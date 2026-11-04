import AppKit
import Foundation
import HubKit

/// A worktree Hub made, with what became of the work in it.
struct WorktreeItem: Identifiable, Hashable {
    var worktree: Worktree
    var repo: String
    /// OPEN, MERGED or CLOSED for the pull request behind it; nil when unknown.
    var prState: String?
    var prNumber: Int?
    var changes: WorktreeChanges
    var modified: Date?
    var id: String { worktree.path }

    /// Safe to remove: its pull request is merged or closed and nothing local would be lost.
    var isDone: Bool { (prState == "MERGED" || prState == "CLOSED") }
    var isStale: Bool { (modified ?? .now) < .now.addingTimeInterval(-14 * 86_400) }
}

extension ClaudeLink {
    /// Sessions written to in the last two minutes: Claude is working in them now.
    var liveSessions: [ClaudeSession] {
        let cutoff = Date.now.addingTimeInterval(-120)
        return sessions.filter { $0.updatedAt > cutoff }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func isLive(_ session: ClaudeSession) -> Bool { session.updatedAt > .now.addingTimeInterval(-120) }
}

extension Store {
    // MARK: Worktrees

    func scanWorktrees() async {
        guard !scanningWorktrees else { return }
        scanningWorktrees = true
        defer { scanningWorktrees = false }
        let clones = claude.clones
        var found: [WorktreeItem] = await Task.detached(priority: .utility) {
            var items: [WorktreeItem] = []
            for (repo, paths) in clones {
                for clone in paths {
                    for tree in Git.hubWorktrees(of: clone) {
                        let modified = (try? FileManager.default.attributesOfItem(atPath: tree.path))?[.modificationDate] as? Date
                        items.append(WorktreeItem(worktree: tree, repo: repo, prState: nil, prNumber: tree.pullRequestNumber,
                                                  changes: Git.changes(in: tree.path), modified: modified))
                    }
                }
            }
            return items
        }.value

        // Ask GitHub what happened to each one's pull request, one query per repository.
        for repo in Set(found.map(\.repo)) {
            let items = found.indices.filter { found[$0].repo == repo }
            guard let client = clientForRepo(repo) else { continue }
            let numbers = items.compactMap { found[$0].worktree.pullRequestNumber }
            let branches = items.compactMap { found[$0].worktree.pullRequestNumber == nil ? found[$0].worktree.branch : nil }
            guard let states = try? await client.pullRequestStates(repo: repo, numbers: numbers, branches: branches) else { continue }
            for index in items {
                if let n = found[index].worktree.pullRequestNumber { found[index].prState = states.byNumber[n] }
                else if let b = found[index].worktree.branch { found[index].prState = states.byBranch[b] }
            }
        }
        // A worktree whose pull request is merged or closed, with nothing uncommitted
        // or unpushed in it, has nothing left to lose: remove it. Branches stay.
        var removed: [WorktreeItem] = []
        for item in found where item.isDone && item.changes.isClean && !worktreeInUse(item.worktree.path) {
            let tree = item.worktree
            if (try? await Task.detached { try Git.removeWorktree(tree, force: false) }.value) != nil { removed.append(item) }
        }
        found.removeAll { removed.contains($0) }
        if !removed.isEmpty {
            show(.success, "Removed \(removed.count) finished worktree\(removed.count == 1 ? "" : "s"): \(removed.map { "\($0.repo.split(separator: "/").last ?? "")/\($0.worktree.name)" }.joined(separator: ", "))")
        }
        worktrees = found.sorted { a, b in
            a.isDone != b.isDone ? a.isDone : (a.modified ?? .distantPast) > (b.modified ?? .distantPast)
        }
    }

    /// A Hub terminal or a live Claude session is working in this folder.
    func worktreeInUse(_ path: String) -> Bool {
        claude.terminals.sessions.contains { $0.running && ($0.directory ?? "").hasPrefix(path) }
            || claude.liveSessions.contains { $0.cwd.hasPrefix(path) }
    }

    /// Removes the worktree at `path` (one Hub made next to `clone`).
    func removeWorktree(at path: String, clone: String, force: Bool) async {
        let item = worktrees.first { $0.worktree.path == path }
            ?? WorktreeItem(worktree: Worktree(path: path, clone: clone), repo: "", prState: nil, prNumber: nil,
                            changes: WorktreeChanges(modifiedFiles: 0, unpushedCommits: nil), modified: nil)
        await removeWorktree(item, force: force)
    }

    func removeWorktree(_ item: WorktreeItem, force: Bool) async {
        do {
            try await Task.detached { try Git.removeWorktree(item.worktree, force: force) }.value
            worktrees.removeAll { $0.id == item.id }
            show(.success, "Removed \(item.worktree.name)")
        } catch {
            show(.failure, error.localizedDescription)
        }
    }

    /// A client for an account that sees a repository, else any account.
    func clientForRepo(_ repo: String) -> GitHubClient? {
        let lower = repo.lowercased()
        let viewers = seenBy.first { $0.key.lowercased() == "repo:\(lower)" }?.value ?? []
        if let id = accounts.first(where: { viewers.contains($0.id) })?.id, let client = client(id) { return client }
        return accounts.lazy.compactMap { self.client($0.id) }.first
    }

    /// Open pull requests matching `text` on GitHub, in the repositories'
    /// owners each shown account works with: for ⌘K, beyond what Hub loaded.
    func searchPulls(_ text: String, in repo: String? = nil) async -> [PullRequest] {
        if let repo {
            guard let client = clientForRepo(repo) else { return [] }
            return (try? await client.searchPullRequests(text, repo: repo)) ?? []
        }
        let ids = activeScope.map { [$0] } ?? accounts.map(\.id).filter { !hiddenAccounts.contains($0) }
        var jobs: [(GitHubClient, [String])] = []
        for id in ids {
            guard let client = client(id) else { continue }
            var owners: [String] = [client.account.login]
            let names = seenBy.filter { $0.key.hasPrefix("repo:") && $0.value.contains(id) }.map { String($0.key.dropFirst(5)) }
                + (reviewRequests + reviewedPulls + myPulls).filter { $0.accountID == id }.map(\.repo)
            for name in names {
                if let owner = name.split(separator: "/").first.map(String.init), !owners.contains(where: { $0.lowercased() == owner.lowercased() }) {
                    owners.append(owner)
                }
            }
            jobs.append((client, owners))
        }
        let found = await withTaskGroup(of: [PullRequest].self) { group in
            for (client, owners) in jobs {
                group.addTask { (try? await client.searchPullRequests(text, owners: owners)) ?? [] }
            }
            var all: [PullRequest] = []
            for await pulls in group { all += pulls }
            return all
        }
        var seen = Set<String>()
        return found.sorted { $0.updatedAt > $1.updatedAt }.filter { seen.insert("\($0.repo.lowercased())#\($0.number)").inserted }
    }

    // MARK: Links

    /// Where a github.com link goes in Hub: loaded items first, otherwise fetched.
    func resolve(_ link: GitHubLink) async -> (Pane, Selection)? {
        switch link {
        case .pullRequest(let repo, let number):
            if let pr = (reviewRequests + myPulls).first(where: { $0.repo.lowercased() == repo.lowercased() && $0.number == number }) {
                return (pr.lane == .reviewRequested ? .reviews : .mine, .pr(pr))
            }
            for state in accounts {
                guard let client = client(state.id),
                      let pr = try? await client.pullRequest(repo: repo, number: number, lane: .reviewRequested) else { continue }
                return (.reviews, .pr(pr))
            }
        case .issue(let repo, let number):
            if let issue = issues.first(where: { $0.repo.lowercased() == repo.lowercased() && $0.number == number }) {
                return (.issues, .issue(issue))
            }
            for state in accounts {
                guard let client = client(state.id), let issue = try? await client.issue(repo: repo, number: number) else { continue }
                return (.issues, .issue(issue))
            }
        case .run(let repo, let id):
            if let run = runs.first(where: { $0.id == id }) { return (.actions, .run(run)) }
            for state in accounts {
                guard let client = client(state.id), let run = try? await client.run(repo: repo, id: id) else { continue }
                return (.actions, .run(run))
            }
        case .repository:
            return nil
        }
        show(.failure, "None of your accounts can see that.")
        return nil
    }
}

// MARK: Comments handed back by Claude

extension Store {
    /// Picks up comments `gh-hub-comment` dropped in the inbox and adds them
    /// to the pull request's pending comments.
    func importInbox() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: ClaudeLink.inbox, includingPropertiesForKeys: nil) else { return }
        var added: [String: Int] = [:]
        for file in files where file.pathExtension == ReviewInbox.fileExtension {
            defer { try? fm.removeItem(at: file) }
            guard let text = try? String(contentsOf: file, encoding: .utf8), let item = ReviewInbox.parse(text) else { continue }
            let c = item.comment
            let existing = drafts[item.pullRequestID] ?? []
            guard !existing.contains(where: { $0.path == c.path && $0.line == c.line && $0.side == c.side && $0.body == c.body }) else { continue }
            drafts[item.pullRequestID, default: []].append(c)
            added[item.pullRequestID, default: 0] += 1
        }
        for (id, count) in added {
            let pr = (reviewRequests + myPulls).first { $0.nodeID == id }
            let target = pr.map { "\($0.repo)#\($0.number)" } ?? "the pull request"
            show(.success, "Claude added \(count) pending comment\(count == 1 ? "" : "s") to \(target)")
        }
    }
}

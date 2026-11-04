import AppKit
import HubKit
import SwiftUI

/// Claude on a pull request, issue or run: start a session with the context
/// filled in, or pick up one that already worked on it.
struct ClaudeCard<Actions: View>: View {
    @Environment(Store.self) private var store
    var repo: String
    var accountID: String
    var worktree: String
    var sessions: [ClaudeSession]
    @ViewBuilder var actions: () -> Actions
    /// Set while asking whether to remove the worktree: what removing it would lose.
    @State private var removing: WorktreeChanges?

    var body: some View {
        let claude = store.claude
        let _ = claude.revision
        let clone = claude.clonePath(for: repo)
        let profile = claude.profile(for: accountID, clone: clone.path)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles").foregroundStyle(Theme.claude.gradient)
                Text("Claude").font(.headline)
                if !sessions.isEmpty {
                    Text("\(sessions.count) session\(sessions.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                }
                Spacer()
                if claude.scanning { ProgressView().controlSize(.mini) }
                if sessions.contains(where: claude.isLive) {
                    HStack(spacing: 5) { LiveDot(); Text("Claude is on it") }.font(.caption).foregroundStyle(Theme.green)
                }
            }

            HStack(spacing: 8) {
                actions()
                Spacer(minLength: 0)
                let worktreePath = clone.path + "-worktrees/" + worktree
                if clone.exists {
                    OpenInButton(path: FileManager.default.fileExists(atPath: worktreePath) ? worktreePath : clone.path)
                }
            }
            .controlSize(.regular)

            HStack(spacing: 5) {
                Image(systemName: clone.exists ? "folder" : "arrow.down.circle")
                Text(clone.exists
                     ? "Works in \((clone.path + "-worktrees/" + worktree).abbreviatingHome)"
                     : "Clones into \(clone.path.abbreviatingHome) first")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("·")
                ProfileChip(name: profile?.name ?? "claude", color: profile?.color)
                Text("· in \(TerminalChoice.current.label)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Change the profile per account in Settings › Claude")

            let worktreePath = clone.path + "-worktrees/" + worktree
            if clone.exists && FileManager.default.fileExists(atPath: worktreePath) {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.gearshape")
                    Text("Worktree \(worktree) is on disk").lineLimit(1)
                    Spacer()
                    Button(role: .destructive) {
                        Task { removing = await Task.detached { Git.changes(in: worktreePath) }.value }
                    } label: { Label("Remove worktree", systemImage: "trash") }
                        .controlSize(.small)
                        .help("Delete the folder. The branch stays, locally and on GitHub.")
                }
                .font(.caption).foregroundStyle(.secondary)
                .confirmationDialog("Remove worktree \(worktree)?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                    let clean = removing?.isClean ?? true
                    Button(clean ? "Remove" : "Remove and lose changes", role: .destructive) {
                        Task { await store.removeWorktree(at: worktreePath, clone: clone.path, force: !clean); removing = nil }
                    }
                } message: {
                    if let changes = removing, !changes.isClean {
                        Text(["\(changes.modifiedFiles) uncommitted file\(changes.modifiedFiles == 1 ? "" : "s")",
                              (changes.unpushedCommits ?? 0) > 0 ? "\(changes.unpushedCommits!) unpushed commit\(changes.unpushedCommits! == 1 ? "" : "s")" : nil]
                            .compactMap { $0 }.filter { !$0.hasPrefix("0 ") }.joined(separator: " and ") + " will be lost. The branch stays.")
                    } else {
                        Text("Nothing uncommitted or unpushed in it. The branch stays.")
                    }
                }
            }

            if !sessions.isEmpty {
                Divider()
                ForEach(sessions.prefix(6)) { session in
                    SessionRow(session: session)
                }
                if sessions.count > 6 {
                    Text("and \(sessions.count - 6) older").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .card()
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.claude.opacity(0.35)))
    }
}

struct SessionRow: View {
    @Environment(Store.self) private var store
    var session: ClaudeSession

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.prompt.isEmpty ? "(no prompt)" : session.prompt)
                    .font(.system(size: 12.5))
                    .lineLimit(2)
                HStack(spacing: 5) {
                    if store.claude.isLive(session) { LiveDot(); Text("working now").foregroundStyle(Theme.green) }
                    ProfileChip(name: store.claude.profileName(forSession: session), color: store.claude.profileColor(forSession: session))
                    if let branch = session.branches.last { BranchChip(name: branch) }
                    Text(session.cwd.abbreviatingHome).lineLimit(1).truncationMode(.head)
                    Text("· \(session.updatedAt.short)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Resume") {
                do { try store.claude.resume(session) } catch { store.show(.failure, error.localizedDescription) }
            }
            .help("claude --resume \(session.id), in \(session.cwd.abbreviatingHome)")
        }
        .padding(.vertical, 2)
    }
}

struct ProfileChip: View {
    var name: String
    var color: String?

    var body: some View {
        let tint = color.flatMap(Color.init(hex:)) ?? Theme.claude
        HStack(spacing: 3) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(name)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .padding(.horizontal, 6).padding(.vertical, 1.5)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

/// A small mark on list rows that Claude has worked on; green while a session is working on it now.
struct ClaudeBadge: View {
    var sessions: [ClaudeSession]

    var body: some View {
        let count = sessions.count
        let live = sessions.contains { $0.updatedAt > .now.addingTimeInterval(-120) }
        if count > 0 {
            HStack(spacing: 2) {
                if live { LiveDot().scaleEffect(0.8) }
                Image(systemName: "sparkles")
                if count > 1 { Text("\(count)") }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(live ? Theme.green : Theme.claude)
            .help(live ? "Claude is working on this right now" : "\(count) local Claude session\(count == 1 ? "" : "s") on this branch")
        }
    }
}

// MARK: Starting Claude from Hub

extension Store {
    func defaultBranch(of repo: String) -> String? {
        repos.first { $0.nameWithOwner.lowercased() == repo.lowercased() }?.defaultBranch
    }

    func claudeSessions(for pr: PullRequest) -> [ClaudeSession] { claude.sessions(for: pr) }

    func claudeSessions(for issue: Issue) -> [ClaudeSession] {
        let branches = issue.linked.compactMap { pullRequest($0)?.headRef }
        return claude.sessions(for: issue, prBranches: branches)
    }

    func claudeSessions(for run: WorkflowRun) -> [ClaudeSession] {
        claude.sessions(for: run, defaultBranch: defaultBranch(of: run.repo))
    }

    private func account(for id: String) -> Account? { account(id)?.account }

    func startClaude(on pr: PullRequest, prompt: String?, as accountID: String) {
        guard let account = account(for: accountID) else { return }
        launch(.init(title: "#\(pr.number) \(pr.title)", repo: pr.repo, account: account, worktree: "pr-\(pr.number)",
                     setup: .pullRequest(pr.number, base: pr.baseRef), prompt: prompt))
    }

    func startClaude(on issue: Issue, as accountID: String) {
        guard let account = account(for: accountID) else { return }
        let base = defaultBranch(of: issue.repo) ?? "main"
        let branch = "\(issue.number)-\(issue.title.slug)"
        launch(.init(title: "#\(issue.number) \(issue.title)", repo: issue.repo, account: account, worktree: "issue-\(issue.number)",
                     setup: .newBranch(branch, base: base), prompt: Prompts.implement(issue, branch: branch, base: base)))
    }

    /// A failed run: on its pull request's branch when there is one, else a detached checkout.
    func startClaude(on run: WorkflowRun, as accountID: String) async {
        guard let account = account(for: accountID), let client = client(accountID) else { return }
        show(.info, "Reading the failed job's log…")
        let jobs = (try? await client.jobs(of: run)) ?? []
        let failed = jobs.first { $0.conclusion == "failure" }
        let log = await failed.asyncMap { try? await client.logTail(repo: run.repo, job: $0, lines: 120) } ?? nil
        if let pr = (reviewRequests + myPulls).first(where: { $0.repo == run.repo && $0.headRef == run.branch }) {
            startClaude(on: pr, prompt: Prompts.failingChecks(pr, runs: [run], log: log), as: accountID)
            return
        }
        launch(.init(title: "\(run.name) #\(run.runNumber)", repo: run.repo, account: account, worktree: "run-\(run.id)",
                     setup: .detached(run.branch ?? defaultBranch(of: run.repo) ?? "main"),
                     prompt: Prompts.failedRun(run, job: failed?.name, log: log)))
    }

    /// The failing runs on a pull request's branch, and the end of the first failed job's log.
    func failingContext(for pr: PullRequest, as accountID: String) async -> (runs: [WorkflowRun], log: String?) {
        let failing = runs.filter { $0.repo == pr.repo && $0.branch == pr.headRef && $0.phase == .failure }
        guard let first = failing.first, let client = client(accountID) else { return (failing, nil) }
        let jobs = (try? await client.jobs(of: first)) ?? []
        guard let job = jobs.first(where: { $0.conclusion == "failure" }) else { return (failing, nil) }
        return (failing, try? await client.logTail(repo: pr.repo, job: job, lines: 120))
    }

    private func launch(_ plan: ClaudeLink.Plan) {
        do {
            _ = try claude.launch(plan)
            show(.success, TerminalChoice.current == .hub ? "Starting Claude" : "Opening Claude in \(TerminalChoice.current.label)")
        } catch {
            show(.failure, error.localizedDescription)
        }
    }
}

extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let value = self else { return nil }
        return await transform(value)
    }
}

extension Store {
    /// Settings changed a profile choice; redraw what depends on it.
    func objectWillChangeClaude() { claude.revision += 1 }
}

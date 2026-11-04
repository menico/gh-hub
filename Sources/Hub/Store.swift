import AppKit
import Foundation
import HubKit
import Observation
import UserNotifications

/// Everything the windows show, refreshed on a timer across every account.
@MainActor
@Observable
final class Store {
    struct Toast: Identifiable, Equatable {
        enum Tone { case success, failure, info }
        let id = UUID()
        var tone: Tone
        var message: String
    }

    struct AccountState: Identifiable, Hashable {
        var account: Account
        var avatar: URL?
        var error: String?
        var usage: ResponseCache.Stats?
        var id: String { account.id }
    }

    private(set) var accounts: [AccountState] = []
    private(set) var reviewRequests: [PullRequest] = []
    private(set) var myPulls: [PullRequest] = []
    /// Open pull requests you already reviewed, no longer waiting on you.
    private(set) var reviewedPulls: [PullRequest] = []
    /// Every open pull request of a repository, as last fetched, by name.
    private(set) var repoPulls: [String: (pulls: [PullRequest], total: Int, at: Date)] = [:]
    private(set) var loadingRepoPulls: Set<String> = []
    private(set) var repoPullsError: [String: String] = [:]
    private(set) var issues: [Issue] = []
    /// Local clones and Claude Code sessions.
    let claude = ClaudeLink()
    /// Claude's reviews of pull requests.
    let reviewer = ClaudeReviewer()

    /// Line comments written but not yet sent, by pull request node id.
    var drafts: [String: [DraftComment]] = Store.loadDrafts() {
        didSet {
            guard persists, let data = try? JSONEncoder().encode(drafts) else { return }
            UserDefaults.standard.set(data, forKey: "drafts")
        }
    }

    private static func loadDrafts() -> [String: [DraftComment]] {
        guard let data = UserDefaults.standard.data(forKey: "drafts") else { return [:] }
        return (try? JSONDecoder().decode([String: [DraftComment]].self, from: data)) ?? [:]
    }

    /// Runs to announce when they finish.
    var watchedRuns: Set<Int> = []
    /// Worktrees Hub made, and what became of their pull requests.
    var worktrees: [WorktreeItem] = []
    var scanningWorktrees = false
    private(set) var runs: [WorkflowRun] = []
    private(set) var repos: [Repo] = []
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    private(set) var setupError: String?
    var toast: Toast?

    /// Accounts switched off in the sidebar.
    var hiddenAccounts: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "hiddenAccounts") ?? []) {
        didSet { UserDefaults.standard.set(Array(hiddenAccounts), forKey: "hiddenAccounts") }
    }

    /// The account the window is scoped to, or nil for every account.
    var scope: String? = UserDefaults.standard.string(forKey: "scope") {
        didSet { if persists { UserDefaults.standard.set(scope, forKey: "scope") } }
    }

    /// Display names chosen for accounts, by account id.
    var aliases: [String: String] = (UserDefaults.standard.dictionary(forKey: "aliases") as? [String: String]) ?? [:] {
        didSet { UserDefaults.standard.set(aliases, forKey: "aliases") }
    }

    /// Per account: work only with these repositories instead of everything
    /// recently active.
    struct RepoFocus: Codable, Equatable {
        var enabled = false
        var repos: [String] = []
    }

    var focus: [String: RepoFocus] = Store.loadFocus() {
        didSet {
            guard persists else { return }
            if let data = try? JSONEncoder().encode(focus) { UserDefaults.standard.set(data, forKey: "repoFocus") }
        }
    }

    /// False for a throwaway store (the probe), so it never rewrites saved settings.
    var persists = true {
        didSet {}
    }

    private static func loadFocus() -> [String: RepoFocus] {
        guard let data = UserDefaults.standard.data(forKey: "repoFocus") else { return [:] }
        return (try? JSONDecoder().decode([String: RepoFocus].self, from: data)) ?? [:]
    }

    /// The repositories an account is limited to, lowercased, or nil when it is not limited.
    func focusedRepos(_ accountID: String) -> Set<String>? {
        guard let entry = focus[accountID], entry.enabled else { return nil }
        return Set(entry.repos.map { $0.lowercased() })
    }

    func inFocus(_ repo: String, for accountID: String) -> Bool {
        focusedRepos(accountID)?.contains(repo.lowercased()) ?? true
    }

    /// Selected repositories older than the dashboard query reaches, looked up once.
    private var extraRepos: [String: Repo] = [:]

    /// Every account that can see a pull request ("pr:<node id>") or a
    /// repository ("repo:<owner/name>"), not just the one listed first.
    private(set) var seenBy: [String: Set<String>] = [:]

    private var clients: [String: GitHubClient] = [:]
    /// The last good answer per account, kept through a failed refresh so a
    /// passing GitHub hiccup does not empty the lists.
    private var lastGood: [String: Snapshot] = [:]
    private var loop: Task<Void, Never>?
    private var activation: NSObjectProtocol?

    /// Seconds until the next refresh: the chosen interval, quicker while a
    /// run is going, slower while Hub is in the background, and slower still
    /// when an account is low on rate limit.
    func nextWait() -> Double {
        let base = max(30, UserDefaults.standard.double(forKey: "pollSeconds").nonZero ?? 90)
        var wait = base
        if !activeRuns.isEmpty && !allActive.isEmpty {
            wait = min(base, 30)
        } else if NSApp?.isActive == false {
            wait = min(base * 3, 600)
        }
        let lowest = accounts.compactMap { $0.usage?.rates["core"] }.map { Double($0.remaining) / Double(max($0.limit, 1)) }.min() ?? 1
        if lowest < 0.1 { wait = max(wait * 4, 600) } else if lowest < 0.25 { wait *= 2 }
        return wait
    }
    private var seenReviewIDs: Set<String>?
    private var seenAssignedIDs: Set<String>?
    private var seenFailedRunIDs: Set<Int>?
    private var seenWaitingRunIDs: Set<Int>?

    // MARK: Derived

    /// Accounts with the sidebar switch on, in order.
    var shownAccounts: [AccountState] { accounts.filter { !hiddenAccounts.contains($0.id) } }

    /// The scope, if it still names an account that is shown.
    var activeScope: String? {
        guard let scope, shownAccounts.contains(where: { $0.id == scope }) else { return nil }
        return scope
    }

    // The accounts that see an item and have its repository in focus.
    func viewers(of pr: PullRequest) -> Set<String> {
        let all = seenBy["pr:\(pr.nodeID)"] ?? [pr.accountID]
        // Someone waiting on your review always gets through, whatever the selection.
        if pr.lane == .reviewRequested { return all }
        return all.filter { inFocus(pr.repo, for: $0) }
    }
    func viewers(of run: WorkflowRun) -> Set<String> {
        (seenBy["repo:\(run.repo)"] ?? [run.accountID]).filter { inFocus(run.repo, for: $0) }
    }
    func viewers(of repo: Repo) -> Set<String> {
        (seenBy["repo:\(repo.nameWithOwner)"] ?? [repo.accountID]).filter { inFocus(repo.nameWithOwner, for: $0) }
    }

    /// The account that acts on an item: the scoped account when it can see
    /// the item, otherwise the first account that saw it.
    func acting(_ owner: String, viewers: Set<String>) -> String {
        if let scope = activeScope, viewers.contains(scope) { return scope }
        if viewers.contains(owner) || viewers.isEmpty { return owner }
        return accounts.first { viewers.contains($0.id) }?.id ?? owner
    }
    func acting(for pr: PullRequest) -> String { acting(pr.accountID, viewers: viewers(of: pr)) }
    func acting(for run: WorkflowRun) -> String { acting(run.accountID, viewers: viewers(of: run)) }
    func acting(for repo: Repo) -> String { acting(repo.accountID, viewers: viewers(of: repo)) }

    private func shown(_ viewers: Set<String>, in scope: String?) -> Bool {
        if let scope { return viewers.contains(scope) }
        return !viewers.isSubset(of: hiddenAccounts)
    }

    // Everything for every shown account: the menu bar, notifications, the Dock badge.
    var allReviews: [PullRequest] { reviewRequests.filter { shown(viewers(of: $0), in: nil) } }
    var allAssigned: [Issue] { issues.filter { $0.lane == .assigned && shown(viewers(of: $0), in: nil) } }
    var allRuns: [WorkflowRun] { runs.filter { shown(viewers(of: $0), in: nil) } }
    var allWaiting: [WorkflowRun] { allRuns.filter { $0.phase == .waiting } }
    var allActive: [WorkflowRun] { allRuns.filter(\.isActive) }
    var allFailingMine: [WorkflowRun] { allRuns.filter { $0.phase == .failure && isOurs($0) } }

    // The same, narrowed to the account tab that is selected.
    var visibleReviews: [PullRequest] { reviewRequests.filter { shown(viewers(of: $0), in: activeScope) } }
    var visibleMine: [PullRequest] { myPulls.filter { shown(viewers(of: $0), in: activeScope) } }
    var visibleReviewed: [PullRequest] { reviewedPulls.filter { shown(viewers(of: $0), in: activeScope) } }
    /// Repositories of the shown accounts, most recently pushed first.
    var visibleRepos: [Repo] {
        repos.filter { shown(viewers(of: $0), in: activeScope) }
            .sorted { ($0.pushedAt ?? .distantPast) > ($1.pushedAt ?? .distantPast) }
    }

    /// Fetches a repository's open pull requests as an account that can see it
    /// (the selected account when it can).
    func loadRepoPulls(_ repo: String) async {
        guard !loadingRepoPulls.contains(repo) else { return }
        loadingRepoPulls.insert(repo)
        defer { loadingRepoPulls.remove(repo) }
        let scoped = activeScope.flatMap { id in seenBy["repo:\(repo)"]?.contains(id) == true ? client(id) : nil }
        guard let client = scoped ?? clientForRepo(repo) else { return }
        do {
            let result = try await client.openPullRequests(in: repo)
            repoPulls[repo] = (result.pulls, result.total, .now)
            repoPullsError[repo] = nil
        } catch {
            repoPullsError[repo] = error.localizedDescription
        }
    }
    var visibleIssues: [Issue] { issues.filter { shown(viewers(of: $0), in: activeScope) } }

    func viewers(of issue: Issue) -> Set<String> {
        let all = seenBy["issue:\(issue.nodeID)"] ?? [issue.accountID]
        // Like review requests, an issue assigned to you always gets through.
        if issue.lane == .assigned { return all }
        return all.filter { inFocus(issue.repo, for: $0) }
    }
    func acting(for issue: Issue) -> String { acting(issue.accountID, viewers: viewers(of: issue)) }

    /// The pull request or issue behind a link, if Hub has it loaded.
    func pullRequest(_ link: LinkedItem) -> PullRequest? {
        (reviewRequests + reviewedPulls + myPulls + repoPulls.values.flatMap(\.pulls)).first { $0.repo == link.repo && $0.number == link.number }
    }
    func issue(_ link: LinkedItem) -> Issue? {
        issues.first { $0.repo == link.repo && $0.number == link.number }
    }

    /// Issues linked to a pull request: the ones it says it closes, plus any
    /// loaded issue that points back at it.
    func linkedIssues(of pr: PullRequest) -> [LinkedItem] {
        var links = pr.linkedIssues
        for issue in issues {
            guard let back = issue.linked.first(where: { $0.repo == pr.repo && $0.number == pr.number }),
                  !links.contains(where: { $0.repo == issue.repo && $0.number == issue.number }) else { continue }
            links.append(LinkedItem(kind: .issue, relation: back.relation, number: issue.number, title: issue.title,
                                    repo: issue.repo, url: issue.url, state: "OPEN", isDraft: false))
        }
        return links
    }
    var visibleRuns: [WorkflowRun] { runs.filter { shown(viewers(of: $0), in: activeScope) } }
    var waitingRuns: [WorkflowRun] { visibleRuns.filter { $0.phase == .waiting } }
    var failingRuns: [WorkflowRun] { visibleRuns.filter { $0.phase == .failure } }
    var activeRuns: [WorkflowRun] { visibleRuns.filter { $0.isActive } }

    /// What needs this account: review requests, assigned issues, and runs waiting on approval.
    func attention(for accountID: String?) -> Int {
        reviewRequests.filter { shown(viewers(of: $0), in: accountID) }.count
            + issues.filter { $0.lane == .assigned && shown(viewers(of: $0), in: accountID) }.count
            + runs.filter { $0.phase == .waiting && shown(viewers(of: $0), in: accountID) }.count
    }

    func name(_ accountID: String) -> String {
        if let alias = aliases[accountID], !alias.isEmpty { return alias }
        return account(accountID)?.account.login ?? accountID
    }

    func account(_ id: String) -> AccountState? { accounts.first { $0.id == id } }
    func client(_ accountID: String) -> GitHubClient? { clients[accountID] }

    // MARK: Lifecycle

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.connect()
            while !Task.isCancelled {
                await self?.refresh()
                guard let wait = self?.nextWait() else { return }
                try? await Task.sleep(for: .seconds(wait))
            }
        }
        // Coming back to Hub shows fresh data right away instead of at the next tick.
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, (self.lastRefresh ?? .distantPast) < .now.addingTimeInterval(-20) else { return }
                await self.refresh()
            }
        }
        // Claude sessions are cheap to rescan (only changed files are read),
        // so "live" stays current while Hub is in front.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self else { return }
                if NSApp?.isActive == true { await self.claude.scan() }
            }
        }
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    /// Reads the signed-in accounts from `gh` and fetches a token for each.
    func connect() async {
        do {
            let found = try await GHCLI.accounts()
            guard !found.isEmpty else {
                setupError = "No GitHub accounts are signed in to gh. Run `gh auth login` and press refresh."
                return
            }
            var states: [AccountState] = []
            var clients: [String: GitHubClient] = [:]
            for account in found {
                do {
                    clients[account.id] = GitHubClient(account: account, token: try await GHCLI.token(for: account))
                    states.append(AccountState(account: account))
                } catch {
                    states.append(AccountState(account: account, error: error.localizedDescription))
                }
            }
            self.clients = clients
            Theme.accountOrder = states.map(\.id)
            self.accounts = states
            setupError = nil
        } catch {
            setupError = error.localizedDescription
        }
    }

    func refresh() async {
        if clients.isEmpty { await connect() }
        guard !isRefreshing, !clients.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let clients = self.clients
        var snapshots: [String: Result<Snapshot, Error>] = [:]
        await withTaskGroup(of: (String, Result<Snapshot, Error>).self) { group in
            for (id, client) in clients {
                group.addTask {
                    do { return (id, .success(try await client.snapshot())) } catch { return (id, .failure(error)) }
                }
            }
            for await (id, result) in group { snapshots[id] = result }
        }

        // Accounts in a stable order; a pull request or repository seen by
        // several accounts belongs to the first.
        var reviews: [PullRequest] = [], mine: [PullRequest] = [], reviewed: [PullRequest] = [], repos: [Repo] = []
        var issues: [Issue] = [], seenIssues = Set<String>()
        var seenPRs = Set<String>(), seenRepos = Set<String>()
        var seenBy: [String: Set<String>] = [:]
        for index in accounts.indices {
            let id = accounts[index].id
            var snapshot: Snapshot?
            switch snapshots[id] {
            case .success(let snap):
                accounts[index].avatar = snap.avatar
                accounts[index].error = nil
                lastGood[id] = snap
                snapshot = snap
            case .failure(let error):
                accounts[index].error = error.localizedDescription
                snapshot = lastGood[id]
            case nil:
                break
            }
            if let snap = snapshot {
                for issue in snap.assignedIssues + snap.createdIssues {
                    seenBy["issue:\(issue.nodeID)", default: []].insert(id)
                }
                // Assigned first, so an issue that is both keeps the assigned lane.
                issues += (snap.assignedIssues + snap.createdIssues).filter { seenIssues.insert($0.nodeID).inserted }
                for pr in snap.reviewRequests + snap.mine + snap.reviewed {
                    seenBy["pr:\(pr.nodeID)", default: []].insert(id)
                    seenBy["repo:\(pr.repo)", default: []].insert(id)
                }
                for repo in snap.repos { seenBy["repo:\(repo.nameWithOwner)", default: []].insert(id) }
                reviews += snap.reviewRequests.filter { seenPRs.insert($0.nodeID).inserted }
                reviewed += snap.reviewed
                mine += snap.mine.filter { seenPRs.insert($0.nodeID).inserted }
                repos += snap.repos.filter { seenRepos.insert($0.nameWithOwner).inserted }
            }
        }
        // Selected repositories the dashboard query did not reach (older pushes).
        var known = Set(repos.map { $0.nameWithOwner.lowercased() })
        for state in accounts {
            guard let wanted = focus[state.id], wanted.enabled, let client = clients[state.id] else { continue }
            for name in wanted.repos {
                seenBy["repo:\(name)", default: []].insert(state.id)
                guard known.insert(name.lowercased()).inserted else { continue }
                if extraRepos[name] == nil { extraRepos[name] = try? await client.repository(name) }
                if let repo = extraRepos[name] { repos.append(repo) }
            }
        }
        self.seenBy = seenBy
        reviewRequests = reviews.sorted { $0.updatedAt > $1.updatedAt }
        let waiting = Set(reviews.map(\.nodeID))
        var seenReviewed = Set<String>()
        reviewedPulls = reviewed.filter { !waiting.contains($0.nodeID) && seenReviewed.insert($0.nodeID).inserted }
            .sorted { $0.updatedAt > $1.updatedAt }
        myPulls = mine.sorted { $0.updatedAt > $1.updatedAt }
        self.issues = issues.sorted { $0.updatedAt > $1.updatedAt }
        self.repos = repos.sorted { ($0.pushedAt ?? .distantPast) > ($1.pushedAt ?? .distantPast) }

        await refreshRuns(prRepos: Set((reviews + mine).map(\.repo)))
        for index in accounts.indices {
            accounts[index].usage = clients[accounts[index].id]?.cache.snapshot
        }
        lastRefresh = .now
        notifyChanges()
        if claude.isStale { Task { await claude.scan() } }
    }

    /// Runs for recently pushed repositories, the repositories of open pull
    /// requests, and anything pinned in settings.
    private func refreshRuns(prRepos: Set<String>) async {
        let days = UserDefaults.standard.double(forKey: "activeDays").nonZero ?? 14
        let limit = Int(UserDefaults.standard.double(forKey: "repoLimit").nonZero ?? 15)
        let cutoff = Date.now.addingTimeInterval(-days * 86_400)
        var targets: [(repo: String, accountID: String)] = []
        var chosen = Set<String>()
        func add(_ name: String, _ accountID: String) {
            guard chosen.insert(name.lowercased()).inserted else { return }
            targets.append((name, accountID))
        }
        for state in accounts where clients[state.id] != nil {
            if let wanted = focus[state.id], wanted.enabled {
                // A focused account watches exactly its selection.
                for name in wanted.repos { add(name, state.id) }
            } else {
                // Otherwise: its most recently pushed repositories.
                let recent = repos.filter {
                    (seenBy["repo:\($0.nameWithOwner)"] ?? [$0.accountID]).contains(state.id)
                        && ($0.pushedAt ?? .distantPast) > cutoff
                }
                for repo in recent.prefix(limit) { add(repo.nameWithOwner, state.id) }
            }
        }
        // And wherever an open pull request lives, as an account that has it in focus.
        for name in prRepos {
            guard let pr = (reviewRequests + myPulls).first(where: { $0.repo == name }) else { continue }
            // Runs still follow the selection, even for a repository you were asked to review in.
            if let viewer = accounts.first(where: { viewers(of: pr).contains($0.id) && inFocus(name, for: $0.id) }) {
                add(name, viewer.id)
            }
        }

        let clients = self.clients
        var collected: [WorkflowRun] = []
        await withTaskGroup(of: [WorkflowRun].self) { group in
            for target in targets {
                guard let client = clients[target.accountID] else { continue }
                group.addTask { (try? await client.runs(in: target.repo, limit: 8)) ?? [] }
            }
            for await batch in group { collected += batch }
        }
        runs = collected.sorted { $0.createdAt > $1.createdAt }
    }

    private func notifyChanges() {
        let reviewIDs = Set(reviewRequests.map(\.nodeID))
        let failed = runs.filter { $0.phase == .failure && $0.updatedAt > .now.addingTimeInterval(-3600) }
        let waiting = runs.filter { $0.phase == .waiting }

        if let seen = seenReviewIDs {
            for pr in reviewRequests where !seen.contains(pr.nodeID) {
                notify(title: "Review requested · \(pr.repo)", body: "#\(pr.number) \(pr.title) — \(pr.author)")
            }
        }
        let assigned = issues.filter { $0.lane == .assigned }
        if let seen = seenAssignedIDs {
            for issue in assigned where !seen.contains(issue.nodeID) {
                notify(title: "Issue assigned · \(issue.repo)", body: "#\(issue.number) \(issue.title)")
            }
        }
        seenAssignedIDs = Set(assigned.map(\.nodeID))
        if let seen = seenFailedRunIDs {
            for run in failed where !seen.contains(run.id) && isOurs(run) {
                notify(title: "Run failed · \(run.repo)", body: "\(run.name) on \(run.branch ?? "?") — \(run.title)")
            }
        }
        if let seen = seenWaitingRunIDs {
            for run in waiting where !seen.contains(run.id) {
                notify(title: "Waiting for approval · \(run.repo)", body: "\(run.name) — \(run.title)")
            }
        }
        for run in runs where watchedRuns.contains(run.id) && !run.isActive {
            watchedRuns.remove(run.id)
            notify(title: "\(run.phase == .success ? "✓ Finished" : run.phase == .failure ? "✗ Failed" : "Finished") · \(run.repo)",
                   body: "\(run.name) #\(run.runNumber) — \(run.title)")
        }
        seenReviewIDs = reviewIDs
        seenFailedRunIDs = Set(failed.map(\.id))
        seenWaitingRunIDs = Set(waiting.map(\.id))
        NSApp?.dockTile.badgeLabel = allReviews.isEmpty ? nil : "\(allReviews.count)"
    }

    /// Started by any of your accounts.
    func isOurs(_ run: WorkflowRun) -> Bool {
        accounts.contains { $0.account.login == run.actor }
    }

    /// Started by you: the scoped account when there is one, else any of yours.
    func isMine(_ run: WorkflowRun) -> Bool {
        if let scope = activeScope { return account(scope)?.account.login == run.actor }
        return isOurs(run)
    }

    func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil, UserDefaults.standard.object(forKey: "notify") as? Bool ?? true else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// A fresher copy of one run, fetched while someone watches it.
    func replace(_ run: WorkflowRun) {
        if let index = runs.firstIndex(where: { $0.id == run.id }) { runs[index] = run }
        if !run.isActive, watchedRuns.contains(run.id) { notifyChanges() }
    }

    // MARK: Actions

    /// Runs one write against GitHub, reports how it went, then refreshes.
    func perform(_ success: String, _ work: @escaping (GitHubClient) async throws -> Void, as accountID: String) async -> Bool {
        guard let client = clients[accountID] else {
            show(.failure, "No signed-in client for this account.")
            return false
        }
        do {
            try await work(client)
            show(.success, success)
            Task { try? await Task.sleep(for: .seconds(2)); await refresh() }
            return true
        } catch {
            show(.failure, error.localizedDescription)
            return false
        }
    }

    func show(_ tone: Toast.Tone, _ message: String) {
        let toast = Toast(tone: tone, message: message)
        self.toast = toast
        Task {
            try? await Task.sleep(for: .seconds(tone == .failure ? 6 : 3))
            if self.toast == toast { self.toast = nil }
        }
    }
}

extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}

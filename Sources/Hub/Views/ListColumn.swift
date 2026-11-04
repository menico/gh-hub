import HubKit
import SwiftUI

struct ListColumn: View {
    @Environment(Store.self) private var store
    @Environment(Router.self) private var router
    var section: Pane
    var query: String
    @State private var runFilter: RunFilter = .all
    @State private var issueFilter: IssueFilter = .all
    /// Open pull requests GitHub found for the search, beyond the loaded ones.
    @State private var remote: [PullRequest] = []
    @State private var searchingRemote = false
    @AppStorage("reviewFilter") private var reviewFilter: ReviewFilter = .waiting

    enum ReviewFilter: String, CaseIterable, Identifiable {
        case waiting = "Waiting on me", reviewed = "Reviewed", all = "All"
        var id: String { rawValue }
    }

    enum IssueFilter: String, CaseIterable, Identifiable {
        case all = "All", assigned = "Assigned", created = "Created", linked = "With PRs"
        var id: String { rawValue }
    }

    enum RunFilter: String, CaseIterable, Identifiable {
        case all = "All", active = "Active", failed = "Failed", mine = "Mine"
        var id: String { rawValue }
    }

    var body: some View {
        @Bindable var router = router
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            List(selection: $router.selection) {
                switch section {
                case .reviews, .mine:
                    let prs = filtered(section == .reviews ? reviewList : store.visibleMine)
                    ForEach(groupedByRepo(prs), id: \.repo) { group in
                        SwiftUI.Section {
                            ForEach(group.items) { pr in
                                PRRow(pr: pr).tag(Selection.pr(pr))
                            }
                        } header: {
                            RepoHeader(name: group.repo, count: group.items.count) { router.browse(group.repo) }
                                .contextMenu {
                                    Button("All open pull requests in \(group.repo)") { router.browse(group.repo) }
                                }
                        }
                    }
                    remoteSection(excluding: prs)
                case .repos:
                    ForEach(repoGroups, id: \.title) { group in
                        SwiftUI.Section {
                            ForEach(group.items) { pr in
                                PRRow(pr: pr).tag(Selection.pr(pr))
                            }
                        } header: {
                            HStack {
                                Text(group.title).fontWeight(.semibold)
                                Spacer()
                                Text("\(group.items.count)").foregroundStyle(.tertiary).monospacedDigit()
                            }
                            .font(.system(size: 11.5))
                        }
                    }
                    remoteSection(excluding: repoGroups.flatMap(\.items))
                case .actions:
                    ForEach(filtered(runs)) { run in
                        RunRow(run: run).tag(Selection.run(run))
                    }
                case .issues:
                    ForEach(groupedByRepo(filtered(issueList)), id: \.repo) { group in
                        SwiftUI.Section {
                            ForEach(group.items) { issue in
                                IssueRow(issue: issue).tag(Selection.issue(issue))
                            }
                        } header: {
                            RepoHeader(name: group.repo, count: group.items.count)
                        }
                    }
                case .waiting:
                    ForEach(filtered(store.waitingRuns)) { run in
                        RunRow(run: run).tag(Selection.run(run))
                    }
                case .claude:
                    EmptyView()
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .overlay { empty }
        }
        .background(.background)
        .task(id: "\(section.rawValue)|\(query)|\(router.browsingRepo ?? "")") {
            remote = []
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 3, [.reviews, .mine, .repos].contains(section) else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            searchingRemote = true
            defer { searchingRemote = false }
            let found = await store.searchPulls(q, in: section == .repos ? router.browsingRepo : nil)
            if !Task.isCancelled { remote = found }
        }
        .task(id: section == .repos ? (router.browsingRepo ?? "") : nil) {
            guard section == .repos else { return }
            if router.browsingRepo == nil { router.browsingRepo = store.visibleRepos.first?.nameWithOwner }
            if let repo = router.browsingRepo { await store.loadRepoPulls(repo) }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(section.title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                if let scope = store.activeScope {
                    HStack(spacing: 4) {
                        Circle().fill(Theme.color(for: scope)).frame(width: 7, height: 7)
                        Text(store.name(scope))
                        Button { store.scope = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                            .help("Show all accounts")
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.color(for: scope).opacity(0.15), in: Capsule())
                    .transition(.scale.combined(with: .opacity))
                }
                Spacer()
                Text(subtitle).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            if section == .repos {
                RepoPicker()
            }
            if section == .reviews {
                Picker("", selection: $reviewFilter) {
                    ForEach(ReviewFilter.allCases) { filter in
                        Text(filter == .reviewed ? "Reviewed (\(store.visibleReviewed.count))" : filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if section == .issues {
                Picker("", selection: $issueFilter) {
                    ForEach(IssueFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if section == .actions {
                Picker("", selection: $runFilter) {
                    ForEach(RunFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack(spacing: 8) {
                    StatTile(value: store.activeRuns.count, label: "running", tint: Theme.amber)
                    StatTile(value: store.failingRuns.count, label: "failed", tint: Theme.red)
                    StatTile(value: store.waitingRuns.count, label: "waiting", tint: Theme.pink)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var subtitle: String {
        switch section {
        case .reviews: "\(store.visibleReviews.count) waiting"
        case .mine: "\(store.visibleMine.count) open"
        case .repos: router.browsingRepo.flatMap { store.repoPulls[$0] }.map { "\($0.total) open" } ?? ""
        case .issues: "\(issueList.count) open"
        case .actions: "\(runs.count) runs"
        case .waiting: "\(store.waitingRuns.count) waiting"
        case .claude: ""
        }
    }

    /// While searching: open pull requests on GitHub that match but aren't in this list.
    @ViewBuilder
    private func remoteSection(excluding shown: [PullRequest]) -> some View {
        if !query.isEmpty {
            let keys = Set(shown.map { "\($0.repo.lowercased())#\($0.number)" })
            let extra = remote.filter { !keys.contains("\($0.repo.lowercased())#\($0.number)") }
            if searchingRemote || !extra.isEmpty {
                SwiftUI.Section {
                    ForEach(extra) { pr in PRRow(pr: pr).tag(Selection.pr(pr)) }
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.caption2).foregroundStyle(.tertiary)
                        Text(section == .repos ? "More on GitHub" : "Other open pull requests on GitHub").fontWeight(.semibold)
                        Spacer()
                        if searchingRemote { ProgressView().controlSize(.mini) }
                        else { Text("\(extra.count)").foregroundStyle(.tertiary).monospacedDigit() }
                    }
                    .font(.system(size: 11.5))
                }
            }
        }
    }

    @ViewBuilder
    private var empty: some View {
        let isEmpty: Bool = switch section {
        case .reviews: filtered(reviewList).isEmpty
        case .mine: filtered(store.visibleMine).isEmpty
        case .repos: repoGroups.isEmpty
        case .issues: filtered(issueList).isEmpty
        case .actions: filtered(runs).isEmpty
        case .waiting: filtered(store.waitingRuns).isEmpty
        case .claude: false
        }
        if isEmpty && remote.isEmpty && !searchingRemote {
            if store.lastRefresh == nil {
                ProgressView()
            } else if !query.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "No matches", subtitle: "Nothing matches “\(query)”.")
            } else {
                switch section {
                case .reviews:
                    if reviewFilter == .reviewed {
                        EmptyState(symbol: "eye.slash", title: "Nothing reviewed",
                                   subtitle: "Open pull requests you have reviewed show up here.", tint: Theme.violet)
                    } else {
                        EmptyState(symbol: "checkmark.seal.fill", title: "Inbox zero",
                                   subtitle: "Nobody is waiting on your review.", tint: Theme.green)
                    }
                case .repos:
                    if let repo = router.browsingRepo {
                        if store.loadingRepoPulls.contains(repo) {
                            ProgressView()
                        } else if let error = store.repoPullsError[repo] {
                            EmptyState(symbol: "exclamationmark.triangle", title: "Couldn't load \(repo)", subtitle: error, tint: Theme.red)
                        } else {
                            EmptyState(symbol: "checkmark.circle", title: "No open pull requests",
                                       subtitle: "\(repo) has nothing open.", tint: Pane.repos.tint)
                        }
                    } else {
                        EmptyState(symbol: "books.vertical", title: "Pick a repository",
                                   subtitle: "Every open pull request in it shows up here.", tint: Pane.repos.tint)
                    }
                case .mine:
                    EmptyState(symbol: "arrow.triangle.pull", title: "No open pull requests",
                               subtitle: "Pull requests you open show up here.", tint: Theme.blue)
                case .actions:
                    EmptyState(symbol: "bolt.slash", title: "No runs",
                               subtitle: "Recently pushed repositories have no workflow runs.", tint: Theme.amber)
                case .issues:
                    EmptyState(symbol: "smallcircle.filled.circle", title: "No open issues",
                               subtitle: "Issues assigned to you or opened by you show up here.", tint: Theme.green)
                case .waiting:
                    EmptyState(symbol: "hand.thumbsup.fill", title: "Nothing to approve",
                               subtitle: "Deployments waiting on an environment reviewer show up here.", tint: Theme.pink)
                case .claude:
                    EmptyView()
                }
            }
        }
    }

    // MARK: Data

    /// The browsed repository's open pull requests: what waits on you first,
    /// then yours, then everyone else's.
    private var repoGroups: [(title: String, items: [PullRequest])] {
        guard let repo = router.browsingRepo, let pulls = store.repoPulls[repo]?.pulls else { return [] }
        let all = filtered(pulls)
        let waiting = Set(store.reviewRequests.map(\.nodeID))
        let groups: [(String, [PullRequest])] = [
            ("Waiting on your review", all.filter { waiting.contains($0.nodeID) }),
            ("Yours", all.filter { $0.lane == .mine }),
            ("Everyone else", all.filter { !waiting.contains($0.nodeID) && $0.lane != .mine }),
        ]
        return groups.filter { !$0.1.isEmpty }.map { (title: $0.0, items: $0.1) }
    }

    private var reviewList: [PullRequest] {
        switch reviewFilter {
        case .waiting: store.visibleReviews
        case .reviewed: store.visibleReviewed
        case .all: (store.visibleReviews + store.visibleReviewed).sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    private var runs: [WorkflowRun] {
        switch runFilter {
        case .all: store.visibleRuns
        case .active: store.activeRuns
        case .failed: store.failingRuns
        case .mine: store.visibleRuns.filter(store.isMine)
        }
    }

    private func filtered(_ prs: [PullRequest]) -> [PullRequest] {
        guard !query.isEmpty else { return prs }
        return prs.filter { pr in
            [pr.title, pr.repo, pr.author, pr.headRef, "#\(pr.number)"].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var issueList: [Issue] {
        switch issueFilter {
        case .all: store.visibleIssues
        case .assigned: store.visibleIssues.filter { $0.lane == .assigned }
        case .created: store.visibleIssues.filter { $0.lane == .created }
        case .linked: store.visibleIssues.filter { !$0.linked.isEmpty }
        }
    }

    private func filtered(_ issues: [Issue]) -> [Issue] {
        guard !query.isEmpty else { return issues }
        return issues.filter { issue in
            ([issue.title, issue.repo, issue.author, "#\(issue.number)"] + issue.labels.map(\.name))
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private func filtered(_ runs: [WorkflowRun]) -> [WorkflowRun] {
        guard !query.isEmpty else { return runs }
        return runs.filter { run in
            [run.title, run.repo, run.name, run.branch ?? "", run.actor ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private func groupedByRepo<Item: Identifiable & RepoScoped>(_ prs: [Item]) -> [(repo: String, items: [Item])] {
        var order: [String] = []
        var groups: [String: [Item]] = [:]
        for pr in prs {
            if groups[pr.repo] == nil { order.append(pr.repo) }
            groups[pr.repo, default: []].append(pr)
        }
        return order.map { ($0, groups[$0]!) }
    }
}

struct StatTile: View {
    var value: Int
    var label: String
    var tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Text("\(value)")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(value > 0 ? tint : .secondary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background((value > 0 ? tint : Color.secondary).opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct RepoHeader: View {
    var name: String
    var count: Int
    /// Opens every open pull request in the repository (Repositories pane).
    var browse: (() -> Void)?

    var body: some View {
        let parts = name.split(separator: "/", maxSplits: 1)
        HStack(spacing: 4) {
            Image(systemName: "book.closed.fill").font(.caption2).foregroundStyle(.tertiary)
            Text(parts.first.map(String.init) ?? "").foregroundStyle(.secondary)
            Text("/").foregroundStyle(.tertiary)
            Text(parts.dropFirst().first.map(String.init) ?? name).fontWeight(.semibold)
            Spacer()
            if let browse {
                Button("All open", action: browse)
                    .buttonStyle(.link)
                    .help("Every open pull request in \(name)")
            }
            Text("\(count)").foregroundStyle(.tertiary).monospacedDigit()
        }
        .font(.system(size: 11.5))
    }
}

struct PRRow: View {
    @Environment(Store.self) private var store
    var pr: PullRequest

    private var pills: some View {
        HStack(spacing: 6) {
            MyReviewPill(pr: pr, waiting: store.reviewRequests.contains { $0.nodeID == pr.nodeID })
            ReviewPill(decision: pr.reviewDecision)
            if pr.mergeable == .conflicting { Pill(text: "Conflicts", symbol: "exclamationmark.triangle", tint: Theme.red) }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AccountStripe(accountID: store.acting(for: pr))
            Avatar(url: pr.authorAvatar, size: 28)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if pr.isDraft { Pill(text: "Draft", tint: .secondary) }
                    Text(pr.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(verbatim: "#\(pr.number)").monospacedDigit()
                    Text("·")
                    Text(pr.author)
                    Text("·")
                    Text(pr.updatedAt.short)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ChecksGlyph(state: pr.checks).font(.caption)
                    ViewThatFits(in: .horizontal) {
                        pills
                        pills.environment(\.compactPills, true)
                    }
                    Spacer(minLength: 0)
                    ClaudeBadge(sessions: store.claudeSessions(for: pr))
                    DiffStat(additions: pr.additions, deletions: pr.deletions)
                }
            }
        }
        .padding(.vertical, 5)
    }
}

struct RunRow: View {
    @Environment(Store.self) private var store
    var run: WorkflowRun

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AccountStripe(accountID: store.acting(for: run))
            RunGlyph(phase: run.phase, size: 17)
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(run.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(run.name).fontWeight(.medium)
                    Text("·").foregroundStyle(.tertiary)
                    Text(run.repo.split(separator: "/").last.map(String.init) ?? run.repo)
                }
                .font(.caption)
                .lineLimit(1)
                HStack(spacing: 6) {
                    if let branch = run.branch {
                        Pill(text: branch, symbol: "arrow.branch", tint: Theme.blue)
                    }
                    Pill(text: run.event.replacingOccurrences(of: "_", with: " "), tint: .secondary)
                    Spacer()
                    if let actor = run.actorAvatar { Avatar(url: actor, size: 16) }
                    Text(run.createdAt.short).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .padding(.vertical, 4)
    }
}

protocol RepoScoped { var repo: String { get } }
extension PullRequest: RepoScoped {}
extension Issue: RepoScoped {}

struct IssueRow: View {
    @Environment(Store.self) private var store
    var issue: Issue

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AccountStripe(accountID: store.acting(for: issue))
            Image(systemName: "smallcircle.filled.circle")
                .font(.system(size: 17))
                .foregroundStyle(Theme.green)
                .frame(width: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text(issue.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(verbatim: "#\(issue.number)").monospacedDigit()
                    Text("·")
                    Text(issue.author)
                    Text("·")
                    Text(issue.updatedAt.short)
                    if issue.lane == .assigned {
                        Pill(text: "Assigned", symbol: "person.fill.checkmark", tint: Theme.amber)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !issue.labels.isEmpty || !issue.linked.isEmpty || issue.comments > 0 || !store.claudeSessions(for: issue).isEmpty {
                    HStack(spacing: 5) {
                        ForEach(issue.labels.prefix(3), id: \.name) { LabelChip(label: $0) }
                        Spacer(minLength: 0)
                        ClaudeBadge(sessions: store.claudeSessions(for: issue))
                        if !issue.linked.isEmpty {
                            LinkCount(items: issue.linked)
                        }
                        if issue.comments > 0 {
                            Label("\(issue.comments)", systemImage: "bubble.left")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 5)
    }
}

struct LabelChip: View {
    var label: IssueLabel

    var body: some View {
        let tint = Color(hex: "#" + label.color) ?? .secondary
        Text(label.name)
            .font(.system(size: 10.5, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.35)))
    }
}

/// "⇄ 2" with the state of the most advanced link: merged, open or closed.
struct LinkCount: View {
    var items: [LinkedItem]

    var body: some View {
        let merged = items.contains { $0.state == "MERGED" }
        let open = items.contains { $0.state == "OPEN" }
        let tint = merged ? Theme.violet : open ? Theme.blue : Color.secondary
        Label("\(items.count)", systemImage: "arrow.triangle.pull")
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .help(items.map { "\($0.relation == .closes ? "Closed by" : "Mentioned in") #\($0.number) \($0.title)" }.joined(separator: "\n"))
    }
}


/// Which repository Repositories shows: the known ones, or any you type.
struct RepoPicker: View {
    @Environment(Store.self) private var store
    @Environment(Router.self) private var router
    @State private var typing = false
    @State private var typed = ""

    var body: some View {
        HStack(spacing: 8) {
            if typing {
                TextField("owner/repo", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let name = typed.trimmingCharacters(in: .whitespaces)
                        if name.split(separator: "/").count == 2 { router.browsingRepo = name }
                        typing = false
                    }
                    .onExitCommand { typing = false }
                Button("Cancel") { typing = false }
            } else {
                Menu {
                    let byOwner = Dictionary(grouping: store.visibleRepos) { $0.nameWithOwner.split(separator: "/").first.map(String.init) ?? "" }
                    ForEach(byOwner.keys.sorted(), id: \.self) { owner in
                        Section(owner) {
                            ForEach(byOwner[owner] ?? [], id: \.nameWithOwner) { repo in
                                Button(repo.nameWithOwner.split(separator: "/").last.map(String.init) ?? repo.nameWithOwner) {
                                    router.browsingRepo = repo.nameWithOwner
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Other repository…") { typed = router.browsingRepo ?? ""; typing = true }
                } label: {
                    Label(router.browsingRepo ?? "Pick a repository", systemImage: "book.closed")
                }
                .menuStyle(.button)
                Spacer()
                if let repo = router.browsingRepo {
                    if let at = store.repoPulls[repo]?.at {
                        Text(at.short == "now" ? "just now" : at.short + " ago").font(.caption).foregroundStyle(.tertiary)
                    }
                    Button { Task { await store.loadRepoPulls(repo) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .disabled(store.loadingRepoPulls.contains(repo))
                        .help("Reload")
                }
            }
        }
    }
}

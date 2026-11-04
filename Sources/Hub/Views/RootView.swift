import HubKit
import SwiftUI

struct RootView: View {
    @Environment(Store.self) private var store
    @Environment(Router.self) private var router
    @State private var query = ""

    var body: some View {
        @Bindable var router = router
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } content: {
            Group {
                if router.section == .claude {
                    ClaudeColumn(query: query)
                } else {
                    ListColumn(section: router.section ?? .reviews, query: query)
                }
            }
                .navigationSplitViewColumnWidth(min: 360, ideal: 440, max: 620)
        } detail: {
            DetailColumn()
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Filter by title, repo, author, branch")
        .toolbar {
            ToolbarItem(placement: .principal) {
                AccountTabs()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { router.showDispatch = true } label: {
                    Label("Run workflow", systemImage: "play.circle")
                }
                .help("Run a workflow (⇧⌘N)")
                Button { Task { await store.refresh() } } label: {
                    if store.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .help(store.lastRefresh.map { "Refreshed \($0.short) ago (⌘R)" } ?? "Refresh (⌘R)")
            }
        }
        .sheet(isPresented: $router.showDispatch) { DispatchSheet() }
        .sheet(isPresented: $router.showQuickOpen) { QuickOpenView() }
        .onAppear {
            store.claude.showTerminal = { id in router.open(.claude, .terminal(id)) }
        }
        .sheet(item: Binding(
            get: { router.repoFocusAccount.map(SheetID.init) },
            set: { router.repoFocusAccount = $0?.id })
        ) { sheet in
            RepoFocusSheet(accountID: sheet.id)
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                ToastView(toast: toast)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(.spring(duration: 0.35), value: store.toast)
        .onChange(of: router.section) { _, _ in router.selection = nil }
        .onChange(of: store.claude.lastScan) { _, _ in
            guard ProcessInfo.processInfo.environment["HUB_DEV_SELECT"] == "claude",
                  let pr = (store.visibleReviews + store.visibleMine).first(where: { !store.claudeSessions(for: $0).isEmpty })
            else { return }
            router.open(pr.lane == .reviewRequested ? .reviews : .mine, .pr(pr))
        }
        .onChange(of: store.activeScope) { _, _ in
            // Keep the open item only if the new account can see it.
            switch router.selection {
            case .pr(let pr) where router.section != .repos && !(store.visibleReviews + store.visibleReviewed + store.visibleMine).contains(where: { $0.nodeID == pr.nodeID }):
                router.selection = nil
            case .run(let run) where !store.visibleRuns.contains(where: { $0.id == run.id }):
                router.selection = nil
            case .issue(let issue) where !store.visibleIssues.contains(where: { $0.nodeID == issue.nodeID }):
                router.selection = nil
            default:
                break
            }
        }
        .onChange(of: store.lastRefresh) { _, _ in
            // HUB_DEV_SELECT=pr|run|focus opens the first item, to look at a detail screen without clicking.
            guard router.selection == nil, let pick = ProcessInfo.processInfo.environment["HUB_DEV_SELECT"] else { return }
            if pick.hasPrefix("pr="), let pr = (store.reviewRequests + store.reviewedPulls + store.myPulls).first(where: { "\($0.repo)#\($0.number)" == pick.dropFirst(3) }) {
                router.open(pr.lane == .reviewRequested ? .reviews : .mine, .pr(pr))
            } else if pick.hasPrefix("pr=") {
                let name = String(pick.dropFirst(3))
                Task { if let target = await devResolve(name) { router.open(target.0, target.1) } }
            } else if pick.hasPrefix("repo=") {
                router.browse(String(pick.dropFirst(5)))
            } else if pick == "claudeterm" {
                // Claude's welcome screen in Hub's terminal; nothing is sent.
                try? store.claude.openShell(in: FileManager.default.currentDirectoryPath, title: "GH Hub Claude test", repo: nil,
                                            command: store.claude.claudeCommand(nil))
            } else if pick == "terminal" {
                try? store.claude.openShell(in: CpxConfig.home, title: "GH Hub test shell", repo: nil)
            } else if pick == "claudepane" {
                router.section = .claude
            } else if pick == "claude", let pr = (store.visibleReviews + store.visibleMine).first(where: { !store.claudeSessions(for: $0).isEmpty }) {
                router.open(pr.lane == .reviewRequested ? .reviews : .mine, .pr(pr))
            } else if pick == "issue", let issue = store.visibleIssues.first(where: { !$0.linked.isEmpty }) ?? store.visibleIssues.first {
                router.open(.issues, .issue(issue))
            } else if pick == "linkedpr", let pr = store.visibleMine.first(where: { !store.linkedIssues(of: $0).isEmpty }) {
                router.open(.mine, .pr(pr))
            } else if pick == "focus" {
                router.repoFocusAccount = store.accounts.last?.id
            } else if pick == "run", let run = store.failingRuns.first {
                router.section = .actions
                DispatchQueue.main.async { router.selection = .run(run) }
            } else if let pr = store.visibleReviews.first {
                router.selection = .pr(pr)
            }
        }
    }
}

struct SidebarView: View {
    @Environment(Store.self) private var store
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        List(selection: $router.section) {
            SwiftUI.Section {
                ForEach(Pane.allCases) { section in
                    HStack(spacing: 10) {
                        Image(systemName: section.symbol)
                            .font(.system(size: 17))
                            .foregroundStyle(section.tint.gradient)
                            .frame(width: 22)
                        Text(section.title)
                        Spacer()
                        CountBadge(count: count(section), tint: badgeTint(section))
                    }
                    .padding(.vertical, 3)
                    .tag(section)
                }
            } header: {
                Text("Inbox")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                if let error = store.setupError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.red)
                }
                HStack(spacing: 6) {
                    Circle().fill(store.isRefreshing ? Theme.amber : Theme.green).frame(width: 6, height: 6)
                    Text(store.isRefreshing ? "Syncing…" : store.lastRefresh.map { "Synced \($0.short == "now" ? "just now" : "\($0.short) ago")" } ?? "Not synced yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    SettingsLink { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless)
                }
            }
            .padding(12)
        }
    }

    private func count(_ section: Pane) -> Int {
        switch section {
        case .reviews: store.visibleReviews.count
        case .mine: store.visibleMine.count
        case .repos: 0
        case .issues: store.visibleIssues.filter { $0.lane == .assigned }.count
        case .actions: store.failingRuns.filter(store.isMine).count
        case .waiting: store.waitingRuns.count
        case .claude: store.claude.terminals.running.count + store.claude.liveSessions.count
        }
    }

    private func badgeTint(_ section: Pane) -> Color {
        section == .actions ? Theme.red : section == .claude ? Theme.green : section.tint
    }
}

struct SheetID: Identifiable {
    var id: String
}

extension RootView {
    /// HUB_DEV_SELECT=pr=owner/repo#n for a pull request Hub hasn't loaded.
    func devResolve(_ name: String) async -> (Pane, Selection)? {
        let url = "https://github.com/" + name.replacingOccurrences(of: "#", with: "/pull/")
        guard let link = GitHubLink.parse(url) else { return nil }
        return await store.resolve(link)
    }
}

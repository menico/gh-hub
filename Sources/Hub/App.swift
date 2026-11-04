import AppKit
import HubKit
import SwiftUI

@main
struct HubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store: Store
    @State private var router: Router
    @Environment(\.openWindow) private var openWindow

    init() {
        // Before Store or Router reads any preference.
        Migration.run()
        _store = State(initialValue: Store())
        _router = State(initialValue: Router())
    }

    var body: some Scene {
        Window("GH Hub", id: "main") {
            RootView()
                .environment(\.openURL, SafeLinks.action)
                .environment(store)
                .environment(router)
                .frame(minWidth: 980, minHeight: 600)
                .task {
                    store.start()
                    GlobalHotKey.shared.action = { [router] in
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: "main")
                        router.showQuickOpen = true
                    }
                    GlobalHotKey.shared.apply()
                }
                .task {
                    // Every half hour: finished worktrees (merged or closed, nothing left in them) go.
                    try? await Task.sleep(for: .seconds(45))
                    while !Task.isCancelled {
                        await store.scanWorktrees()
                        try? await Task.sleep(for: .seconds(1800))
                    }
                }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await store.refresh() } }
                    .keyboardShortcut("r")
            }
            CommandMenu("Go") {
                ForEach(Array(Pane.allCases.enumerated()), id: \.element) { index, section in
                    Button(section.title) { router.section = section }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
                Divider()
                Button("Run Workflow…") { router.showDispatch = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Quick Open…") { router.showQuickOpen = true }
                    .keyboardShortcut("k")
            }
            CommandMenu("Account") {
                Button("All Accounts") { store.scope = nil }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                ForEach(Array(store.shownAccounts.enumerated()), id: \.element.id) { index, state in
                    Button(store.name(state.id)) { store.scope = state.id }
                        .keyboardShortcut(KeyEquivalent(Character("\(min(index + 1, 9))")), modifiers: [.command, .option])
                }
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(store)
                .environment(router)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--probe") { probe() }
        if CommandLine.arguments.contains("--probe-review") { probeReview() }
        if let i = CommandLine.arguments.firstIndex(of: "--probe-thread"), i + 1 < CommandLine.arguments.count {
            probeThread(CommandLine.arguments[i + 1])
        }
        if CommandLine.arguments.contains("--probe-guard") {
            // Writes the review guard and prints the PATH a review gets.
            print(ReviewGuard.environment(ShellEnv.environment())["PATH"] ?? "")
            exit(0)
        }
        // Running straight from `swift run` gives no bundle; behave like an app anyway.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// `hub-app --probe-thread owner/repo#n`: Claude checks the first thread
    /// waiting on you. Prints the result; posts nothing.
    private func probeThread(_ name: String) {
        Task { @MainActor in
            let store = Store()
            store.persists = false
            await store.connect()
            await store.claude.scan()
            let parts = name.split(separator: "#")
            guard parts.count == 2, let number = Int(parts[1]) else { print("usage: owner/repo#n"); exit(1) }
            for state in store.accounts {
                guard let client = store.client(state.id),
                      let pr = try? await client.pullRequest(repo: String(parts[0]), number: number, lane: .reviewRequested),
                      let c = try? await client.conversation(of: pr) else { continue }
                let login = client.account.login
                guard let thread = c.threads.first(where: { $0.waitsOn(login) }) else { continue }
                print("thread \(thread.path):\(thread.line ?? -1) comments \(thread.comments.count) hunk \(thread.diffHunk?.count ?? 0) chars")
                let files = (try? await client.files(of: pr)) ?? []
                let start = Date.now
                do {
                    let check = try await store.reviewer.check(thread, on: pr, reviewer: login, files: files, claude: store.claude,
                                                               accountID: state.id, persona: .architect)
                    print("in \(Int(Date.now.timeIntervalSince(start)))s addressed=\(check.addressed) resolve=\(check.resolve)")
                    print("assessment:", check.assessment)
                    print("reply:", check.reply)
                } catch { print("failed:", error.localizedDescription) }
                exit(0)
            }
            print("no thread waiting"); exit(0)
        }
    }

    /// `hub-app --probe-review`: the review pieces against real data.
    /// HUB_PROBE_CLAUDE=1 also runs a Claude review on the smallest PR.
    private func probeReview() {
        Task { @MainActor in
            let store = Store()
            store.persists = false
            await store.connect()
            await store.refresh()
            await store.claude.scan()
            let prs = (store.reviewRequests + store.myPulls)
            var threads = 0, timeline = 0, failures = 0
            for pr in prs.prefix(12) {
                guard let client = store.client(store.acting(for: pr)) else { continue }
                do {
                    let c = try await client.conversation(of: pr)
                    threads += c.threads.count; timeline += c.timeline.count
                    if !c.threads.isEmpty || c.mergeState == "BEHIND" {
                        print("  \(pr.repo)#\(pr.number): threads \(c.threads.count) (open \(c.threads.filter { !$0.isResolved }.count), outdated \(c.threads.filter { $0.line == nil }.count)) timeline \(c.timeline.count) merge \(c.mergeState) autoMerge \(c.canEnableAutoMerge) update \(c.canUpdateBranch) suggested \(c.suggestedReviewers.map(\.login))")
                    }
                } catch { failures += 1; print("  conversation failed", pr.repo, pr.number, error.localizedDescription) }
            }
            print("conversations: threads \(threads) timeline \(timeline) failures \(failures)")
            if let pr = prs.first, let client = store.client(store.acting(for: pr)) {
                let link = GitHubLink.parse(pr.url.absoluteString)!
                let resolved = await store.resolve(link)
                print("link resolves:", resolved.map { "\($0.0)" } ?? "nil")
                let fetched = try? await client.pullRequest(repo: pr.repo, number: pr.number, lane: .reviewRequested)
                print("single PR fetch:", fetched?.title ?? "failed")
            }
            if let issue = store.issues.first, let client = store.client(store.acting(for: issue)) {
                print("single issue fetch:", (try? await client.issue(repo: issue.repo, number: issue.number))?.title ?? "failed")
            }
            if let run = store.runs.first, let client = store.client(store.acting(for: run)) {
                print("single run fetch:", (try? await client.run(repo: run.repo, id: run.id))?.name ?? "failed")
            }
            await store.scanWorktrees()
            print("worktrees:", store.worktrees.count, store.worktrees.prefix(8).map { "\($0.repo)/\($0.worktree.name)=\($0.prState ?? "-") clean:\($0.changes.isClean)" })
            print("live sessions:", store.claude.liveSessions.count)
            print("editors:", Editor.installed.map(\.name), "terminals:", TerminalChoice.allCases.filter(\.isInstalled).map(\.label))
            let look = TerminalLook.fromGhostty()
            print("look:", look.fontFamily ?? "-", look.fontSize, look.background, look.palette.count)
            let env = ShellEnv.environment()
            print("PATH has claude:", (env["PATH"] ?? "").split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: "\($0)/claude") })

            if ProcessInfo.processInfo.environment["HUB_PROBE_CLAUDE"] != nil,
               let pr = prs.filter({ $0.additions + $0.deletions > 5 }).min(by: { $0.additions + $0.deletions < $1.additions + $1.deletions }),
               let client = store.client(store.acting(for: pr)) {
                let files = (try? await client.files(of: pr)) ?? []
                print("reviewing \(pr.repo)#\(pr.number) (+\(pr.additions) −\(pr.deletions), \(files.count) files)…")
                let started = Date.now
                store.reviewer.discard(pr)
                let mode = ClaudeReviewer.Mode(rawValue: ProcessInfo.processInfo.environment["HUB_PROBE_MODE"] ?? "") ?? .quick
                let token = try? await GHCLI.token(for: store.account(store.acting(for: pr))!.account)
                store.reviewer.review(pr, files: files, head: nil, claude: store.claude, accountID: store.acting(for: pr), focus: nil,
                                      mode: mode, ghToken: token)
                while store.reviewer.isRunning(pr) { try? await Task.sleep(for: .seconds(1)) }
                print(String(format: "took %.0fs", Date.now.timeIntervalSince(started)))
                switch store.reviewer.state(for: pr) {
                case .done(let review):
                    print("verdict:", review.verdict, "cost:", review.costUSD ?? -1)
                    print("summary:", review.summary)
                    print("risks:", review.risks.map { "\($0.level): \($0.text)" })
                    print("comments:", review.comments.map { "\($0.path):\($0.line) \($0.side?.rawValue ?? "") \($0.body.prefix(80))" })
                case .failed(let message): print("review failed:", message)
                default: print("review state?")
                }
            }
            exit(0)
        }
    }

    /// `hub-app --probe`: fetch everything once, print a summary, and quit.
    private func probe() {
        Task { @MainActor in
            let store = Store()
            store.persists = false
            store.focus = [:]
            // HUB_PROBE_FOCUS="github.com/login=owner/repo,owner/other" limits one account.
            if let spec = ProcessInfo.processInfo.environment["HUB_PROBE_FOCUS"], let eq = spec.firstIndex(of: "=") {
                let repos = spec[spec.index(after: eq)...].split(separator: ",").map(String.init)
                store.focus = [String(spec[..<eq]): .init(enabled: true, repos: repos)]
            }
            await store.connect()
            await store.refresh()
            @MainActor func usage(_ label: String) {
                for state in store.accounts {
                    let u = store.client(state.id)?.cache.snapshot
                    let core = u?.rates["core"]
                    print("\(label) \(state.account.login): requests \(u?.requests ?? 0), unchanged \(u?.notModified ?? 0), core left \(core?.remaining ?? -1)/\(core?.limit ?? -1)")
                }
            }
            usage("after 1st refresh")
            await store.refresh()
            usage("after 2nd refresh")
            print("setup error:", store.setupError ?? "none")
            let started = Date.now
            await store.claude.scan()
            let first = Date.now.timeIntervalSince(started)
            let again = Date.now
            await store.claude.scan()
            print(String(format: "claude scan %.1fs, rescan %.1fs", first, Date.now.timeIntervalSince(again)),
                  "sessions:", store.claude.sessions.count, "with repo:", store.claude.sessionRepo.count,
                  "clones:", store.claude.clones.count, "folders:", store.claude.codeFolders)
            let prs = store.reviewRequests + store.myPulls
            let matchedPRs = prs.filter { !store.claudeSessions(for: $0).isEmpty }
            print("PRs with sessions:", matchedPRs.count, "of", prs.count, matchedPRs.prefix(4).map { "\($0.repo)#\($0.number)=\(store.claudeSessions(for: $0).count)" })
            let matchedIssues = store.issues.filter { !store.claudeSessions(for: $0).isEmpty }
            print("issues with sessions:", matchedIssues.count, "of", store.issues.count, matchedIssues.prefix(4).map { "\($0.repo)#\($0.number)=\(store.claudeSessions(for: $0).count)" })
            if ProcessInfo.processInfo.environment["HUB_NO_OPEN"] != nil,
               let pr = store.myPulls.first,
               let owner = store.accounts.first(where: { $0.id == pr.accountID }) {
                let path = try? store.claude.launch(.init(title: "#\(pr.number) \(pr.title)", repo: pr.repo, account: owner.account,
                                                          worktree: "pr-\(pr.number)", setup: .pullRequest(pr.number, base: pr.baseRef),
                                                          prompt: Prompts.reviewComments(pr)))
                print("launch script:", path ?? "failed")
            }
            for repo in Array(Set(prs.map(\.repo))).sorted().prefix(3) {
                let clone = store.claude.clonePath(for: repo)
                let profile = store.claude.profile(for: store.accounts.last?.id ?? "", clone: clone.path)
                print("clone", repo, clone.path, clone.exists, "profile", profile?.name ?? "default")
            }
            print("issues:", store.issues.count, "assigned:", store.issues.filter { $0.lane == .assigned }.count,
                  "with linked PRs:", store.issues.filter { !$0.linked.isEmpty }.count,
                  "PRs with linked issues:", (store.reviewRequests + store.myPulls).filter { !store.linkedIssues(of: $0).isEmpty }.count)
            for state in store.accounts { print("account", state.account.login, state.error ?? "ok") }
            print("review requests:", store.reviewRequests.count, "mine:", store.myPulls.count,
                  "repos:", store.repos.count, "runs:", store.runs.count,
                  "failing:", store.failingRuns.count, "waiting:", store.waitingRuns.count)
            for state in store.accounts {
                store.scope = state.id
                let all = (try? await store.client(state.id)?.repositories())?.count ?? -1
                print("  \(state.account.login): reviews \(store.visibleReviews.count) reviewed \(store.visibleReviewed.count) \(store.visibleReviewed.prefix(3).map { "#\($0.number) \($0.myReview?.rawValue ?? "-")" }) mine \(store.visibleMine.count) runs \(store.visibleRuns.count) run-repos \(Set(store.visibleRuns.map(\.repo)).sorted()) reachable-repos \(all)")
            }
            store.scope = nil
            for pr in store.reviewRequests.prefix(0) { print("  review", pr.repo, pr.number, pr.title) }

            if let repo = store.repos.first, let client = store.client(repo.accountID) {
                let flows = (try? await client.dispatchableWorkflows(in: repo)) ?? []
                print("dispatchable in", repo.nameWithOwner, flows.map { "\($0.workflow.name)(\($0.inputs.count))" })
            }
            exit(0)
        }
    }
}

struct MenuBarLabel: View {
    var store: Store

    var body: some View {
        let reviews = store.allReviews.count
        let waiting = store.allWaiting.count
        let count = reviews + waiting
        HStack(spacing: 3) {
            Image(systemName: !store.allFailingMine.isEmpty ? "exclamationmark.circle.fill" : "arrow.triangle.pull")
            if count > 0 { Text("\(count)").monospacedDigit() }
        }
        .task { store.start() }
    }
}

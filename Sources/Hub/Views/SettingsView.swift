import SwiftUI
import HubKit

struct SettingsView: View {
    @Environment(Store.self) private var store
    @AppStorage("pollSeconds") private var pollSeconds = 90.0
    @AppStorage("activeDays") private var activeDays = 14.0
    @AppStorage("repoLimit") private var repoLimit = 15.0
    @AppStorage("notify") private var notify = true
    @State private var focusAccount: String?
    @AppStorage("codeFolders") private var codeFolders = ""
    @AppStorage("cloneFolder") private var cloneFolder = ""
    @AppStorage("terminal") private var terminal = TerminalChoice.hub.rawValue
    @AppStorage("editor") private var editor = ""
    @AppStorage("hotKey") private var hotKey = GlobalHotKey.Choice.ctrlOptH.rawValue

    var body: some View {
        let _ = store.claude.revision
        Form {
            SwiftUI.Section {
                Picker("Check GitHub every", selection: $pollSeconds) {
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("90 seconds").tag(90.0)
                    Text("3 minutes").tag(180.0)
                    Text("5 minutes").tag(300.0)
                }
                Toggle("Notify on review requests, failed runs and pending approvals", isOn: $notify)
                Picker("Bring GH Hub forward with ⌘K open", selection: $hotKey) {
                    ForEach(GlobalHotKey.Choice.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .onChange(of: hotKey) { _, value in GlobalHotKey.shared.apply(GlobalHotKey.Choice(rawValue: value) ?? .off) }
            } header: {
                Text("Refresh")
            } footer: {
                Text("GitHub has no push for desktop apps, so GH Hub asks. Each question carries the answer's fingerprint (ETag); an unchanged answer costs nothing against the rate limit. GH Hub checks every 30 seconds while a run is going, a third as often in the background, and backs off when an account runs low.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section {
                Stepper("Repositories pushed in the last \(Int(activeDays)) days", value: $activeDays, in: 1...90)
                Stepper("At most \(Int(repoLimit)) per account", value: $repoLimit, in: 1...60)
            } header: {
                Text("Actions")
            } footer: {
                Text("For accounts on Recent activity, runs come from recently pushed repositories and from repositories with your open pull requests. An account limited to selected repositories watches exactly those.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section {
                Picker("Start Claude in", selection: $terminal) {
                    ForEach(TerminalChoice.allCases.filter(\.isInstalled)) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Open folders in", selection: $editor) {
                    Text("First installed").tag("")
                    ForEach(Editor.installed) { Text($0.name).tag($0.bundleID) }
                }
                LabeledContent("Code folders") {
                    TextField("", text: $codeFolders, prompt: Text(ClaudeLink.defaultCodeFolders.joined(separator: "\n")), axis: .vertical)
                        .lineLimit(2...5)
                }
                LabeledContent("New clones go to") {
                    TextField("", text: $cloneFolder, prompt: Text(ClaudeLink.defaultCloneFolder))
                }
                ForEach(store.accounts) { state in
                    Picker("Profile for \(store.name(state.id))", selection: Binding(
                        get: { UserDefaults.standard.string(forKey: "claudeProfile.\(state.id)") ?? "" },
                        set: { UserDefaults.standard.set($0, forKey: "claudeProfile.\(state.id)"); store.objectWillChangeClaude() })
                    ) {
                        Text("Automatic (cpx binding)").tag("")
                        Text("claude (default)").tag("default")
                        ForEach(store.claude.cpx.profiles, id: \.name) { p in
                            Text(p.name + "  " + UsageGauge.text(store.claude.usage.account(p.name))).tag(p.name)
                        }
                    }
                }
                LabeledContent("Profiles") {
                    HStack {
                        if store.claude.usage.writtenAt == nil {
                            Text(ClaudeLink.cpxAppInstalled ? "Open cpx to see each profile's usage here." : "Install cpx-app to see each profile's usage here.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if ClaudeLink.cpxAppInstalled {
                            Button("Manage profiles in cpx…") { ClaudeLink.openCpxApp() }
                        }
                    }
                }
                LabeledContent("Show sessions from") {
                    VStack(alignment: .trailing, spacing: 4) {
                        let hidden = ClaudeLink.hiddenSessionDirs
                        ForEach(store.claude.cpx.configDirs, id: \.self) { dir in
                            Toggle(store.claude.label(forConfigDir: dir), isOn: Binding(
                                get: { !hidden.contains(ClaudeLink.key(forConfigDir: dir)) },
                                set: { store.claude.setSessionsShown($0, configDir: dir); store.objectWillChangeClaude() }))
                                .toggleStyle(.checkbox)
                                .help(dir.abbreviatingHome)
                        }
                    }
                }
                HStack {
                    Text("\(store.claude.clones.count) repositories cloned, \(store.claude.sessions.count) sessions in the last 60 days")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Rescan") { Task { await store.claude.scan() } }
                        .disabled(store.claude.scanning)
                }
            } header: {
                Text("Claude")
            } footer: {
                Text("GH Hub looks for clones in the code folders (one per line) and in cpx's bound folders, and reads Claude Code's session files to match sessions to branches. Sessions from an unticked profile stay out of GH Hub: the Claude tab, pull requests and ⌘K. Claude runs in a worktree next to the clone (<repo>-worktrees/pr-123), with gh signed in as the account. Inside GH Hub, the terminal uses Ghostty's font and colours.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            PersonaSettings()
            SwiftUI.Section {
                ForEach(store.accounts) { state in
                    AccountSettingsRow(state: state) { focusAccount = state.id }
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text("GH Hub uses every account signed in to the gh command; add one with `gh auth login`. A hidden account is left out of the tabs, the menu bar and notifications.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 720)
        .sheet(item: Binding(get: { focusAccount.map(SheetID.init) }, set: { focusAccount = $0?.id })) { sheet in
            RepoFocusSheet(accountID: sheet.id)
        }
    }
}

struct AccountSettingsRow: View {
    @Environment(Store.self) private var store
    var state: Store.AccountState
    var chooseRepos: () -> Void

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Avatar(url: state.avatar, size: 26)
                Circle().fill(Theme.color(for: state.id)).frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
            }
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: Binding(
                    get: { store.aliases[state.id] ?? "" },
                    set: { store.aliases[state.id] = $0.isEmpty ? nil : $0 }),
                    prompt: Text(state.account.login))
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                Text(state.error ?? "\(state.account.login) · \(state.account.host)")
                    .font(.caption)
                    .foregroundStyle(state.error == nil ? Color.secondary : Theme.red)
                    .lineLimit(1)
                if let usage = state.usage {
                    UsageLine(usage: usage)
                }
                Button {
                    chooseRepos()
                } label: {
                    Label(store.focusSummary(state.id), systemImage: store.focusedRepos(state.id) == nil ? "clock.arrow.circlepath" : "scope")
                        .font(.caption)
                }
                .buttonStyle(.link)
                .help("Choose which repositories this account shows")
            }
            Spacer()
            Toggle("Show", isOn: Binding(
                get: { !store.hiddenAccounts.contains(state.id) },
                set: { if $0 { store.hiddenAccounts.remove(state.id) } else { store.hiddenAccounts.insert(state.id) } }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

/// "4,812 of 5,000 calls left this hour · 71% answered from cache".
struct UsageLine: View {
    var usage: ResponseCache.Stats

    var body: some View {
        HStack(spacing: 6) {
            if let core = usage.rates["core"] {
                let share = Double(core.remaining) / Double(max(core.limit, 1))
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .foregroundStyle(share < 0.1 ? Theme.red : share < 0.25 ? Theme.amber : Theme.green)
                Text("\(core.remaining.formatted()) of \(core.limit.formatted()) calls left, resets \(core.reset.formatted(date: .omitted, time: .shortened))")
            }
            if usage.requests > 0 {
                Text("· \(Int((Double(usage.notModified) / Double(usage.requests) * 100).rounded()))% unchanged, free")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
}

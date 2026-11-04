import AppKit
import HubKit
import SwiftUI

/// Claude on this Mac: terminals running inside Hub, sessions working right
/// now, recent sessions, and the worktrees Hub made.
struct ClaudeColumn: View {
    @Environment(Store.self) private var store
    @Environment(Router.self) private var router
    var query: String
    @State private var confirmCleanup = false

    var body: some View {
        @Bindable var router = router
        let claude = store.claude
        let live = claude.liveSessions
        let recent = claude.sessions.sorted { $0.updatedAt > $1.updatedAt }.filter { !claude.isLive($0) }.prefix(15)
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            List(selection: $router.selection) {
                if !claude.terminals.sessions.isEmpty {
                    SwiftUI.Section("In GH Hub") {
                        ForEach(claude.terminals.sessions) { session in
                            TerminalRow(session: session).tag(Selection.terminal(session.id))
                                .contextMenu {
                                    Button("Close", role: .destructive) { claude.terminals.close(session.id) }
                                }
                        }
                    }
                }
                SwiftUI.Section("Working now") {
                    if live.isEmpty {
                        Text("No session has written in the last two minutes.").font(.caption).foregroundStyle(.tertiary)
                    }
                    ForEach(filter(live)) { session in
                        SessionListRow(session: session, live: true).tag(Selection.session(session.id))
                    }
                }
                SwiftUI.Section {
                    if store.worktrees.isEmpty {
                        Text(store.scanningWorktrees ? "Looking…" : "No worktrees made by GH Hub.").font(.caption).foregroundStyle(.tertiary)
                    }
                    ForEach(store.worktrees.filter { query.isEmpty || $0.worktree.path.localizedCaseInsensitiveContains(query) || $0.repo.localizedCaseInsensitiveContains(query) }) { item in
                        WorktreeRow(item: item).tag(Selection.worktree(item.id))
                            .contextMenu { WorktreeMenu(item: item) }
                    }
                } header: {
                    HStack {
                        Text("Worktrees")
                        Spacer()
                        if !removable.isEmpty {
                            Button("Clean up \(removable.count)") { confirmCleanup = true }
                                .buttonStyle(.link)
                                .help("Remove worktrees whose pull request is merged or closed and that have no local changes")
                        }
                    }
                }
                SwiftUI.Section("Recent sessions") {
                    ForEach(filter(Array(recent))) { session in
                        SessionListRow(session: session, live: false).tag(Selection.session(session.id))
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
        .background(.background)
        .task { await store.scanWorktrees() }
        .confirmationDialog("Remove \(removable.count) finished worktrees?", isPresented: $confirmCleanup) {
            Button("Remove \(removable.count)", role: .destructive) {
                Task { for item in removable { await store.removeWorktree(item, force: false) } }
            }
        } message: {
            Text(removable.map { "\($0.repo.split(separator: "/").last ?? "") / \($0.worktree.name)" }.joined(separator: "\n")
                 + "\n\nTheir pull requests are merged or closed and nothing in them is uncommitted or unpushed. Branches stay.")
        }
    }

    private var removable: [WorktreeItem] { store.worktrees.filter { $0.isDone && $0.changes.isClean } }

    private func filter(_ sessions: [ClaudeSession]) -> [ClaudeSession] {
        guard !query.isEmpty else { return sessions }
        return sessions.filter { s in
            ([s.prompt, s.cwd] + s.branches).contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Claude").font(.system(size: 22, weight: .bold, design: .rounded))
            Spacer()
            if store.claude.scanning || store.scanningWorktrees { ProgressView().controlSize(.small) }
            Button {
                Task { await store.claude.scan(); await store.scanWorktrees() }
            } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Rescan sessions and worktrees")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

struct LiveDot: View {
    var color: Color = Theme.green
    @State private var pulse = false

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .overlay(Circle().stroke(color.opacity(0.5), lineWidth: 2).scaleEffect(pulse ? 2.2 : 1).opacity(pulse ? 0 : 1))
            .onAppear { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true } }
    }
}

struct TerminalRow: View {
    var session: TerminalSession

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal.fill").foregroundStyle(Theme.claude)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).lineLimit(1)
                Text(session.repo ?? session.directory?.abbreviatingHome ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if session.running { LiveDot() } else {
                Text(session.exitCode.map { "exited \($0)" } ?? "ended").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct SessionListRow: View {
    @Environment(Store.self) private var store
    var session: ClaudeSession
    var live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if live { LiveDot() }
                Text(session.prompt.isEmpty ? "(no prompt)" : session.prompt).lineLimit(2)
            }
            HStack(spacing: 5) {
                ProfileChip(name: store.claude.profileName(forSession: session), color: store.claude.profileColor(forSession: session))
                if let branch = session.branches.last { BranchChip(name: branch) }
                Text(store.claude.sessionRepo[session.id] ?? session.cwd.abbreviatingHome).lineLimit(1).truncationMode(.head)
                Spacer()
                Text(session.updatedAt.short).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

struct WorktreeRow: View {
    var item: WorktreeItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").foregroundStyle(item.isDone ? Color.secondary : Theme.blue)
                Text(item.worktree.name).fontWeight(.medium)
                Text(item.repo).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                WorktreeStatePill(item: item)
            }
            HStack(spacing: 6) {
                if let branch = item.worktree.branch { BranchChip(name: branch) } else { Text("detached") }
                ChangesLabel(changes: item.changes)
                Spacer()
                if let modified = item.modified { Text(modified.short).monospacedDigit() }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

struct WorktreeStatePill: View {
    var item: WorktreeItem
    var body: some View {
        switch item.prState {
        case "MERGED": Pill(text: "Merged", symbol: "arrow.triangle.merge", tint: Theme.violet)
        case "CLOSED": Pill(text: "Closed", symbol: "xmark.circle", tint: .secondary)
        case "OPEN": Pill(text: "Open", symbol: "arrow.triangle.pull", tint: Theme.green)
        default: item.isStale ? Pill(text: "Idle 2w+", tint: Theme.amber) : Pill(text: "No PR", tint: .secondary)
        }
    }
}

struct ChangesLabel: View {
    var changes: WorktreeChanges
    var body: some View {
        if changes.isClean {
            Label("clean", systemImage: "checkmark").labelStyle(.titleAndIcon)
        } else {
            let parts = [changes.modifiedFiles > 0 ? "\(changes.modifiedFiles) changed" : nil,
                         (changes.unpushedCommits ?? 0) > 0 ? "\(changes.unpushedCommits!) unpushed" : nil].compactMap { $0 }
            Label(parts.joined(separator: ", "), systemImage: "exclamationmark.circle").foregroundStyle(Theme.amber)
        }
    }
}

struct WorktreeMenu: View {
    @Environment(Store.self) private var store
    @Environment(Router.self) private var router
    var item: WorktreeItem
    var body: some View {
        OpenInEditorMenu(path: item.worktree.path)
        Button("Open shell here") {
            try? store.claude.openShell(in: item.worktree.path, title: item.worktree.name, repo: item.repo)
        }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.worktree.path)]) }
        Divider()
        if item.changes.isClean {
            Button("Remove worktree", role: .destructive) { Task { await store.removeWorktree(item, force: false) } }
        } else {
            // Uncommitted or unpushed work: removing goes through the detail view, which asks first.
            Button("Remove worktree…") { router.selection = .worktree(item.id) }
        }
    }
}

/// "Open in Zed", or a menu of every editor installed.
struct OpenInEditorMenu: View {
    var path: String
    var body: some View {
        ForEach(Editor.installed) { editor in
            Button("Open in \(editor.name)") { editor.open(path) }
        }
    }
}

struct OpenInButton: View {
    var path: String
    var body: some View {
        if let editor = Editor.preferred {
            Menu {
                OpenInEditorMenu(path: path)
            } label: {
                Label("Open in \(editor.name)", systemImage: "chevron.left.forwardslash.chevron.right")
            } primaryAction: {
                editor.open(path)
            }
            .fixedSize()
            .help(path.abbreviatingHome)
        }
    }
}

// MARK: Details

struct TerminalDetailView: View {
    @Environment(Store.self) private var store
    @Environment(Router.self) private var router
    var session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill").foregroundStyle(Theme.claude)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title).font(.headline).lineLimit(1)
                    Text([session.repo, session.directory?.abbreviatingHome].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer()
                if session.running { LiveDot() } else { Text("Ended").font(.caption).foregroundStyle(.secondary) }
                if let dir = session.directory { OpenInButton(path: dir) }
                Button {
                    store.claude.terminals.close(session.id)
                    router.selection = nil
                } label: { Label(session.running ? "Close" : "Remove", systemImage: "xmark") }
                    .help(session.running ? "Ends the process" : "")
            }
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.bar)
            Divider()
            TerminalPane(session: session)
        }
    }
}

struct SessionDetailView: View {
    @Environment(Store.self) private var store
    @Environment(Router.self) private var router
    var session: ClaudeSession

    var body: some View {
        let claude = store.claude
        let repo = claude.sessionRepo[session.id]
        let prs = (store.reviewRequests + store.myPulls).filter { pr in
            pr.repo.lowercased() == repo && session.branches.contains(pr.headRef)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    if claude.isLive(session) { LiveDot(); Text("Working now").foregroundStyle(Theme.green) }
                    ProfileChip(name: claude.profileName(forSession: session), color: claude.profileColor(forSession: session))
                    Spacer()
                    Text("started \(session.startedAt.short) ago · last write \(session.updatedAt.short) ago").font(.caption).foregroundStyle(.tertiary)
                }
                Text(session.prompt.isEmpty ? "(no prompt)" : session.prompt)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .textSelection(.enabled)
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Folder") { Text(session.cwd.abbreviatingHome).textSelection(.enabled) }
                    if let repo { LabeledContent("Repository") { Text(repo) } }
                    LabeledContent("Branches") { HStack { ForEach(session.branches, id: \.self) { BranchChip(name: $0) } } }
                    LabeledContent("Session") { Text(session.id).font(.caption.monospaced()).textSelection(.enabled) }
                }
                .card()
                if !prs.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pull requests on this branch").font(.headline)
                        ForEach(prs) { pr in
                            Button {
                                router.open(pr.lane == .reviewRequested ? .reviews : .mine, .pr(pr))
                            } label: {
                                Text(verbatim: "#\(pr.number) \(pr.title)")
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                HStack {
                    Button {
                        do { try claude.resume(session) } catch { store.show(.failure, error.localizedDescription) }
                    } label: { Label("Resume", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).tint(Theme.claude)
                    OpenInButton(path: session.cwd)
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.cwd)]) }
                }
                .controlSize(.large)
                if claude.isLive(session) {
                    Text("This session is running somewhere else right now; resuming it opens a second copy.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct WorktreeDetailView: View {
    @Environment(Store.self) private var store
    @Environment(Router.self) private var router
    var item: WorktreeItem
    @State private var confirm = false

    var body: some View {
        let claude = store.claude
        let sessions = claude.sessions.filter { $0.cwd.hasPrefix(item.worktree.path) }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Text(item.repo).foregroundStyle(.secondary)
                    WorktreeStatePill(item: item)
                    Spacer()
                }
                Text(item.worktree.name).font(.system(size: 24, weight: .bold, design: .rounded))
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Folder") { Text(item.worktree.path.abbreviatingHome).textSelection(.enabled) }
                    LabeledContent("Branch") { Text(item.worktree.branch ?? "detached") }
                    LabeledContent("Changes") { ChangesLabel(changes: item.changes) }
                    if let modified = item.modified { LabeledContent("Last touched") { Text("\(modified.short) ago") } }
                }
                .card()
                if let number = item.prNumber ?? matchingPR?.number, let pr = matchingPR ?? nil {
                    Button { router.open(pr.lane == .reviewRequested ? .reviews : .mine, .pr(pr)) } label: {
                        Text(verbatim: "Open #\(number) \(pr.title)")
                    }
                    .buttonStyle(.link)
                }
                if !sessions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Claude sessions here").font(.headline)
                        ForEach(sessions.prefix(6)) { SessionRow(session: $0) }
                    }
                    .card()
                }
                HStack {
                    OpenInButton(path: item.worktree.path)
                    Button("Open shell here") {
                        try? claude.openShell(in: item.worktree.path, title: item.worktree.name, repo: item.repo)
                    }
                    Spacer()
                    Button(role: .destructive) { confirm = true } label: { Label("Remove", systemImage: "trash") }
                }
                .controlSize(.large)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Remove \(item.worktree.name)?", isPresented: $confirm) {
            Button(item.changes.isClean ? "Remove" : "Remove and lose changes", role: .destructive) {
                Task {
                    await store.removeWorktree(item, force: !item.changes.isClean)
                    router.selection = nil
                }
            }
        } message: {
            Text(item.changes.isClean
                 ? "The folder goes; the branch and its commits stay in the clone."
                 : "It has uncommitted or unpushed work. That work is lost if you remove it.")
        }
    }

    private var matchingPR: PullRequest? {
        (store.reviewRequests + store.myPulls).first { pr in
            pr.repo.lowercased() == item.repo && (pr.number == item.prNumber || pr.headRef == item.worktree.branch)
        }
    }
}

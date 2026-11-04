import AppKit
import HubKit
import SwiftUI

struct DetailColumn: View {
    @Environment(Store.self) private var store
    @Environment(Router.self) private var router

    var body: some View {
        switch router.selection {
        case .pr(let pr):
            // Prefer the freshest copy; keep the old one if it left the list (say, after approving).
            let latest = (store.reviewRequests + store.reviewedPulls + store.myPulls).first { $0.nodeID == pr.nodeID } ?? pr
            PRDetailView(pr: latest).id(pr.nodeID)
        case .issue(let issue):
            let latest = store.issues.first { $0.nodeID == issue.nodeID } ?? issue
            IssueDetailView(issue: latest).id(issue.nodeID)
        case .run(let run):
            let latest = store.runs.first { $0.id == run.id } ?? run
            RunDetailView(initial: latest).id(run.id)
        case .terminal(let id):
            if let session = store.claude.terminals.session(id) {
                TerminalDetailView(session: session).id(id)
            } else {
                EmptyState(symbol: "terminal", title: "Terminal closed", subtitle: "Start Claude from a pull request, issue or run.")
            }
        case .session(let id):
            if let session = store.claude.sessions.first(where: { $0.id == id }) {
                SessionDetailView(session: session).id(id)
            } else {
                EmptyState(symbol: "sparkles", title: "Session gone", subtitle: "Its file is no longer there.")
            }
        case .worktree(let path):
            if let item = store.worktrees.first(where: { $0.id == path }) {
                WorktreeDetailView(item: item).id(path)
            } else {
                EmptyState(symbol: "folder", title: "Worktree removed", subtitle: "")
            }
        case nil:
            EmptyState(symbol: "sparkles", title: "Pick something",
                       subtitle: "Select a pull request or a run to review, approve, merge or re-run it.")
        }
    }
}

struct PRDetailView: View {
    @Environment(Store.self) private var store
    var pr: PullRequest
    private var actor: String { store.acting(for: pr) }

    @State private var files: [PRFile] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var conversation: PRConversation?
    @State private var comment = ""
    @State private var busy = false
    @State private var confirmMerge: MergeMethod?
    @State private var collapsed: Set<String> = []
    @State private var composing: DiffAnchor?
    @State private var showReviewers = false
    /// Files marked as looked at; they fold away.
    @State private var viewed: Set<String> = []
    /// Files you marked viewed that changed again since (GitHub unticks them).
    @State private var changedSinceViewed: Set<String> = []
    @State private var scrollTarget: String?
    @State private var showFileList = true
    @State private var showTreePopover = false
    @State private var tree: [FileNode] = []
    @State private var fileFilter = ""

    private var drafts: [DraftComment] { store.drafts[pr.nodeID] ?? [] }

    private var context: ReviewContext {
        ReviewContext(pr: pr, actor: actor, threads: conversation?.threads ?? [], drafts: drafts,
                      headSHA: conversation?.headSHA, reload: { await loadConversation() }, files: files)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    LinkedItemsCard(title: "Linked issues", items: store.linkedIssues(of: pr))
                    ClaudeReviewCard(pr: pr, actor: actor, files: files, headSHA: conversation?.headSHA,
                                     summary: $comment, busy: busy, submit: { await review($0) },
                                     conversation: conversation)
                    DiscussionCard(context: context, jump: { path in scrollTarget = "file:\(path)" })
                    ClaudeCard(repo: pr.repo, accountID: actor, worktree: "pr-\(pr.number)", sessions: store.claudeSessions(for: pr)) {
                        // Fixing the code for reviewers' comments is the author's job: only on your own PRs.
                        if pr.lane == .mine {
                            Button {
                                store.startClaude(on: pr, prompt: Prompts.reviewComments(pr), as: actor)
                            } label: { Label("Address review comments", systemImage: "text.bubble") }
                        }
                        if pr.checks?.isFailing == true {
                            Button {
                                Task {
                                    let context = await store.failingContext(for: pr, as: actor)
                                    store.startClaude(on: pr, prompt: Prompts.failingChecks(pr, runs: context.runs, log: context.log), as: actor)
                                }
                            } label: { Label("Fix failing checks", systemImage: "wrench.and.screwdriver") }
                            .tint(Theme.red)
                        }
                        Button {
                            store.startClaude(on: pr, prompt: nil, as: actor)
                        } label: { Label("Open on branch", systemImage: "terminal") }
                    }
                    if !pr.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        description
                    }
                    if let conversation {
                        ConversationCard(pr: pr, actor: actor, timeline: conversation.timeline, reload: { await loadConversation() },
                                         jump: { path in scrollTarget = "file:\(path)" })
                    }
                    filesHeading.id("files")
                }
                .padding([.horizontal, .top], 22)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(files) { file in
                    FileDiffView(file: file, context: context, composing: $composing, collapsed: Binding(
                        get: { collapsed.contains(file.id) },
                        set: { if $0 { collapsed.insert(file.id) } else { collapsed.remove(file.id) } }),
                        viewed: viewedBinding(file), changedSinceViewed: changedSinceViewed.contains(file.id))
                    .id("file:\(file.id)")
                }
                Color.clear.frame(height: 40)
                }
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo(target, anchor: .top) }
                scrollTarget = nil
            }
            .overlay(alignment: .bottomTrailing) {
                if files.count > 3 {
                    Button { showTreePopover.toggle() } label: {
                        Label("\(viewed.count)/\(files.count) files", systemImage: "list.bullet.indent")
                    }
                    .popover(isPresented: $showTreePopover, arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Filter files", text: $fileFilter).textFieldStyle(.roundedBorder)
                            ScrollView { FileTreeView(nodes: tree, state: treeState(closeOnSelect: true), filter: fileFilter) }
                        }
                        .padding(12)
                        .frame(width: 460, height: 560)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.blue.opacity(0.85))
                    .controlSize(.small)
                    .padding(14)
                    .help("Jump to the file list")
                }
            }
            .onChange(of: conversation?.threads.count) { _, _ in
                // HUB_DEV_SCROLL=files jumps to the diff, to look at threads without scrolling by hand.
                if ProcessInfo.processInfo.environment["HUB_DEV_SCROLL"] == "files" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { proxy.scrollTo("files", anchor: .top) }
                }
            }
            }
            Divider()
            actionBar
        }
        .task {
            async let a: Void = loadFiles()
            async let b: Void = loadConversation()
            _ = await (a, b)
        }
        // Hub's refresh saw the PR change (a review, a comment, a push): show it.
        .onChange(of: pr.updatedAt) { _, _ in Task { await loadConversation() } }
        // New commits: the diff changed too.
        .onChange(of: conversation?.headSHA) { old, new in
            if old != nil, new != nil, old != new { Task { await loadFiles() } }
        }
        .sheet(isPresented: $showReviewers) {
            RequestReviewersSheet(pr: pr, actor: actor, suggested: conversation?.suggestedReviewers ?? [],
                                  already: conversation?.requestedReviewers ?? [])
        }
        .confirmationDialog(
            "Merge #\(pr.number) into \(pr.baseRef)?",
            isPresented: Binding(get: { confirmMerge != nil }, set: { if !$0 { confirmMerge = nil } }),
            presenting: confirmMerge
        ) { method in
            Button(method.label) { Task { await merge(method) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("\(pr.title)\n\(pr.headRef) → \(pr.baseRef) in \(pr.repo)")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "book.closed.fill").foregroundStyle(.tertiary)
                Text(pr.repo).foregroundStyle(.secondary)
                Text(verbatim: "#\(pr.number)").foregroundStyle(.tertiary).monospacedDigit()
                Spacer()
                if store.account(actor) != nil {
                    HStack(spacing: 5) {
                        Circle().fill(Theme.color(for: actor)).frame(width: 7, height: 7)
                        Text("as \(store.name(actor))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary.opacity(0.5), in: Capsule())
                }
            }
            .font(.callout)

            Text(pr.title)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Avatar(url: pr.authorAvatar, size: 20)
                Text(pr.author).fontWeight(.medium)
                Text("wants to merge").foregroundStyle(.secondary)
                BranchChip(name: pr.headRef)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                BranchChip(name: pr.baseRef)
            }
            .font(.callout)

            HStack(spacing: 8) {
                if pr.isDraft { Pill(text: "Draft", symbol: "pencil", tint: .secondary) }
                ChecksPill(state: pr.checks)
                ReviewPill(decision: pr.reviewDecision)
                switch pr.mergeable {
                case .mergeable: Pill(text: "Mergeable", symbol: "arrow.triangle.merge", tint: Theme.green)
                case .conflicting: Pill(text: "Conflicts", symbol: "exclamationmark.triangle", tint: Theme.red)
                case .unknown: EmptyView()
                }
                if conversation?.mergeState == "BEHIND" { Pill(text: "Behind \(pr.baseRef)", symbol: "arrow.down.circle", tint: Theme.amber) }
                if let method = conversation?.autoMergeMethod {
                    Pill(text: "Auto-merge (\(method.lowercased()))", symbol: "bolt.badge.checkmark", tint: Theme.green)
                }
                Pill(text: "\(pr.changedFiles) files", symbol: "doc", tint: .secondary)
                DiffStat(additions: pr.additions, deletions: pr.deletions)
                Spacer()
                Text("updated \(pr.updatedAt.short) ago").font(.caption).foregroundStyle(.tertiary)
            }
            if let reviewers = conversation?.requestedReviewers, !reviewers.isEmpty {
                Text("Waiting on \(reviewers.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var description: some View {
        MarkdownBody(text: pr.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
    }

    // MARK: Files

    private var filesHeading: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Files changed").font(.headline)
                Text("\(files.count)").foregroundStyle(.secondary).monospacedDigit()
                if let threads = conversation?.threads, !threads.isEmpty {
                    let open = threads.filter { !$0.isResolved }.count
                    Pill(text: "\(open) open thread\(open == 1 ? "" : "s")", symbol: "text.bubble", tint: open > 0 ? Theme.blue : .secondary)
                }
                Spacer()
                if !files.isEmpty {
                    Button(collapsed.count == files.count ? "Expand all" : "Collapse all") {
                        collapsed = collapsed.count == files.count ? [] : Set(files.map(\.id))
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            if files.count > 1 { treeCard }
            Text("Hover a line and click + to comment on it.").font(.caption).foregroundStyle(.tertiary)
            if loading {
                HStack { ProgressView().controlSize(.small); Text("Loading diff…").foregroundStyle(.secondary) }
            } else if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.red)
            }
        }
    }

    private func treeState(closeOnSelect: Bool) -> FileTreeState {
        let threads = conversation?.threads ?? []
        return FileTreeState(
            viewed: viewed,
            openThreads: Dictionary(threads.filter { !$0.isResolved }.map { ($0.path, 1) }, uniquingKeysWith: +),
            pending: Dictionary(drafts.map { ($0.path, 1) }, uniquingKeysWith: +),
            setViewed: { file, isViewed in viewedBinding(file).wrappedValue = isViewed },
            select: { file in
                collapsed.remove(file.id)
                if closeOnSelect { showTreePopover = false }
                scrollTarget = "file:\(file.id)"
            })
    }

    /// The tree, with review progress.
    private var treeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { withAnimation(.snappy(duration: 0.2)) { showFileList.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.caption.weight(.bold))
                            .rotationEffect(.degrees(showFileList ? 90 : 0))
                        Image(systemName: "list.bullet.indent").foregroundStyle(Theme.blue)
                        Text("File tree").font(.subheadline.weight(.semibold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Gauge(value: Double(viewed.count), in: 0...Double(max(files.count, 1))) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(viewed.count == files.count ? Theme.green : Theme.blue)
                    .frame(maxWidth: 140)
                Text("\(viewed.count) of \(files.count) viewed").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if showFileList {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.tertiary)
                        TextField("Filter", text: $fileFilter).textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.quaternary.opacity(0.5), in: Capsule())
                    .frame(maxWidth: 180)
                }
            }
            if showFileList {
                ScrollView {
                    FileTreeView(nodes: tree, state: treeState(closeOnSelect: false), filter: fileFilter)
                }
                .frame(maxHeight: 360)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .padding(12)
        .background(.background.secondary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }

    private func viewedBinding(_ file: PRFile) -> Binding<Bool> {
        Binding(get: { viewed.contains(file.id) }, set: { isViewed in
            if isViewed { viewed.insert(file.id); collapsed.insert(file.id) } else { viewed.remove(file.id) }
            changedSinceViewed.remove(file.id)
            // Saved on GitHub, so it holds after a restart and on the website.
            let pr = pr, path = file.filename
            Task {
                guard let client = store.client(actor) else { return }
                do { try await client.setViewed(pr, path: path, isViewed) } catch {
                    if isViewed { viewed.remove(path) } else { viewed.insert(path) }
                    store.show(.failure, "Couldn't save “viewed” on GitHub: \(error.localizedDescription)")
                }
            }
        })
    }

    // MARK: Actions

    private var actionBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                if !drafts.isEmpty {
                    HStack(spacing: 6) {
                        Pill(text: "\(drafts.count) pending comment\(drafts.count == 1 ? "" : "s")", symbol: "clock", tint: Theme.amber)
                        Text("go out with your review").font(.caption).foregroundStyle(.secondary)
                        Button("Discard") { store.drafts[pr.nodeID] = nil }.buttonStyle(.link).font(.caption)
                    }
                }
                TextField(drafts.isEmpty ? "Leave a review comment (optional for approve)…" : "Review summary (optional)…", text: $comment, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(9)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .frame(minWidth: 120)

            Menu {
                if let conversation {
                    if conversation.autoMergeMethod != nil {
                        Button("Disable auto-merge") { Task { await act("Auto-merge off") { try await $0.setAutoMerge(pr, method: nil) } } }
                            .disabled(!conversation.canDisableAutoMerge)
                    } else {
                        Menu("Enable auto-merge") {
                            ForEach(MergeMethod.allCases, id: \.self) { method in
                                Button(method.label) { Task { await act("Auto-merge on: merges when checks pass") { try await $0.setAutoMerge(pr, method: method) } } }
                            }
                        }
                        .disabled(!conversation.canEnableAutoMerge)
                    }
                    Button("Update branch from \(pr.baseRef)") { Task { await act("Updating #\(pr.number) from \(pr.baseRef)") { try await $0.updateBranch(pr) } } }
                        .disabled(!conversation.canUpdateBranch)
                }
                if pr.lane == .mine {
                    if pr.isDraft {
                        Button("Mark ready for review") { Task { await act("#\(pr.number) is ready for review") { try await $0.setDraft(pr, false) } } }
                    } else {
                        Button("Convert to draft") { Task { await act("#\(pr.number) is a draft") { try await $0.setDraft(pr, true) } } }
                    }
                }
                Button("Request reviewers…") { showReviewers = true }
                Divider()
                Button("Open in browser") { NSWorkspace.shared.open(pr.url) }
                Button("Copy checkout command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("gh pr checkout \(pr.number) -R \(pr.repo)", forType: .string)
                    store.show(.info, "Copied gh pr checkout \(pr.number)")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Auto-merge, update branch, draft, reviewers, open in browser")

            // Send the review without approving: as a comment, or blocking with "request changes".
            Menu {
                Button("Comment") { Task { await review(.comment) } }
                Button("Request changes") { Task { await review(.requestChanges) } }
            } label: {
                Label(drafts.isEmpty ? "Comment" : "Comment with \(drafts.count)", systemImage: "text.bubble")
            } primaryAction: {
                Task { await review(.comment) }
            }
            .fixedSize()
            .disabled(busy || (comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && drafts.isEmpty))
            .help("Submit your review without approving; the arrow has Request changes. Type a summary or add line comments first.")

            Menu {
                ForEach(MergeMethod.allCases, id: \.self) { method in
                    Button(method.label) { confirmMerge = method }
                }
            } label: {
                Label("Merge", systemImage: "arrow.triangle.merge")
            } primaryAction: {
                confirmMerge = .squash
            }
            .fixedSize()
            .disabled(busy || pr.isDraft || pr.mergeable == .conflicting)
            .help("Squash and merge; the arrow picks another method")

            Button {
                Task { await review(.approve) }
            } label: {
                Label(drafts.isEmpty ? "Approve" : "Approve with \(drafts.count)", systemImage: "checkmark.seal.fill")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.green)
            .fixedSize()
            .layoutPriority(1)
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(busy || pr.lane == .mine)
            .help(pr.lane == .mine ? "You cannot approve your own pull request"
                  : pr.myReview == .changesRequested ? "Approve (⇧⌘↩). This replaces your request for changes."
                  : "Approve (⇧⌘↩)")
        }
        .controlSize(.large)
        .padding(14)
        .background(.bar)
    }

    private func loadFiles() async {
        guard let client = store.client(actor) else { return }
        do {
            files = try await client.files(of: pr)
            tree = FileNode.tree(files)
            showFileList = files.count <= 80
            // Lock files and generated files are rarely what a reviewer wants first.
            collapsed = Set(files.filter { $0.isNoise || $0.additions + $0.deletions > 400 }.map(\.id))
            // GitHub remembers what you viewed; viewed files start collapsed.
            if let marks = try? await client.viewedFiles(of: pr) {
                viewed = marks.viewed
                changedSinceViewed = marks.changedSince
                collapsed.formUnion(marks.viewed)
            }
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }

    private func loadConversation() async {
        guard let client = store.client(actor) else { return }
        if let fresh = try? await client.conversation(of: pr) { conversation = fresh }
    }

    private func act(_ message: String, _ work: @escaping (GitHubClient) async throws -> Void) async {
        busy = true
        defer { busy = false }
        if await store.perform(message, work, as: actor) { await loadConversation() }
    }

    private func review(_ event: ReviewEvent) async {
        busy = true
        defer { busy = false }
        let body = comment
        let pending = drafts
        let head = conversation?.headSHA
        let extra = pending.isEmpty ? "" : " with \(pending.count) comment\(pending.count == 1 ? "" : "s")"
        let label = switch event {
        case .approve: "Approved #\(pr.number)\(extra)"
        case .requestChanges: "Requested changes on #\(pr.number)\(extra)"
        case .comment: "Reviewed #\(pr.number)\(extra)"
        }
        let pr = pr
        if await store.perform(label, { try await $0.submitReview(pr, event: event, body: body, comments: pending, commit: head) }, as: actor) {
            comment = ""
            store.drafts[pr.nodeID] = nil
            store.reviewer.markSubmitted(pr, event: event)
            await loadConversation()
        }
    }

    private func merge(_ method: MergeMethod) async {
        busy = true
        defer { busy = false }
        let pr = pr
        _ = await store.perform("Merged #\(pr.number)", { try await $0.merge(pr, method: method) }, as: actor)
    }

}

extension PRFile {
    var isNoise: Bool {
        let name = (filename as NSString).lastPathComponent
        return ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "Cargo.lock", "Package.resolved", "go.sum", "Podfile.lock", "poetry.lock", "bun.lockb", "uv.lock"].contains(name)
            || filename.contains(".min.") || filename.hasSuffix(".snap")
    }
}

struct BranchChip: View {
    var name: String
    var body: some View {
        Text(name)
            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Theme.blue.opacity(0.13), in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(Theme.blue)
    }
}

struct ChecksPill: View {
    var state: CheckState?
    var body: some View {
        switch state {
        case .success: Pill(text: "Checks passed", symbol: "checkmark.circle.fill", tint: Theme.green)
        case .failure, .error: Pill(text: "Checks failing", symbol: "xmark.circle.fill", tint: Theme.red)
        case .pending, .expected: Pill(text: "Checks running", symbol: "circle.dotted", tint: Theme.amber)
        case nil: EmptyView()
        }
    }
}

// MARK: Diff

struct FileDiffView: View {
    var file: PRFile
    var context: ReviewContext
    @Binding var composing: DiffAnchor?
    @Binding var collapsed: Bool
    @Binding var viewed: Bool
    /// You had viewed it, and it changed since.
    var changedSinceViewed = false
    @State private var showAll = false
    private let preview = 400

    var body: some View {
        let threads = context.threads.filter { $0.path == file.filename }
        let anchoredThreads = Dictionary(grouping: threads.filter { $0.line != nil }) { "\($0.side == .left ? "L" : "R"):\($0.line!)" }
        let outdated = threads.filter { $0.line == nil }
        let drafts = Dictionary(grouping: context.drafts.filter { $0.path == file.filename }) { "\($0.side == .left ? "L" : "R"):\($0.line)" }
        // A section, so the header stays pinned while you scroll through the file.
        Section {
            if !collapsed {
                VStack(alignment: .leading, spacing: 0) {
                    if let patch = file.patch {
                        let lines = DiffLine.parse(patch)
                        let shown = showAll ? lines : Array(lines.prefix(preview))
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(shown) { line in
                                let anchor = anchor(for: line)
                                DiffLineView(line: line, canComment: anchor != nil) {
                                    composing = anchor
                                }
                                if let anchor {
                                    let here = (anchoredThreads[anchor.key] ?? []), mine = (drafts[anchor.key] ?? [])
                                    if !here.isEmpty || !mine.isEmpty || composing == anchor {
                                        VStack(alignment: .leading, spacing: 8) {
                                            ForEach(here) { ThreadView(thread: $0, context: context) }
                                            ForEach(mine) { DraftView(draft: $0, context: context) }
                                            if composing == anchor {
                                                CommentComposer(anchor: anchor, context: context) { composing = nil }
                                            }
                                        }
                                        .padding(.vertical, 8)
                                        .padding(.leading, 60)
                                        .padding(.trailing, 12)
                                        .background(Theme.blue.opacity(0.04))
                                    }
                                }
                            }
                        }
                        if lines.count > preview, !showAll {
                            Button("Show \(lines.count - preview) more lines") { showAll = true }
                                .buttonStyle(.link)
                                .padding(10)
                        }
                    } else {
                        Text("Binary file, or a diff too large for GitHub to show.")
                            .font(.caption).foregroundStyle(.secondary).padding(12)
                    }
                    if !outdated.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Earlier comments on code that has since changed").font(.caption).foregroundStyle(.secondary)
                            ForEach(outdated) { ThreadView(thread: $0, context: context) }
                        }
                        .padding(12)
                    }
                }
                .background(.background.secondary.opacity(0.5))
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous))
                .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous)
                    .strokeBorder(.separator.opacity(0.5)))
                .padding(.horizontal, 22)
                .padding(.bottom, 12)
            }
        } header: {
            header(openCount: threads.filter { !$0.isResolved }.count + drafts.values.joined().count)
                .padding(.horizontal, 22)
                .padding(.bottom, collapsed ? 12 : 0)
                .background(Color(nsColor: .windowBackgroundColor).opacity(collapsed ? 0 : 1))
        }
    }

    private func header(openCount: Int) -> some View {
        let folder = (file.filename as NSString).deletingLastPathComponent
        let name = (file.filename as NSString).lastPathComponent
        let (symbol, tint) = FileKind.symbol(name)
        let shape = UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: collapsed ? 10 : 0,
                                           bottomTrailingRadius: collapsed ? 10 : 0, topTrailingRadius: 10, style: .continuous)
        return HStack(spacing: 8) {
            Button { withAnimation(.snappy(duration: 0.2)) { collapsed.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                        .foregroundStyle(.secondary)
                    Image(systemName: symbol).foregroundStyle(tint)
                    (Text(folder.isEmpty ? "" : folder + "/").foregroundStyle(.secondary) + Text(name).fontWeight(.semibold))
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                    StatusBadge(status: file.status)
                    Spacer()
                    if openCount > 0 {
                        Label("\(openCount)", systemImage: "text.bubble.fill").font(.caption).foregroundStyle(Theme.blue)
                    }
                    ChangeBar(additions: file.additions, deletions: file.deletions)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(file.filename)
            // GitHub's "Viewed" box: tick it and the file folds away.
            if changedSinceViewed && !viewed {
                Pill(text: "Changed since you viewed", symbol: "arrow.triangle.2.circlepath", tint: Theme.amber)
            }
            Button { viewed.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: viewed ? "checkmark.square.fill" : "square")
                        .foregroundStyle(viewed ? Theme.green : .secondary)
                    Text("Viewed")
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(viewed ? Theme.green.opacity(0.14) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(viewed ? Theme.green.opacity(0.5) : .secondary.opacity(0.25)))
            }
            .buttonStyle(.plain)
            .help(viewed ? "Mark as not viewed" : "Mark as viewed")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: shape)
        .overlay(shape.strokeBorder(.separator.opacity(0.5)))
        .opacity(viewed && collapsed ? 0.7 : 1)
    }

    private func anchor(for line: DiffLine) -> DiffAnchor? {
        switch line.kind {
        case .add, .context: line.new.map { DiffAnchor(path: file.filename, line: $0, side: .right) }
        case .remove: line.old.map { DiffAnchor(path: file.filename, line: $0, side: .left) }
        case .hunk: nil
        }
    }

    private var statusSymbol: String {
        switch file.status {
        case "added": "plus.square.fill"
        case "removed": "minus.square.fill"
        case "renamed": "arrow.right.square.fill"
        default: "pencil.circle.fill"
        }
    }

    private var statusTint: Color {
        switch file.status {
        case "added": Theme.green
        case "removed": Theme.red
        case "renamed": Theme.blue
        default: Theme.amber
        }
    }
}

struct DiffLine: Identifiable {
    enum Kind { case hunk, add, remove, context }
    let id: Int
    let kind: Kind
    let old: Int?
    let new: Int?
    let text: String

    static func parse(_ patch: String) -> [DiffLine] {
        var result: [DiffLine] = []
        var old = 0, new = 0
        for (index, raw) in patch.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            if line.hasPrefix("@@") {
                // @@ -12,7 +12,9 @@ context
                let parts = line.split(separator: " ")
                if parts.count > 2 {
                    old = Int(parts[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                    new = Int(parts[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                result.append(DiffLine(id: index, kind: .hunk, old: nil, new: nil, text: line))
            } else if line.hasPrefix("+") {
                result.append(DiffLine(id: index, kind: .add, old: nil, new: new, text: String(line.dropFirst())))
                new += 1
            } else if line.hasPrefix("-") {
                result.append(DiffLine(id: index, kind: .remove, old: old, new: nil, text: String(line.dropFirst())))
                old += 1
            } else if line.hasPrefix("\\") {
                continue
            } else {
                result.append(DiffLine(id: index, kind: .context, old: old, new: new, text: String(line.dropFirst())))
                old += 1
                new += 1
            }
        }
        return result
    }
}

struct DiffLineView: View {
    var line: DiffLine
    var canComment = false
    var onComment: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            if line.kind == .hunk {
                Text(line.text)
                    .foregroundStyle(Theme.violet.opacity(0.9))
                    .padding(.leading, 12)
                    .padding(.vertical, 3)
            } else {
                ZStack {
                    if hovering && canComment {
                        Button(action: onComment) {
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 15, height: 15)
                                .background(Theme.blue, in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .help("Comment on this line")
                    }
                }
                .frame(width: 18)
                number(line.old)
                number(line.new)
                Text(marker)
                    .foregroundStyle(markerTint)
                    .frame(width: 16)
                Text(line.text.isEmpty ? " " : line.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .background(hovering && canComment ? Theme.blue.opacity(0.08) : background)
        .onHover { hovering = $0 }
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: 40, alignment: .trailing)
            .padding(.trailing, 6)
    }

    private var marker: String {
        switch line.kind {
        case .add: "+"
        case .remove: "−"
        default: ""
        }
    }

    private var markerTint: Color { line.kind == .add ? Theme.green : Theme.red }

    private var background: Color {
        switch line.kind {
        case .add: Theme.green.opacity(0.12)
        case .remove: Theme.red.opacity(0.12)
        case .hunk: Theme.violet.opacity(0.07)
        case .context: .clear
        }
    }
}

// MARK: Markdown

/// Pull request descriptions: headings, lists, quotes, fenced code and inline
/// markdown. HTML comments (bot bookkeeping) are dropped.
struct MarkdownBody: View {
    var text: String

    enum Block: Hashable {
        case heading(Int, String)
        case paragraph(String)
        case bullet(String, depth: Int)
        case quote(String)
        case code(String)
        case rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(.system(size: level <= 1 ? 18 : level == 2 ? 15.5 : 13.5, weight: .bold))
                .padding(.top, 6)
        case .paragraph(let text):
            Text(inline(text)).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        case .bullet(let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(depth == 0 ? "•" : "◦").foregroundStyle(.secondary)
                Text(inline(text)).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(.tertiary).frame(width: 3)
                Text(inline(text)).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(size: 11.5, design: .monospaced)).padding(10)
            }
            .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        case .rule:
            Divider()
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    static func blocks(_ source: String) -> [Block] {
        // Drop HTML comments, including ones spanning lines.
        var text = source.replacingOccurrences(of: "\r\n", with: "\n")
        while let start = text.range(of: "<!--"), let end = text.range(of: "-->", range: start.upperBound..<text.endIndex) {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                flush()
                blocks.append(.heading(level, line.dropFirst(level).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flush()
                let indent = raw.prefix { $0 == " " }.count
                var item = String(line.dropFirst(2))
                if item.hasPrefix("[ ] ") { item = "☐ " + item.dropFirst(4) }
                if item.hasPrefix("[x] ") || item.hasPrefix("[X] ") { item = "☑ " + item.dropFirst(4) }
                blocks.append(.bullet(item, depth: min(indent / 2, 3)))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
                      line[line.index(after: dot)...].hasPrefix(" ") {
                flush()
                blocks.append(.paragraph(line))
            } else if line.hasPrefix(">") {
                flush()
                blocks.append(.quote(line.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else if line == "---" || line == "***" {
                flush()
                blocks.append(.rule)
            } else if line.hasPrefix("<") && line.hasSuffix(">") && !line.contains(" ") {
                continue // bare tags such as <details>, <br/>
            } else {
                paragraph.append(line)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}

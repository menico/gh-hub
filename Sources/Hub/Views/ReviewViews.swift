import AppKit
import HubKit
import SwiftUI

/// A place in the diff a comment can attach to.
struct DiffAnchor: Hashable {
    var path: String
    var line: Int
    var side: DiffSide
    var key: String { "\(side == .left ? "L" : "R"):\(line)" }
}

/// What the diff of one pull request needs to show and take comments.
struct ReviewContext {
    var pr: PullRequest
    var actor: String
    var threads: [ReviewThread]
    var drafts: [DraftComment]
    var headSHA: String?
    var reload: () async -> Void
    var files: [PRFile] = []
}

// MARK: Threads

struct ThreadView: View {
    @Environment(Store.self) private var store
    var thread: ReviewThread
    var context: ReviewContext
    @State private var reply = ""
    @State private var replying = false
    @State private var expanded = false
    @State private var busy = false
    @State private var checking = false
    @State private var check: ThreadCheck?
    @State private var checkError: String?
    @AppStorage(ReviewPersona.selectedKey) private var personaID = ReviewPersona.general.id

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if thread.isResolved && !expanded {
                Button { expanded = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                        Text("Resolved · \(thread.comments.first?.author ?? "") and \(max(thread.comments.count - 1, 0)) more").foregroundStyle(.secondary)
                        Spacer()
                        Text("Show").foregroundStyle(.tertiary)
                    }
                    .font(.caption)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                ForEach(thread.comments) { comment in
                    CommentBubble(author: comment.author, avatar: comment.authorAvatar, date: comment.createdAt, text: comment.body)
                }
                if let check { checkView(check) }
                if let checkError {
                    Label(checkError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.red)
                        .textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    if replying {
                        TextField("Reply…", text: $reply, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...10)
                        Button("Reply") { Task { await sendReply(resolve: false) } }
                            .disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                            .keyboardShortcut(.return, modifiers: .command)
                        if !thread.isResolved {
                            Button("Reply & resolve") { Task { await sendReply(resolve: true) } }
                                .disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                        }
                        Button("Cancel") { replying = false; reply = "" }
                    } else {
                        Button { replying = true } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                        if !thread.isResolved && thread.comments.count > 1 {
                            Button { Task { await runCheck() } } label: {
                                if checking {
                                    HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Claude is reading…") }
                                } else {
                                    Label(check == nil ? "Check with Claude" : "Check again", systemImage: "sparkles")
                                }
                            }
                            .disabled(checking)
                            .help("Did the answer and the current code address the comment? Claude says, and drafts a reply. Nothing is posted.")
                        }
                        Button {
                            Task { await setResolved(!thread.isResolved) }
                        } label: {
                            Label(thread.isResolved ? "Unresolve" : "Resolve", systemImage: thread.isResolved ? "arrow.uturn.backward" : "checkmark")
                        }
                        if thread.isOutdated { Pill(text: "Outdated", tint: .secondary) }
                        Spacer()
                    }
                }
                .controlSize(.small)
                .disabled(busy)
            }
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.separator.opacity(0.6)))
        .font(.system(size: 12.5))
    }

    private func sendReply(resolve: Bool) async {
        guard let id = thread.comments.first?.databaseID else { return }
        busy = true
        defer { busy = false }
        let pr = context.pr, body = reply, threadID = thread.id
        let sent = await store.perform(resolve ? "Replied and resolved" : "Replied", {
            try await $0.reply(on: pr, to: id, body: body)
            if resolve { try await $0.setResolved(thread: threadID, true) }
        }, as: context.actor)
        if sent {
            reply = ""
            replying = false
            check = nil
            await context.reload()
        }
    }

    private func runCheck() async {
        checking = true
        checkError = nil
        defer { checking = false }
        let login = store.account(context.actor)?.account.login ?? ""
        do {
            let result = try await store.reviewer.check(thread, on: context.pr, reviewer: login, files: context.files,
                                                        claude: store.claude, accountID: context.actor,
                                                        persona: ReviewPersona.named(personaID))
            check = result
            reply = result.reply
            replying = true
        } catch {
            checkError = error.localizedDescription
        }
    }

    private func checkView(_ check: ThreadCheck) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(Theme.claude)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    switch check.addressed {
                    case "yes": Pill(text: "Addressed", symbol: "checkmark.circle.fill", tint: Theme.green)
                    case "partly": Pill(text: "Partly addressed", symbol: "circle.lefthalf.filled", tint: Theme.amber)
                    default: Pill(text: "Not addressed", symbol: "xmark.circle.fill", tint: Theme.red)
                    }
                    if check.resolve { Text("Can be resolved").font(.caption).foregroundStyle(.secondary) }
                }
                MarkdownBody(text: check.assessment)
                Text("Claude's draft reply is in the box below. Edit it before sending.").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(Theme.claude.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func setResolved(_ resolved: Bool) async {
        busy = true
        defer { busy = false }
        let id = thread.id
        if await store.perform(resolved ? "Resolved" : "Reopened", { try await $0.setResolved(thread: id, resolved) }, as: context.actor) {
            await context.reload()
        }
    }
}

/// The review threads on a pull request in one place, the ones where it is
/// your turn first: answer, resolve, or have Claude check the answer.
struct DiscussionCard: View {
    @Environment(Store.self) private var store
    var context: ReviewContext
    var jump: (String) -> Void
    @State private var showResolved = false

    var body: some View {
        let login = store.account(context.actor)?.account.login ?? ""
        let open = context.threads.filter { !$0.isResolved }
        let yourTurn = open.filter { $0.waitsOn(login) }
        let rest = open.filter { !$0.waitsOn(login) }
        let resolved = context.threads.filter(\.isResolved)
        if !context.threads.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(Theme.blue)
                    Text("Discussion").font(.headline)
                    if !yourTurn.isEmpty {
                        Pill(text: "\(yourTurn.count) waiting on your answer", symbol: "arrowshape.turn.up.left.fill", tint: Theme.blue)
                    }
                    Spacer()
                    Text("\(open.count) open · \(resolved.count) resolved").font(.caption).foregroundStyle(.secondary)
                }
                if open.isEmpty {
                    Text("Every thread is resolved.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(yourTurn + rest) { thread in
                    threadBlock(thread, yourTurn: thread.waitsOn(login))
                }
                if !resolved.isEmpty {
                    Button(showResolved ? "Hide resolved" : "Show \(resolved.count) resolved") {
                        withAnimation(.snappy) { showResolved.toggle() }
                    }
                    .buttonStyle(.link).font(.caption)
                    if showResolved {
                        ForEach(resolved) { threadBlock($0, yourTurn: false) }
                    }
                }
            }
            .card()
        }
    }

    private func threadBlock(_ thread: ReviewThread, yourTurn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Button {
                    jump(thread.path)
                } label: {
                    Text("\(thread.path)\((thread.line ?? thread.originalLine).map { ":\($0)" } ?? "")")
                        .font(.caption.monospaced()).lineLimit(1).truncationMode(.head)
                }
                .buttonStyle(.link)
                .help("Show it in the diff")
                if thread.isOutdated { Pill(text: "Code changed", symbol: "arrow.triangle.2.circlepath", tint: .secondary) }
                if yourTurn, let last = thread.comments.last {
                    Pill(text: "\(last.author) answered", symbol: "arrowshape.turn.up.left.fill", tint: Theme.blue)
                }
                Spacer()
            }
            ThreadView(thread: thread, context: context)
        }
    }
}

struct CommentBubble: View {
    var author: String
    var avatar: URL?
    var date: Date
    var text: String
    var tag: AnyView? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Avatar(url: avatar, size: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(author).fontWeight(.semibold)
                    Text(date.short == "now" ? "just now" : "\(date.short) ago").foregroundStyle(.tertiary)
                    if let tag { tag }
                }
                .font(.caption)
                MarkdownBody(text: text)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: Drafts and the composer

struct DraftView: View {
    @Environment(Store.self) private var store
    var draft: DraftComment
    var context: ReviewContext
    @State private var editing = false
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Pill(text: draft.fromClaude ? "Pending · from Claude" : "Pending", symbol: draft.fromClaude ? "sparkles" : "clock",
                     tint: draft.fromClaude ? Theme.claude : Theme.amber)
                Spacer()
                Button(editing ? "Done" : "Edit") {
                    if editing { update(text) } else { text = draft.body }
                    editing.toggle()
                }
                Button(role: .destructive) { remove() } label: { Image(systemName: "trash") }
                    .help("Discard this comment")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            if editing {
                TextField("", text: $text, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...10)
            } else {
                MarkdownBody(text: draft.body)
            }
        }
        .font(.system(size: 12.5))
        .padding(10)
        .background((draft.fromClaude ? Theme.claude : Theme.amber).opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder((draft.fromClaude ? Theme.claude : Theme.amber).opacity(0.4)))
    }

    private func update(_ body: String) {
        guard var list = store.drafts[context.pr.nodeID], let i = list.firstIndex(where: { $0.id == draft.id }) else { return }
        list[i].body = body
        store.drafts[context.pr.nodeID] = list
    }

    private func remove() {
        store.drafts[context.pr.nodeID]?.removeAll { $0.id == draft.id }
    }
}

struct CommentComposer: View {
    @Environment(Store.self) private var store
    var anchor: DiffAnchor
    var context: ReviewContext
    var close: () -> Void
    @State private var text = ""
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Comment on line \(anchor.line)\(anchor.side == .left ? " (old)" : "")")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Leave a comment — markdown, ```suggestion blocks work", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...12)
                .focused($focused)
            HStack {
                Button("Cancel", action: close).keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Comment now") { Task { await sendNow() } }
                    .disabled(empty || busy || context.headSHA == nil)
                    .help("Publish this one comment right away")
                Button {
                    store.drafts[context.pr.nodeID, default: []].append(
                        DraftComment(path: anchor.path, line: anchor.line, side: anchor.side, body: text))
                    close()
                } label: {
                    Text(context.drafts.isEmpty ? "Start a review" : "Add to review")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(empty)
                .help("Keep it pending; it goes out with Approve, Comment or Request changes (⌘↩)")
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.blue.opacity(0.6)))
        .onAppear { focused = true }
    }

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func sendNow() async {
        guard let head = context.headSHA else { return }
        busy = true
        defer { busy = false }
        let pr = context.pr
        let draft = DraftComment(path: anchor.path, line: anchor.line, side: anchor.side, body: text)
        if await store.perform("Commented on line \(anchor.line)", { try await $0.comment(on: pr, draft, commit: head) }, as: context.actor) {
            close()
            await context.reload()
        }
    }
}

// MARK: Conversation

struct ConversationCard: View {
    @Environment(Store.self) private var store
    var pr: PullRequest
    var actor: String
    var timeline: [TimelineEntry]
    var reload: () async -> Void
    /// Scrolls to a file in the diff.
    var jump: (String) -> Void = { _ in }
    @State private var text = ""
    @State private var busy = false
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Conversation").font(.headline)
                Text("\(timeline.count)").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
            }
            if timeline.isEmpty {
                Text("No comments or reviews yet.").font(.callout).foregroundStyle(.secondary)
            }
            let shown = showAll ? timeline : Array(timeline.suffix(6))
            if timeline.count > shown.count {
                Button("Show \(timeline.count - shown.count) earlier") { showAll = true }.buttonStyle(.link).font(.caption)
            }
            ForEach(shown) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    CommentBubble(author: entry.author, avatar: entry.authorAvatar, date: entry.date,
                                  text: entry.body.isEmpty ? "" : entry.body,
                                  tag: tag(entry.kind, lineComments: entry.lineComments.count))
                    if !entry.lineComments.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(entry.lineComments.enumerated()), id: \.offset) { _, note in
                                VStack(alignment: .leading, spacing: 3) {
                                    Button { jump(note.path) } label: {
                                        Label(note.line.map { "\(note.path):\($0)" } ?? note.path, systemImage: "arrow.down.right")
                                            .font(.caption.monospaced())
                                            .lineLimit(1).truncationMode(.head)
                                    }
                                    .buttonStyle(.link)
                                    .help("Show it in the diff")
                                    MarkdownBody(text: note.body)
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                        }
                        .padding(.leading, 28)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Comment on the conversation…", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                Button("Comment") { Task { await send() } }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
        }
        .card()
    }

    private func tag(_ kind: TimelineEntry.Kind, lineComments: Int) -> AnyView? {
        guard case .review(let state) = kind else { return nil }
        switch state {
        case "APPROVED": return AnyView(Pill(text: "Approved", symbol: "checkmark.seal.fill", tint: Theme.green))
        case "CHANGES_REQUESTED": return AnyView(Pill(text: "Changes requested", symbol: "exclamationmark.bubble.fill", tint: Theme.red))
        case "DISMISSED": return AnyView(Pill(text: "Dismissed", tint: .secondary))
        default:
            let text = lineComments == 0 ? "Reviewed" : "Reviewed · \(lineComments) line comment\(lineComments == 1 ? "" : "s")"
            return AnyView(Pill(text: text, symbol: "text.bubble", tint: .secondary))
        }
    }

    private func send() async {
        busy = true
        defer { busy = false }
        let pr = pr, body = text
        if await store.perform("Commented on #\(pr.number)", { try await $0.comment(onConversationOf: pr, body: body) }, as: actor) {
            text = ""
            await reload()
        }
    }
}

// MARK: Claude's review

/// Which perspective Claude reviews from: General, Architect, … or your own.
struct PersonaPicker: View {
    @Binding var selection: String
    var defaultID: String
    /// Only here so the view redraws when personas change in Settings.
    var custom: Data?

    var body: some View {
        let personas = ReviewPersona.all()
        let current = ReviewPersona.named(selection)
        HStack(spacing: 8) {
            Text("Review as").font(.callout).foregroundStyle(.secondary)
            Picker("", selection: $selection) {
                ForEach(personas) { p in
                    Label(p.id == defaultID ? "\(p.name) (default)" : p.name, systemImage: p.symbol).tag(p.id)
                }
            }
            .labelsHidden()
            .fixedSize()
            Text(current.lens.prefix(110).split(separator: " ").dropLast().joined(separator: " ") + "…")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                .help(current.lens)
            SettingsLink { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.borderless)
                .help("Set the default persona, edit them or add your own (Settings)")
        }
    }
}

struct ClaudeReviewCard: View {
    @Environment(Store.self) private var store
    var pr: PullRequest
    var actor: String
    var files: [PRFile]
    var headSHA: String?
    /// The review summary, shared with the action bar at the bottom.
    @Binding var summary: String
    var busy: Bool
    /// Sends the review with every pending comment, as the action bar does.
    var submit: (ReviewEvent) async -> Void
    /// What GitHub has: posted line comments, and your own reviews.
    var conversation: PRConversation?
    @State private var focus = ""
    @State private var showUnused = false
    /// A profile picked for this PR's review only: "@claude" or a cpx profile name.
    @State private var overrideKey: String?
    @AppStorage("reviewMode") private var modeRaw = ClaudeReviewer.Mode.quick.rawValue
    private var mode: ClaudeReviewer.Mode { ClaudeReviewer.Mode(rawValue: modeRaw) ?? .quick }
    /// The default persona, set in Settings.
    @AppStorage(ReviewPersona.selectedKey) private var defaultPersona = ReviewPersona.general.id
    /// A persona picked for this PR's review only.
    @State private var personaOverride: String?
    /// Watched so personas edited in Settings show up here.
    @AppStorage("reviewPersonas") private var customPersonas: Data?
    private var personaID: String { personaOverride ?? defaultPersona }
    private var persona: ReviewPersona { ReviewPersona.named(personaID) }

    var body: some View {
        let reviewer = store.reviewer
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles").foregroundStyle(Theme.claude.gradient)
                Text("Claude's review").font(.headline)
                Spacer()
                ReviewProfileMenu(pr: pr, actor: actor, profile: profile, overrideKey: $overrideKey)
            }
            if canStart {
                UsageNotice(profile: profile, others: otherProfiles) { overrideKey = $0 }
            }
            switch reviewer.state(for: pr) {
            case nil:
                Text("Claude reads the diff (and the code around it, from your clone) and gives a summary, the risky spots, and line comments you can add to your review. Nothing is posted until you say so.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                startRow(label: "Review with Claude")
            case .running(let started):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        let seconds = Int(context.date.timeIntervalSince(started))
                        Text(mode == .codeReview
                             ? "Running /code-review: agents review, then check each finding… \(seconds / 60)m \(seconds % 60)s"
                             : "Reviewing \(files.count) files… \(seconds)s").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel") { reviewer.cancel(pr) }
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.red).font(.callout)
                    .textSelection(.enabled)
                startRow(label: "Try again")
            case .done(let review):
                result(review)
            }
        }
        .card()
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.claude.opacity(0.35)))
    }

    private var profile: CpxConfig.Profile? {
        if let overrideKey { return overrideKey == "@claude" ? nil : store.claude.cpx.profiles.first { $0.name == overrideKey } }
        return store.claude.profile(for: actor, clone: store.claude.clonePath(for: pr.repo).path)
    }

    /// Before a review, or after one failed: when the profile still matters.
    private var canStart: Bool {
        switch store.reviewer.state(for: pr) {
        case nil, .failed: true
        default: false
        }
    }

    /// Every account a review could run as: each cpx profile, then plain claude.
    private var otherProfiles: [String?] {
        store.claude.cpx.profiles.map { Optional($0.name) } + [nil]
    }

    private func startRow(label: String) -> some View {
        let plugin = store.claude.codeReviewPlugin(for: profile)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("", selection: $modeRaw) {
                    Text("Quick").tag(ClaudeReviewer.Mode.quick.rawValue)
                    Text("/code-review").tag(ClaudeReviewer.Mode.codeReview.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(plugin.dir == nil && !plugin.enabled)
                Text(mode == .quick
                     ? "One pass over the diff, about a minute."
                     : "Anthropic's code-review plugin: parallel Sonnet and Opus agents, each finding double-checked. Several minutes; costs more."
                       + (plugin.enabled ? "" : " Loaded for this run (not enabled in this profile)."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PersonaPicker(selection: Binding(get: { personaID }, set: { personaOverride = $0 == defaultPersona ? nil : $0 }),
                          defaultID: defaultPersona, custom: customPersonas)
            startButtons(label: label)
        }
    }

    private func startButtons(label: String) -> some View {
        HStack(spacing: 8) {
            TextField("Focus on… (optional)", text: $focus)
                .textFieldStyle(.roundedBorder)
                .onSubmit(start)
            Button(action: start) { Label(label, systemImage: "sparkles") }
                .buttonStyle(.borderedProminent)
                .tint(Theme.claude)
                .disabled(files.isEmpty)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .help("⇧⌘R")
        }
    }

    private func start() {
        let mode = mode, account = store.account(actor)?.account
        let (pr, files, head, focus, actor, overrideKey) = (pr, files, headSHA, focus, actor, overrideKey)
        Task {
            // gh inside the review runs as the account that sees this PR.
            let token = await account.asyncMap { try? await GHCLI.token(for: $0) } ?? nil
            store.reviewer.review(pr, files: files, head: head, claude: store.claude, accountID: actor, focus: focus,
                                  mode: mode, persona: persona, ghToken: token, profileOverride: overrideKey)
        }
    }

    @ViewBuilder
    private func result(_ review: ClaudeReview) -> some View {
        HStack(spacing: 8) {
            switch review.verdict {
            case "approve": Pill(text: "Looks good to merge", symbol: "checkmark.seal.fill", tint: Theme.green)
            case "request_changes": Pill(text: "Needs changes", symbol: "exclamationmark.triangle.fill", tint: Theme.red)
            default: Pill(text: "Worth a look", symbol: "eye", tint: Theme.amber)
            }
            if let name = review.persona, name != ReviewPersona.general.name {
                Pill(text: name, symbol: ReviewPersona.all().first { $0.name == name }?.symbol ?? "person.crop.circle", tint: Theme.claude)
            }
            if review.mode == "code-review" { Pill(text: "/code-review", symbol: "checkmark.shield", tint: Theme.claude) }
            if let head = store.reviewer.reviewedHead[pr.nodeID], let current = headSHA, head != current {
                Pill(text: "PR changed since", symbol: "arrow.triangle.2.circlepath", tint: Theme.amber)
            }
            Spacer()
            if let at = review.reviewedAt {
                Text("\(at.short == "now" ? "just now" : at.short + " ago")\(review.costUSD.map { String(format: " · $%.2f", $0) } ?? "")")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            if review.sessionID != nil {
                Button {
                    do { try store.claude.resumeReview(review, title: "Review #\(pr.number)", pr: pr) }
                    catch { store.show(.failure, error.localizedDescription) }
                } label: { Label("Open conversation", systemImage: "bubble.left.and.text.bubble.right") }
                    .controlSize(.small)
                    .help("Continue this review with Claude: ask why, ask for more, or have it look again")
            }
            Menu {
                Button("Quick review again") { modeRaw = ClaudeReviewer.Mode.quick.rawValue; start() }
                Button("Review again with /code-review") { modeRaw = ClaudeReviewer.Mode.codeReview.rawValue; start() }
                Menu("Review again as…") {
                    ForEach(ReviewPersona.all()) { p in
                        Button { personaOverride = p.id; start() } label: { Label(p.id == defaultPersona ? "\(p.name) (default)" : p.name, systemImage: p.symbol) }
                    }
                }
                Button("Discard review", role: .destructive) { store.reviewer.discard(pr) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        MarkdownBody(text: review.summary)
        if !review.risks.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(review.risks.enumerated()), id: \.offset) { _, risk in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle().fill(risk.level == "high" ? Theme.red : risk.level == "medium" ? Theme.amber : Color.secondary)
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text((try? AttributedString(markdown: risk.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(risk.text))
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                            if let path = risk.path, !path.isEmpty, path != "null" {
                                Text(path).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        let review = withGitHub(review)
        let open = review.comments.filter { !review.handled.contains($0.id) && !alreadyAdded($0) }
        if review.submitted != nil {
            Divider()
            sentRow(review, unused: open)
        } else if !review.comments.isEmpty {
            Divider()
            HStack {
                Text(open.isEmpty ? "All \(review.comments.count) suggested comments handled" : "\(open.count) suggested comment\(open.count == 1 ? "" : "s")")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if open.count > 1 {
                    Button { open.forEach(add) } label: { Label("Add all to review", systemImage: "plus.bubble") }
                        .controlSize(.small)
                }
            }
            ForEach(open) { suggestion in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("\(suggestion.path):\(suggestion.line)\(suggestion.side == .left ? " (old)" : "")")
                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        Spacer()
                        Button("Dismiss") { store.reviewer.markHandled(pr, [suggestion.id]) }.buttonStyle(.borderless)
                        Button("Add to review") { add(suggestion) }
                    }
                    .controlSize(.small)
                    MarkdownBody(text: suggestion.body)
                }
                .padding(9)
                .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        if review.submitted == nil {
            Divider()
            submitRow(review)
        }
    }

    /// After the review went out: what you sent, and any suggestions left unused.
    @ViewBuilder
    private func sentRow(_ review: ClaudeReview, unused: [ClaudeReview.Suggestion]) -> some View {
        HStack(spacing: 8) {
            switch review.submitted {
            case "APPROVE": Pill(text: "You approved", symbol: "checkmark.seal.fill", tint: Theme.green)
            case "REQUEST_CHANGES": Pill(text: "You requested changes", symbol: "exclamationmark.bubble.fill", tint: Theme.red)
            default: Pill(text: "You commented", symbol: "text.bubble.fill", tint: Theme.blue)
            }
            if let at = review.submittedAt {
                Text(at.short == "now" ? "just now" : at.short + " ago").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // Changed your mind after the fixes: approve from here; it replaces the earlier review.
            if review.submitted != "APPROVE" && pr.lane != .mine {
                Button { Task { await submit(.approve) } } label: { Label("Approve now", systemImage: "checkmark.seal.fill") }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.green)
                    .controlSize(.small)
                    .disabled(busy)
                    .help("Approve the pull request. This replaces your earlier review; the summary box below goes with it.")
            }
            if !unused.isEmpty {
                Button(showUnused ? "Hide unused suggestions" : "\(unused.count) unused suggestion\(unused.count == 1 ? "" : "s")") {
                    withAnimation(.snappy) { showUnused.toggle() }
                }
                .buttonStyle(.link).font(.caption)
            }
        }
        if showUnused {
            ForEach(unused) { suggestion in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("\(suggestion.path):\(suggestion.line)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                        Spacer()
                        Button("Dismiss") { store.reviewer.markHandled(pr, [suggestion.id]) }.buttonStyle(.borderless)
                        Button("Add to a new review") { add(suggestion) }
                    }
                    .controlSize(.small)
                    MarkdownBody(text: suggestion.body)
                }
                .padding(9)
                .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    /// Send the review from here, without scrolling to the action bar.
    @ViewBuilder
    private func submitRow(_ review: ClaudeReview) -> some View {
        let pending = store.drafts[pr.nodeID]?.count ?? 0
        let with = pending == 0 ? "" : " with \(pending)"
        let empty = summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Your review").font(.subheadline.weight(.semibold))
                if pending > 0 {
                    Pill(text: "\(pending) pending comment\(pending == 1 ? "" : "s")", symbol: "clock", tint: Theme.amber)
                }
                Spacer()
                if empty, !review.summary.isEmpty {
                    Button("Use Claude's summary") { summary = review.summary }
                        .buttonStyle(.link).font(.caption)
                        .help("Fills the summary with Claude's text; edit it before sending")
                }
            }
            TextField("Summary (optional)…", text: $summary, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack(spacing: 8) {
                Text("Posts as \(store.name(actor)) on GitHub.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                submitButton("Request changes\(with)", symbol: "exclamationmark.bubble", event: .requestChanges,
                             prominent: review.verdict == "request_changes", tint: Theme.red)
                    .disabled(busy || (empty && pending == 0) || pr.lane == .mine)
                submitButton("Comment\(with)", symbol: "text.bubble", event: .comment,
                             prominent: review.verdict == "comment", tint: Theme.blue)
                    .disabled(busy || (empty && pending == 0))
                submitButton("Approve\(with)", symbol: "checkmark.seal.fill", event: .approve,
                             prominent: review.verdict == "approve", tint: Theme.green)
                    .disabled(busy || pr.lane == .mine)
            }
            .controlSize(.regular)
        }
    }

    /// Claude's verdict decides which button stands out; all three always work.
    @ViewBuilder
    private func submitButton(_ title: String, symbol: String, event: ReviewEvent, prominent: Bool, tint: Color) -> some View {
        let button = Button { Task { await submit(event) } } label: { Label(title, systemImage: symbol) }
        if prominent { button.buttonStyle(.borderedProminent).tint(tint) } else { button.buttonStyle(.bordered) }
    }

    /// Fills in what Hub didn't record (a review sent elsewhere, or before
    /// Hub kept track): suggestions already posted on their line count as
    /// handled, and your review after Claude's counts as sent.
    private func withGitHub(_ review: ClaudeReview) -> ClaudeReview {
        guard let conversation else { return review }
        var copy = review
        let trimmed = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines) }
        for s in review.comments where conversation.threads.contains(where: { thread in
            thread.path == s.path && (thread.line == s.line || thread.originalLine == s.line)
                && thread.comments.contains { trimmed($0.body) == trimmed(s.body) }
        }) {
            copy.handled.insert(s.id)
        }
        if copy.submitted == nil, let me = store.account(actor)?.account.login,
           let mine = conversation.timeline.last(where: { entry in
               guard entry.author.caseInsensitiveCompare(me) == .orderedSame, case .review = entry.kind else { return false }
               return entry.date > (review.reviewedAt ?? .distantPast)
           }), case .review(let state) = mine.kind {
            copy.submitted = switch state {
            case "APPROVED": "APPROVE"
            case "CHANGES_REQUESTED": "REQUEST_CHANGES"
            default: "COMMENT"
            }
            copy.submittedAt = mine.date
        }
        return copy
    }

    private func alreadyAdded(_ s: ClaudeReview.Suggestion) -> Bool {
        (store.drafts[pr.nodeID] ?? []).contains { $0.path == s.path && $0.line == s.line && $0.body == s.body }
    }

    private func add(_ s: ClaudeReview.Suggestion) {
        guard !alreadyAdded(s) else { return }
        store.drafts[pr.nodeID, default: []].append(DraftComment(path: s.path, line: s.line, side: s.side ?? .right, body: s.body, fromClaude: true))
        // Handled for good: sending the review clears the drafts, the suggestion stays gone.
        store.reviewer.markHandled(pr, [s.id])
    }
}

// MARK: Reviewers

struct RequestReviewersSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    var pr: PullRequest
    var actor: String
    var suggested: [Person]
    var already: [String]
    @State private var chosen: Set<String> = []
    @State private var typed = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Request reviewers").font(.title3.weight(.semibold))
            Text(verbatim: "#\(pr.number) \(pr.title)").foregroundStyle(.secondary).lineLimit(1)
            if !already.isEmpty {
                Text("Already requested: \(already.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
            }
            if !suggested.isEmpty {
                Text("Suggested").font(.subheadline.weight(.semibold))
                ForEach(suggested, id: \.login) { person in
                    Toggle(isOn: Binding(get: { chosen.contains(person.login) },
                                         set: { if $0 { chosen.insert(person.login) } else { chosen.remove(person.login) } })) {
                        HStack(spacing: 6) { Avatar(url: person.avatar, size: 18); Text(person.login) }
                    }
                }
            }
            TextField("Other logins, comma separated", text: $typed).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape, modifiers: [])
                Button("Request") { Task { await request() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(logins.isEmpty || busy)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private var logins: [String] {
        Array(chosen) + typed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "@", with: "") }.filter { !$0.isEmpty }
    }

    private func request() async {
        busy = true
        defer { busy = false }
        let pr = pr, logins = logins
        if await store.perform("Requested \(logins.joined(separator: ", "))", { try await $0.requestReviewers(pr, logins: logins) }, as: actor) {
            dismiss()
        }
    }
}


// MARK: Profile and usage

/// "as hd ▾": which Claude account runs the review, with each one's usage
/// from cpx, and the ways to change it.
struct ReviewProfileMenu: View {
    @Environment(Store.self) private var store
    var pr: PullRequest
    var actor: String
    var profile: CpxConfig.Profile?
    @Binding var overrideKey: String?
    @State private var binding: CpxConfig.Profile?
    @State private var bindError: String?

    var body: some View {
        let claude = store.claude
        let clone = claude.clonePath(for: pr.repo)
        let bound = clone.exists ? claude.cpx.boundProfile(for: clone.path) : nil
        let usage = claude.usage.account(profile?.name)
        HStack(spacing: 6) {
            if let usage { UsageGauge(account: usage) }
            // macOS menus show only a text label, so the chip sits beside it.
            Text("as")
            ProfileChip(name: profile?.name ?? "claude", color: profile?.color)
            Menu {
                Section("Review as") {
                    ForEach(claude.cpx.profiles, id: \.name) { p in
                        Button { overrideKey = p.name } label: {
                            Text(p.name + "  " + UsageGauge.text(claude.usage.account(p.name)))
                            if profile?.name == p.name { Image(systemName: "checkmark") }
                        }
                    }
                    Button { overrideKey = "@claude" } label: {
                        Text("claude (~/.claude)  " + UsageGauge.text(claude.usage.account(nil)))
                        if profile == nil { Image(systemName: "checkmark") }
                    }
                    if overrideKey != nil {
                        Button("Back to the usual profile") { overrideKey = nil }
                    }
                }
                Section {
                    if let at = claude.usage.writtenAt {
                        Text("Usage as cpx saw it \(RelativeDateTimeFormatter().localizedString(for: at, relativeTo: .now))")
                    } else {
                        Text("Usage shows once cpx's menu-bar app has refreshed")
                    }
                    if clone.exists, bound == nil, ClaudeLink.cpxInstalled, !claude.cpx.profiles.isEmpty {
                        Menu("Bind \((clone.path as NSString).abbreviatingWithTildeInPath) to…") {
                            ForEach(claude.cpx.profiles, id: \.name) { p in
                                Button(p.name) { binding = p }
                            }
                        }
                    }
                    if ClaudeLink.cpxAppInstalled {
                        Button("Manage profiles in cpx…") { ClaudeLink.openCpxApp() }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .font(.caption).foregroundStyle(.secondary)
        .help(help(bound: bound))
        .onAppear { claude.reloadUsage() }
        .confirmationDialog("Bind this clone to \(binding?.name ?? "")?", isPresented: Binding(get: { binding != nil }, set: { if !$0 { binding = nil } })) {
            Button("Bind") {
                guard let p = binding else { return }
                Task {
                    do { try await claude.bind(clone.path, to: p.name); overrideKey = nil }
                    catch { bindError = error.localizedDescription }
                }
            }
        } message: {
            Text("cpx writes an .envrc in \((clone.path as NSString).abbreviatingWithTildeInPath) so Claude started there runs as \(binding?.name ?? ""), and ignores it in .git/info/exclude (not .gitignore). Settings › Claude still wins when it names a profile for \(store.name(actor)).")
        }
        .alert("Couldn't bind", isPresented: Binding(get: { bindError != nil }, set: { if !$0 { bindError = nil } })) {
            Button("OK") { bindError = nil }
        } message: { Text(bindError ?? "") }
    }

    private func help(bound: String?) -> String {
        if overrideKey != nil { return "Picked for this review only." }
        if let profile {
            return bound == profile.name
                ? "\(profile.name): cpx bound the clone to it."
                : "\(profile.name): chosen for \(store.name(actor)) in Settings › Claude."
        }
        return "Plain `claude` (~/.claude). Pick a profile here, in Settings › Claude, or bind the clone with cpx."
    }
}

/// "5h 12% · week 44%", tinted by the fuller window.
struct UsageGauge: View {
    var account: CpxUsage.Account

    var body: some View {
        if account.isLoginProblem {
            Label("signed out", systemImage: "person.crop.circle.badge.exclamationmark").foregroundStyle(Theme.amber)
                .help("cpx can't read this login. Run \(account.command ?? "the profile's claude command") once to sign in again.")
        } else if let tightest = account.tightest {
            HStack(spacing: 4) {
                Gauge(value: min(tightest.usedPercent, 100), in: 0...100) {}
                    .gaugeStyle(.accessoryCircularCapacity)
                    .scaleEffect(0.38)
                    .frame(width: 16, height: 16)
                    .tint(Self.tint(tightest.usedPercent))
                Text(Self.text(account)).monospacedDigit()
            }
            .help(Self.detail(account))
        }
    }

    static func tint(_ used: Double) -> Color {
        used >= 90 ? Theme.red : used >= 70 ? Theme.amber : Theme.green
    }

    static func text(_ account: CpxUsage.Account?) -> String {
        guard let account else { return "" }
        if account.isLoginProblem { return "· signed out" }
        var parts: [String] = []
        if let s = account.session { parts.append("5h \(Int(s.usedPercent.rounded()))%") }
        if let w = account.weekly { parts.append("week \(Int(w.usedPercent.rounded()))%") }
        return parts.joined(separator: " · ")
    }

    static func detail(_ account: CpxUsage.Account) -> String {
        let format = RelativeDateTimeFormatter()
        var lines = account.windows.filter { $0.id == "session" || $0.id == "weekly" }.map { w in
            "\(w.title): \(Int(w.usedPercent.rounded()))% used" + (w.resetDate.map { ", resets \(format.localizedString(for: $0, relativeTo: .now))" } ?? "")
        }
        if let at = account.fetchedAt { lines.append("Checked \(format.localizedString(for: at, relativeTo: .now)) by cpx.") }
        return lines.joined(separator: "\n")
    }
}

/// A warning when the review's profile is close to a limit, offering the
/// account with the most room left.
struct UsageNotice: View {
    @Environment(Store.self) private var store
    var profile: CpxConfig.Profile?
    var others: [String?]
    var use: (String) -> Void

    var body: some View {
        let usage = store.claude.usage
        if let account = usage.account(profile?.name), CpxUsage.isNearLimit(account) || account.isLoginProblem {
            let name = profile?.name ?? "claude"
            let alternative = usage.roomiest(among: others, excluding: profile?.name)
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.67percent").foregroundStyle(Theme.amber)
                Text(message(name: name, account: account)).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let alternative {
                    Button("Use \(alternative.profile ?? "claude") (\(Int((alternative.tightest?.usedPercent ?? 0).rounded()))%)") {
                        use(alternative.profile ?? "@claude")
                    }
                    .controlSize(.small)
                }
            }
            .padding(8)
            .background(Theme.amber.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func message(name: String, account: CpxUsage.Account) -> String {
        if account.isLoginProblem { return "\(name) is signed out; the review would fail." }
        let format = RelativeDateTimeFormatter()
        guard let w = account.tightest else { return "" }
        let window = w.id == "session" ? "5-hour" : "weekly"
        return "\(name) has used \(Int(w.usedPercent.rounded()))% of its \(window) limit"
            + (w.resetDate.map { " (resets \(format.localizedString(for: $0, relativeTo: .now)))" } ?? "") + "."
    }
}

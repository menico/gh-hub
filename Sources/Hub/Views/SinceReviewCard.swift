import AppKit
import HubKit
import SwiftUI

/// What happened on a pull request after your last review: new commits, the
/// files they touched, and what other people said.
struct SinceReviewCard: View {
    @Environment(Store.self) private var store
    var pr: PullRequest
    var actor: String
    /// The PR's files, to send Claude only the ones touched since your review.
    var prFiles: [PRFile]
    var threads: [ReviewThread]
    var reviewedAt: Date
    var reviewedCommit: String?
    var headSHA: String?
    var code: CodeSinceReview?
    var replies: [Reply]
    @Binding var onlyChangedFiles: Bool
    var jump: (String) -> Void
    /// Scrolls to Claude's review card, where the result shows up.
    var showClaudeCard: () -> Void
    @State private var showAllCommits = false
    @AppStorage(ReviewPersona.selectedKey) private var defaultPersona = ReviewPersona.general.id
    @State private var showAllReplies = false

    private var compareURL: URL? {
        guard let reviewedCommit, let headSHA, reviewedCommit != headSHA else { return nil }
        return pr.url.appending(path: "files").appending(path: "\(reviewedCommit)..\(headSHA)")
    }

    var body: some View {
        let commits = code?.commits ?? []
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.violet)
                Text("Since your review").font(.headline)
                Text("\(reviewedAt.short) ago").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let compareURL {
                    WebLink(url: compareURL, help: "GitHub's diff of only what changed since your review") {
                        Label("Changes on GitHub", systemImage: "arrow.up.right.square").font(.caption)
                    }
                    .foregroundStyle(Theme.blue)
                }
            }

            if commits.isEmpty && replies.isEmpty && code?.rewritten != true {
                Text("Nothing new: no pushes and no replies.").font(.callout).foregroundStyle(.secondary)
            }

            if let code, code.rewritten {
                Label("The branch was rewritten (force-push or rebase) since you reviewed, so the list below may include changes that aren't the author's.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Theme.amber)
            }

            if !commits.isEmpty {
                section("\(commits.count) new commit\(commits.count == 1 ? "" : "s")", symbol: "point.3.connected.trianglepath.dotted") {
                    let shown = showAllCommits ? commits : Array(commits.suffix(5))
                    if commits.count > shown.count {
                        Button("Show \(commits.count - shown.count) earlier") { showAllCommits = true }.buttonStyle(.link).font(.caption)
                    }
                    ForEach(shown) { commit in
                        HStack(spacing: 8) {
                            if let url = commit.url {
                                WebLink(url: url, help: "Open \(commit.shortSHA) on GitHub") {
                                    Text(commit.shortSHA).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.blue)
                                }
                            } else {
                                Text(commit.shortSHA).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            Text(commit.title).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 4)
                            Text(commit.author).font(.caption).foregroundStyle(.secondary)
                            if let date = commit.date { Text(date.short).font(.caption).foregroundStyle(.tertiary) }
                        }
                        .font(.callout)
                    }
                }
            }

            if let code, !code.commits.isEmpty || code.rewritten {
                reReviewRow(code)
            }

            if let files = code?.files, !files.isEmpty {
                section("\(files.count) file\(files.count == 1 ? "" : "s") changed", symbol: "doc.badge.ellipsis") {
                    FlowLayout(spacing: 6) {
                        ForEach(files, id: \.self) { path in
                            Button { jump(path) } label: {
                                Text((path as NSString).lastPathComponent)
                                    .font(.system(size: 11, design: .monospaced))
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Theme.violet.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)
                            .help("Jump to \(path)")
                        }
                    }
                    Toggle("Show only these files in the diff below", isOn: $onlyChangedFiles)
                        .toggleStyle(.checkbox).font(.caption)
                }
            }

            if !replies.isEmpty {
                section("\(replies.count) new repl\(replies.count == 1 ? "y" : "ies")", symbol: "arrowshape.turn.up.left") {
                    let shown = showAllReplies ? replies : Array(replies.suffix(6))
                    if replies.count > shown.count {
                        Button("Show \(replies.count - shown.count) earlier") { showAllReplies = true }.buttonStyle(.link).font(.caption)
                    }
                    ForEach(shown) { reply in replyRow(reply) }
                }
            }
        }
        .card()
    }

    private func reReviewRow(_ code: CodeSinceReview) -> some View {
        let running = store.reviewer.isRunning(pr)
        let changed = Set(code.files)
        let subset = prFiles.filter { changed.contains($0.filename) }
        return HStack(spacing: 8) {
            Button {
                let me = store.account(actor)?.account.login ?? ""
                let focus = ClaudeReview.reReviewFocus(code: code, threads: threads, me: me)
                store.reviewer.review(pr, files: subset.isEmpty ? prFiles : subset, head: headSHA, claude: store.claude,
                                      accountID: actor, focus: focus, mode: .quick, followUp: true, persona: ReviewPersona.named(defaultPersona))
                showClaudeCard()
            } label: {
                Label(running ? "Claude is reviewing…" : "Re-review with Claude", systemImage: "sparkles")
            }
            .tint(Theme.claude)
            .disabled(running || prFiles.isEmpty)
            Text(subset.isEmpty
                 ? "Claude reviews the PR again, checking your open threads."
                 : "Claude reviews only the \(subset.count) changed file\(subset.count == 1 ? "" : "s") and checks whether your open threads were addressed.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help("A quick Claude review of what changed since your review. The result appears in Claude's review card; nothing is posted.")
    }

    private func section<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func replyRow(_ reply: Reply) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Avatar(url: reply.authorAvatar, size: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(reply.author).fontWeight(.semibold)
                    if let path = reply.path {
                        Button { jump(path) } label: {
                            Text(verbatim: "\((path as NSString).lastPathComponent)\(reply.line.map { ":\($0)" } ?? "")")
                                .font(.system(size: 11, design: .monospaced))
                        }
                        .buttonStyle(.link)
                        .help("Jump to \(path)")
                    } else {
                        Text("in the conversation").foregroundStyle(.secondary)
                    }
                    if reply.inYourThread { Pill(text: "your thread", symbol: "person.fill", tint: Theme.blue) }
                    Spacer(minLength: 4)
                    Text(reply.date.short).font(.caption).foregroundStyle(.tertiary)
                    if let url = reply.url {
                        WebLink(url: url, help: "Open this comment on GitHub") {
                            Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.callout)
                Text(reply.body).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }
}

/// Lays children out left to right, wrapping onto new rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

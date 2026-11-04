import AppKit
import HubKit
import SwiftUI

struct IssueDetailView: View {
    @Environment(Store.self) private var store
    var issue: Issue
    private var actor: String { store.acting(for: issue) }

    @State private var comment = ""
    @State private var busy = false
    @State private var confirmClose: Bool?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    LinkedItemsCard(title: "Linked pull requests", items: issue.linked,
                                    empty: "No pull request closes or mentions this issue yet.")
                    ClaudeCard(repo: issue.repo, accountID: actor, worktree: "issue-\(issue.number)",
                               sessions: store.claudeSessions(for: issue)) {
                        Button {
                            store.startClaude(on: issue, as: actor)
                        } label: { Label("Implement with Claude", systemImage: "hammer") }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.claude)
                    }
                    if !issue.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        MarkdownBody(text: issue.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .card()
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            actionBar
        }
        .confirmationDialog(
            "Close #\(issue.number)?",
            isPresented: Binding(get: { confirmClose != nil }, set: { if !$0 { confirmClose = nil } }),
            presenting: confirmClose
        ) { completed in
            Button(completed ? "Close as completed" : "Close as not planned") { Task { await close(completed: completed) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(issue.title)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "book.closed.fill").foregroundStyle(.tertiary)
                Text(issue.repo).foregroundStyle(.secondary)
                Text(verbatim: "#\(issue.number)").foregroundStyle(.tertiary).monospacedDigit()
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(Theme.color(for: actor)).frame(width: 7, height: 7)
                    Text("as \(store.name(actor))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.quaternary.opacity(0.5), in: Capsule())
            }
            .font(.callout)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "smallcircle.filled.circle").foregroundStyle(Theme.green)
                Text(issue.title)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .textSelection(.enabled)
            }
            .font(.system(size: 20))

            HStack(spacing: 8) {
                Avatar(url: issue.authorAvatar, size: 20)
                Text(issue.author).fontWeight(.medium)
                Text("opened \(issue.createdAt.short) ago").foregroundStyle(.secondary)
                if issue.comments > 0 {
                    Label("\(issue.comments)", systemImage: "bubble.left").foregroundStyle(.secondary)
                }
                Spacer()
                if !issue.assignees.isEmpty {
                    Text("Assigned").font(.caption).foregroundStyle(.tertiary)
                    HStack(spacing: -6) {
                        ForEach(issue.assignees, id: \.login) { person in
                            Avatar(url: person.avatar, size: 20)
                                .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                                .help(person.login)
                        }
                    }
                }
            }
            .font(.callout)

            if !issue.labels.isEmpty {
                HStack(spacing: 6) {
                    ForEach(issue.labels, id: \.name) { LabelChip(label: $0) }
                }
            }
        }
    }

    private var actionBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Write a comment…", text: $comment, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(9)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Button { NSWorkspace.shared.open(issue.url) } label: { Image(systemName: "safari") }
                .help("Open on GitHub")

            Menu {
                Button("Close as completed") { confirmClose = true }
                Button("Close as not planned") { confirmClose = false }
            } label: {
                Label("Close", systemImage: "checkmark.circle")
            } primaryAction: {
                confirmClose = true
            }
            .fixedSize()
            .disabled(busy)

            Button {
                Task { await postComment() }
            } label: {
                Label("Comment", systemImage: "bubble.left.fill").padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.blue)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(busy || comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .controlSize(.large)
        .padding(14)
        .background(.bar)
    }

    private func postComment() async {
        busy = true
        defer { busy = false }
        let issue = issue, body = comment
        if await store.perform("Commented on #\(issue.number)", { try await $0.comment(on: issue, body: body) }, as: actor) {
            comment = ""
        }
    }

    private func close(completed: Bool) async {
        busy = true
        defer { busy = false }
        let issue = issue
        _ = await store.perform("Closed #\(issue.number)", { try await $0.close(issue, completed: completed) }, as: actor)
    }
}

/// Pull requests ↔ issues. A linked item Hub has loaded opens in place;
/// anything else opens on GitHub.
struct LinkedItemsCard: View {
    @Environment(Store.self) private var store
    @Environment(Router.self) private var router
    var title: String
    var items: [LinkedItem]
    var empty: String? = nil

    var body: some View {
        if !items.isEmpty || empty != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "link").foregroundStyle(.secondary)
                    Text(title).font(.headline)
                    Text("\(items.count)").foregroundStyle(.secondary).monospacedDigit()
                }
                if items.isEmpty, let empty {
                    Text(empty).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    Button { open(item) } label: { row(item) }
                        .buttonStyle(HoverRowStyle())
                }
            }
            .card()
        }
    }

    private func row(_ item: LinkedItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol(item))
                .foregroundStyle(tint(item))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(spacing: 5) {
                    Text(verbatim: "\(item.repo)#\(item.number)")
                    Text("·")
                    Text(item.relation == .closes ? (item.kind == .pullRequest ? "closes this" : "closed by this") : "mentions")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Pill(text: stateLabel(item), tint: tint(item))
            Image(systemName: isLoaded(item) ? "chevron.right" : "arrow.up.right.square")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private func isLoaded(_ item: LinkedItem) -> Bool {
        item.kind == .pullRequest ? store.pullRequest(item) != nil : store.issue(item) != nil
    }

    private func open(_ item: LinkedItem) {
        if item.kind == .pullRequest, let pr = store.pullRequest(item) {
            router.open(pr.lane == .reviewRequested ? .reviews : .mine, .pr(pr))
        } else if item.kind == .issue, let issue = store.issue(item) {
            router.open(.issues, .issue(issue))
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    private func symbol(_ item: LinkedItem) -> String {
        if item.kind == .issue { return item.state == "OPEN" ? "smallcircle.filled.circle" : "checkmark.circle.fill" }
        switch item.state {
        case "MERGED": return "arrow.triangle.merge"
        case "CLOSED": return "xmark.circle"
        default: return "arrow.triangle.pull"
        }
    }

    private func stateLabel(_ item: LinkedItem) -> String {
        if item.isDraft && item.state == "OPEN" { return "Draft" }
        return item.state.capitalized
    }

    private func tint(_ item: LinkedItem) -> Color {
        switch item.state {
        case "MERGED": return Theme.violet
        case "CLOSED": return item.kind == .issue ? Theme.violet : Theme.red
        default: return item.isDraft ? .secondary : Theme.green
        }
    }
}

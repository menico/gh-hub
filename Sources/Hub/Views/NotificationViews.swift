import HubKit
import SwiftUI

struct NotificationRow: View {
    @Environment(Store.self) private var store
    @Environment(\.openURL) private var openURL
    var notification: GHNotification

    var body: some View {
        let n = notification
        HStack(alignment: .top, spacing: 10) {
            AccountStripe(accountID: n.accountID)
            Image(systemName: Self.symbol(n))
                .font(.system(size: 16))
                .foregroundStyle(Self.tint(n))
                .frame(width: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text(n.title)
                    .font(.system(size: 13, weight: n.unread ? .semibold : .regular))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(n.repo).lineLimit(1)
                    if let number = n.number { Text(verbatim: "#\(number)").monospacedDigit() }
                    Text("·")
                    Text(n.updatedAt.short)
                    Pill(text: n.reasonLabel, symbol: Self.reasonSymbol(n.reason), tint: Self.reasonTint(n.reason))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if n.unread {
                Circle().fill(Pane.notifications.tint).frame(width: 7, height: 7).padding(.top, 5)
            }
        }
        .opacity(n.unread ? 1 : 0.6)
        .padding(.vertical, 4)
        .contextMenu {
            if n.unread { Button("Mark as read") { store.markRead(n) } }
            Button("Mark as done") { store.markDone(n) }
            if let url = n.webURL { Button("Open on GitHub") { openURL(url) } }
        }
    }

    static func symbol(_ n: GHNotification) -> String {
        switch n.type {
        case "PullRequest": "arrow.triangle.pull"
        case "Issue": "smallcircle.filled.circle"
        case "Release": "tag.fill"
        case "Discussion": "bubble.left.and.bubble.right.fill"
        case "CheckSuite": "bolt.circle.fill"
        case "Commit": "point.3.connected.trianglepath.dotted"
        case "RepositoryVulnerabilityAlert", "RepositoryDependabotAlertsThread": "exclamationmark.shield.fill"
        default: "bell.fill"
        }
    }

    static func tint(_ n: GHNotification) -> Color {
        switch n.type {
        case "PullRequest": Theme.blue
        case "Issue": Theme.green
        case "Release": Theme.violet
        case "CheckSuite": Theme.amber
        case "RepositoryVulnerabilityAlert", "RepositoryDependabotAlertsThread": Theme.red
        default: Theme.gray
        }
    }

    static func reasonSymbol(_ reason: String) -> String {
        switch reason {
        case "mention", "team_mention": "at"
        case "review_requested": "eye"
        case "comment": "bubble.left"
        case "author": "person.fill"
        case "assign": "person.fill.checkmark"
        case "ci_activity": "bolt"
        case "security_alert": "exclamationmark.shield"
        default: "bell"
        }
    }

    static func reasonTint(_ reason: String) -> Color {
        switch reason {
        case "mention", "team_mention": Theme.pink
        case "review_requested", "approval_requested": Theme.violet
        case "assign": Theme.amber
        case "security_alert": Theme.red
        default: Theme.gray
        }
    }
}

/// A notification opened: its pull request or issue in full, with a bar to
/// mark it done. Opening it marks it read, as on github.com.
struct NotificationDetailView: View {
    @Environment(Store.self) private var store
    @Environment(\.openURL) private var openURL
    var notification: GHNotification
    @State private var subject: Selection?
    @State private var loading = false
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider().opacity(0.5)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            store.markRead(notification)
            guard notification.number != nil else { return }
            loading = true
            defer { loading = false }
            do { subject = try await store.subject(of: notification) } catch { problem = error.localizedDescription }
        }
    }

    private var bar: some View {
        let n = notification
        return HStack(spacing: 8) {
            Pill(text: n.reasonLabel, symbol: NotificationRow.reasonSymbol(n.reason), tint: NotificationRow.reasonTint(n.reason))
            Text("\(n.repo) · \(n.updatedAt.short) ago").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if let url = n.webURL {
                Button { openURL(url) } label: { Label("Open on GitHub", systemImage: "arrow.up.right.square") }
            }
            Button { store.markDone(n) } label: { Label("Done", systemImage: "checkmark") }
                .help("Remove it from your inbox here and on GitHub")
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var content: some View {
        switch subject {
        case .pr(let pr):
            let latest = (store.reviewRequests + store.reviewedPulls + store.myPulls).first { $0.nodeID == pr.nodeID } ?? pr
            PRDetailView(pr: latest).id(pr.nodeID)
        case .issue(let issue):
            let latest = store.issues.first { $0.nodeID == issue.nodeID } ?? issue
            IssueDetailView(issue: latest).id(issue.nodeID)
        default:
            if loading {
                ProgressView()
            } else if let problem {
                EmptyState(symbol: "exclamationmark.triangle", title: "Couldn't open it", subtitle: problem, tint: Theme.red)
            } else {
                EmptyState(symbol: NotificationRow.symbol(notification), title: notification.title,
                           subtitle: "\(notification.type) in \(notification.repo). Hub can't show this kind here; open it on GitHub.",
                           tint: NotificationRow.tint(notification))
            }
        }
    }
}

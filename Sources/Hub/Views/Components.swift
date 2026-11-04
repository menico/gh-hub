import HubKit
import SwiftUI

// MARK: Navigation

enum Pane: String, CaseIterable, Identifiable {
    case reviews, mine, repos, issues, actions, waiting, claude
    var id: String { rawValue }

    var title: String {
        switch self {
        case .reviews: "Review requests"
        case .mine: "My pull requests"
        case .repos: "Repositories"
        case .issues: "Issues"
        case .actions: "Actions"
        case .waiting: "Awaiting approval"
        case .claude: "Claude"
        }
    }

    var symbol: String {
        switch self {
        case .reviews: "eye.circle.fill"
        case .mine: "arrow.triangle.pull"
        case .repos: "books.vertical.fill"
        case .issues: "smallcircle.filled.circle"
        case .actions: "bolt.circle.fill"
        case .waiting: "hand.raised.circle.fill"
        case .claude: "sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .reviews: Theme.violet
        case .mine: Theme.blue
        case .repos: Color(red: 0.25, green: 0.75, blue: 0.85)
        case .issues: Theme.green
        case .actions: Theme.amber
        case .waiting: Theme.pink
        case .claude: Theme.claude
        }
    }
}

enum Selection: Hashable {
    case pr(PullRequest)
    case run(WorkflowRun)
    case issue(Issue)
    case terminal(UUID)
    case session(String)
    case worktree(String)

    var key: String {
        switch self {
        case .terminal(let id): "terminal:\(id)"
        case .session(let id): "session:\(id)"
        case .worktree(let path): "worktree:\(path)"
        case .pr(let pr): "pr:\(pr.nodeID)"
        case .issue(let issue): "issue:\(issue.nodeID)"
        case .run(let run): "run:\(run.id)"
        }
    }
}

/// Where the main window is; the menu bar can point it somewhere.
@MainActor
@Observable
final class Router {
    var section: Pane? = .reviews
    var selection: Selection?
    var showDispatch = false
    var showQuickOpen = false
    /// The account whose repository picker is open.
    var repoFocusAccount: String?
    /// The repository shown under Repositories ("owner/name").
    var browsingRepo: String? = UserDefaults.standard.string(forKey: "browsingRepo") {
        didSet { UserDefaults.standard.set(browsingRepo, forKey: "browsingRepo") }
    }

    /// Shows every open pull request of a repository.
    func browse(_ repo: String) {
        browsingRepo = repo
        section = .repos
    }

    /// Jump to an item in another section, e.g. from a linked issue to its pull request.
    func open(_ section: Pane, _ selection: Selection) {
        if self.section == section {
            self.selection = selection
        } else {
            self.section = section
            // Let the section change clear the old selection first.
            DispatchQueue.main.async { self.selection = selection }
        }
    }
}

// MARK: Theme

enum Theme {
    static let violet = Color(red: 0.56, green: 0.43, blue: 1.0)
    static let blue = Color(red: 0.30, green: 0.55, blue: 1.0)
    static let green = Color(red: 0.20, green: 0.80, blue: 0.50)
    static let red = Color(red: 1.0, green: 0.36, blue: 0.40)
    static let amber = Color(red: 1.0, green: 0.70, blue: 0.25)
    static let pink = Color(red: 1.0, green: 0.40, blue: 0.70)
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let gray = Color.secondary

    static let accentGradient = LinearGradient(
        colors: [violet, blue], startPoint: .topLeading, endPoint: .bottomTrailing)

    static let swatches: [Color] = [
        Color(red: 0.36, green: 0.55, blue: 1.0), Color(red: 0.36, green: 0.78, blue: 0.58),
        Color(red: 0.84, green: 0.58, blue: 0.32), Color(red: 0.79, green: 0.43, blue: 0.79),
        Color(red: 0.36, green: 0.74, blue: 0.84), Color(red: 0.83, green: 0.40, blue: 0.42),
    ]

    /// Accounts in the order gh lists them; the first gets the first swatch,
    /// so two accounts never share a colour.
    nonisolated(unsafe) static var accountOrder: [String] = []

    /// A stable colour per account, so rows say whose they are at a glance.
    static func color(for accountID: String) -> Color {
        if let index = accountOrder.firstIndex(of: accountID) { return swatches[index % swatches.count] }
        let sum = accountID.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return swatches[sum % swatches.count]
    }
}

// MARK: Small pieces

struct Avatar: View {
    var url: URL?
    var size: CGFloat = 22

    var body: some View {
        AsyncImage(url: url.map { URL(string: $0.absoluteString + (($0.query == nil) ? "?" : "&") + "s=\(Int(size * 2))") ?? $0 }) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Circle().fill(.quaternary)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.08)))
    }
}

extension EnvironmentValues {
    /// Pills show only their symbol when a row is too narrow for the words.
    @Entry var compactPills = false
}

struct Pill: View {
    var text: String
    var symbol: String? = nil
    var tint: Color = .secondary
    @Environment(\.compactPills) private var compact

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            if !(compact && symbol != nil) { Text(text).lineLimit(1) }
        }
        .fixedSize()
        .help(text)
        .font(.system(size: 10.5, weight: .semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(tint)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

struct CountBadge: View {
    var count: Int
    var tint: Color

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(tint.opacity(0.9), in: Capsule())
                .foregroundStyle(.white)
        }
    }
}

struct AccountStripe: View {
    var accountID: String
    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Theme.color(for: accountID))
            .frame(width: 3)
    }
}

struct RunGlyph: View {
    var phase: WorkflowRun.Phase
    var size: CGFloat = 14
    @State private var spin = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(tint)
            .rotationEffect(.degrees(phase == .running && spin ? 360 : 0))
            .animation(phase == .running ? .linear(duration: 1.6).repeatForever(autoreverses: false) : .default, value: spin)
            .onAppear { spin = true }
    }

    var symbol: String {
        switch phase {
        case .queued: "clock.fill"
        case .running: "arrow.triangle.2.circlepath"
        case .waiting: "hand.raised.fill"
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.octagon.fill"
        case .cancelled: "slash.circle.fill"
        case .skipped: "arrow.uturn.right.circle.fill"
        case .neutral: "circle.dashed"
        }
    }

    var tint: Color { RunGlyph.tint(phase) }

    static func tint(_ phase: WorkflowRun.Phase) -> Color {
        switch phase {
        case .queued: Theme.gray
        case .running: Theme.amber
        case .waiting: Theme.pink
        case .success: Theme.green
        case .failure: Theme.red
        case .cancelled, .skipped, .neutral: Theme.gray
        }
    }
}

struct ChecksGlyph: View {
    var state: CheckState?

    var body: some View {
        switch state {
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
        case .failure, .error: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.red)
        case .pending, .expected: Image(systemName: "circle.dotted").foregroundStyle(Theme.amber)
        case nil: Image(systemName: "circle").foregroundStyle(.quaternary)
        }
    }
}

struct ReviewPill: View {
    var decision: ReviewDecision?
    var body: some View {
        switch decision {
        case .approved: Pill(text: "Approved", symbol: "checkmark", tint: Theme.green)
        case .changesRequested: Pill(text: "Changes", symbol: "exclamationmark.bubble", tint: Theme.red)
        case .reviewRequired: Pill(text: "Needs review", symbol: "eye", tint: Theme.amber)
        case nil: EmptyView()
        }
    }
}

/// What you said last on a pull request you review: "You approved",
/// or "Re-requested" when the author asked you again after that.
struct MyReviewPill: View {
    var pr: PullRequest
    var waiting: Bool
    var body: some View {
        if pr.lane == .reviewRequested, let mine = pr.myReview {
            if waiting {
                Pill(text: "Re-requested", symbol: "arrow.uturn.backward", tint: Theme.violet)
            } else {
                switch mine {
                case .approved: Pill(text: "You approved", symbol: "checkmark.seal", tint: Theme.green)
                case .changesRequested: Pill(text: "You: changes", symbol: "exclamationmark.bubble", tint: Theme.red)
                case .commented: Pill(text: "You commented", symbol: "text.bubble", tint: .secondary)
                case .dismissed: Pill(text: "Dismissed", symbol: "xmark.bubble", tint: .secondary)
                }
            }
        }
    }
}

struct DiffStat: View {
    var additions: Int
    var deletions: Int
    var body: some View {
        HStack(spacing: 4) {
            Text("+\(additions)").foregroundStyle(Theme.green)
            Text("−\(deletions)").foregroundStyle(Theme.red)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
    }
}

struct EmptyState: View {
    var symbol: String
    var title: String
    var subtitle: String
    var tint: Color = Theme.violet

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(tint.gradient)
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ToastView: View {
    var toast: Store.Toast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(toast.message).font(.callout.weight(.medium)).lineLimit(3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.4)))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .padding(.bottom, 22)
    }

    private var symbol: String {
        switch toast.tone {
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    private var tint: Color {
        switch toast.tone {
        case .success: Theme.green
        case .failure: Theme.red
        case .info: Theme.blue
        }
    }
}

extension Date {
    /// "now", "4m", "3h", "2d", "5w".
    var short: String {
        let seconds = max(0, Date.now.timeIntervalSince(self))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(86_400 * 14): return "\(Int(seconds / 86_400))d"
        default: return "\(Int(seconds / (86_400 * 7)))w"
        }
    }
}

extension View {
    func card() -> some View {
        padding(14)
            .background(.background.secondary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}

extension Color {
    /// "#rrggbb".
    init?(hex: String) {
        guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }
}

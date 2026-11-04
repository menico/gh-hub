import HubKit
import SwiftUI

/// The account switcher at the top of the window: All, then one tab per
/// account, each with what needs you there.
struct AccountTabs: View {
    @Environment(Store.self) private var store
    @Environment(Router.self) private var router
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 4) {
            tab(id: nil) {
                AvatarStack(urls: store.shownAccounts.map(\.avatar))
                Text("All")
            }
            ForEach(store.shownAccounts) { state in
                tab(id: state.id) {
                    ZStack(alignment: .bottomTrailing) {
                        Avatar(url: state.avatar, size: 18)
                        if state.error != nil {
                            Circle().fill(Theme.red).frame(width: 7, height: 7)
                                .overlay(Circle().strokeBorder(.background, lineWidth: 1))
                        }
                    }
                    Text(store.name(state.id)).lineLimit(1)
                    if store.focusedRepos(state.id) != nil {
                        Image(systemName: "scope")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.color(for: state.id))
                            .help("Limited to \(store.focusSummary(state.id))")
                    }
                }
                .contextMenu {
                    RenameButton(accountID: state.id)
                    Button("Choose Repositories… (\(store.focusSummary(state.id)))") {
                        router.repoFocusAccount = state.id
                    }
                    Divider()
                    Button("Hide Account") {
                        store.hiddenAccounts.insert(state.id)
                        store.show(.info, "Hid \(store.name(state.id)). Show it again in Settings › Accounts.")
                    }
                }
                .help(state.error ?? "\(state.account.login) on \(state.account.host)")
            }
        }
        .padding(3)
        .background(.quaternary.opacity(0.35), in: Capsule())
        .animation(.snappy(duration: 0.25), value: store.activeScope)
    }

    private func tab<Label: View>(id: String?, @ViewBuilder label: () -> Label) -> some View {
        let selected = store.activeScope == id
        let tint = id.map(Theme.color(for:)) ?? Theme.violet
        let count = store.attention(for: id)
        return Button {
            store.scope = id
        } label: {
            HStack(spacing: 6) {
                label()
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(selected ? tint : Color.secondary.opacity(0.25), in: Capsule())
                        .foregroundStyle(selected ? .white : .secondary)
                        .fixedSize()
                }
            }
            .fixedSize()
            .font(.system(size: 12, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.leading, 6)
            .padding(.trailing, 9)
            .padding(.vertical, 4)
            .background {
                if selected {
                    Capsule()
                        .fill(tint.opacity(0.22))
                        .overlay(Capsule().strokeBorder(tint.opacity(0.65), lineWidth: 1))
                        .matchedGeometryEffect(id: "selected", in: selection)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct AvatarStack: View {
    var urls: [URL?]

    var body: some View {
        HStack(spacing: -7) {
            ForEach(Array(urls.prefix(3).enumerated()), id: \.offset) { _, url in
                Avatar(url: url, size: 18)
                    .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
            }
        }
    }
}

/// Lets an account go by a short name ("work", "personal") instead of its login.
struct RenameButton: View {
    @Environment(Store.self) private var store
    var accountID: String

    var body: some View {
        Button("Rename…") {
            let alert = NSAlert()
            alert.messageText = "Name for \(store.account(accountID)?.account.login ?? accountID)"
            alert.informativeText = "Shown on the account tab and in the sidebar. Leave empty to use the login."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            field.stringValue = store.aliases[accountID] ?? ""
            alert.accessoryView = field
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            if alert.runModal() == .alertFirstButtonReturn {
                let name = field.stringValue.trimmingCharacters(in: .whitespaces)
                store.aliases[accountID] = name.isEmpty ? nil : name
            }
        }
        if store.aliases[accountID] != nil {
            Button("Use login") { store.aliases[accountID] = nil }
        }
    }
}

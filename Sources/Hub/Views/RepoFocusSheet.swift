import HubKit
import SwiftUI

/// Choose the repositories one account works with.
struct RepoFocusSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    var accountID: String

    enum Mode: Hashable { case recent, selected }
    @State private var mode: Mode = .recent
    private var enabled: Bool { mode == .selected }
    @State private var selected: [String] = []
    @State private var candidates: [Repo] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var query = ""
    @State private var manual = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $mode) {
                Text("Recent activity").tag(Mode.recent)
                Text("Only selected repositories").tag(Mode.selected)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(16)

            if enabled {
                picker
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                    Text("Shows every pull request for this account, and Actions runs from the repositories it pushed to recently (see Settings › Actions).")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            HStack {
                if enabled {
                    Text("\(selected.count) selected").foregroundStyle(.secondary).monospacedDigit()
                    if !selected.isEmpty {
                        Button("Clear") { selected = [] }.buttonStyle(.link)
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(enabled && selected.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 540, height: 620)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Avatar(url: store.account(accountID)?.avatar, size: 34)
                Circle().fill(Theme.color(for: accountID)).frame(width: 11, height: 11)
                    .overlay(Circle().strokeBorder(.background, lineWidth: 2))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Repositories for \(store.name(accountID))").font(.title3.weight(.bold))
                Text("Your pull requests, runs and workflows outside these are hidden. Review requests always show.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
    }

    private var picker: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter repositories", text: $query).textFieldStyle(.plain)
                if loading { ProgressView().controlSize(.small) }
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 16)

            if let loadError {
                Text(loadError).font(.caption).foregroundStyle(Theme.red).padding(.horizontal, 16)
            }

            List {
                ForEach(rows, id: \.self) { name in
                    Toggle(isOn: Binding(
                        get: { isSelected(name) },
                        set: { on in
                            if on { selected.append(name) } else { selected.removeAll { $0.lowercased() == name.lowercased() } }
                        })
                    ) {
                        HStack(spacing: 6) {
                            let parts = name.split(separator: "/", maxSplits: 1).map(String.init)
                            Text(parts.first ?? "").foregroundStyle(.secondary)
                            Text("/").foregroundStyle(.tertiary)
                            Text(parts.last ?? name).fontWeight(.medium)
                            Spacer()
                            if let pushed = pushedAt[name.lowercased()] {
                                Text(pushed.short).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .listStyle(.inset)

            HStack {
                TextField("Add by name: owner/repo", text: $manual)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addManual)
                Button("Add", action: addManual)
                    .disabled(!manual.contains("/"))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    /// Selected first (in the order picked), then everything else by last push.
    private var rows: [String] {
        let chosen = selected.filter(matches)
        let lowered = Set(selected.map { $0.lowercased() })
        let rest = candidates.map(\.nameWithOwner).filter { !lowered.contains($0.lowercased()) && matches($0) }
        return chosen + rest
    }

    private var pushedAt: [String: Date] {
        Dictionary(candidates.compactMap { repo in repo.pushedAt.map { (repo.nameWithOwner.lowercased(), $0) } },
                   uniquingKeysWith: { a, _ in a })
    }

    private func matches(_ name: String) -> Bool {
        query.isEmpty || name.localizedCaseInsensitiveContains(query)
    }

    private func isSelected(_ name: String) -> Bool {
        selected.contains { $0.lowercased() == name.lowercased() }
    }

    private func addManual() {
        let name = manual.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "https://github.com/", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard name.split(separator: "/").count == 2, !isSelected(name) else { return }
        selected.insert(name, at: 0)
        manual = ""
    }

    private func load() async {
        let current = store.focus[accountID] ?? .init()
        mode = current.enabled ? .selected : .recent
        selected = current.repos
        // Start with what the dashboard already knows, then the full list.
        candidates = store.repos.filter { store.account($0.accountID) != nil }
        guard let client = store.client(accountID) else { loading = false; return }
        do {
            candidates = try await client.repositories()
        } catch {
            loadError = "Could not list every repository: \(error.localizedDescription)"
        }
        loading = false
    }

    private func save() {
        store.focus[accountID] = .init(enabled: enabled && !selected.isEmpty, repos: selected)
        store.show(.success, enabled ? "\(store.name(accountID)) now shows \(selected.count) repositories" : "\(store.name(accountID)) follows recent activity")
        Task { await store.refresh() }
        dismiss()
    }
}

/// "Recent activity" or "3 repositories", for menus and settings.
extension Store {
    func focusSummary(_ accountID: String) -> String {
        guard let entry = focus[accountID], entry.enabled else { return "Recent activity" }
        return entry.repos.count == 1 ? "1 repository" : "\(entry.repos.count) repositories"
    }
}

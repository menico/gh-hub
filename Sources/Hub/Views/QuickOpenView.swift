import AppKit
import Carbon.HIToolbox
import HubKit
import SwiftUI

/// ⌘K: jump to any pull request, issue, run, repository or Claude session
/// across accounts, or paste a GitHub link to open it in Hub.
struct QuickOpenView: View {
    @Environment(Store.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var index = 0
    @State private var resolving = false
    /// Open pull requests GitHub found for the text, beyond what Hub has loaded.
    @State private var remote: [PullRequest] = []
    @State private var searching = false
    @FocusState private var focused: Bool

    struct Hit: Identifiable {
        var id: String
        var symbol: String
        var tint: Color
        var title: String
        var detail: String
        var go: () -> Void
    }

    var body: some View {
        let hits = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: resolving ? "hourglass" : "magnifyingglass").foregroundStyle(.secondary)
                TextField("Pull requests, issues, runs, repositories — or paste a GitHub link", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
                    .onSubmit { open(hits) }
                    .onChange(of: text) { _, _ in index = 0 }
                if searching { ProgressView().controlSize(.small).help("Searching GitHub…") }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(hits.enumerated()), id: \.element.id) { offset, hit in
                            HStack(spacing: 10) {
                                Image(systemName: hit.symbol).foregroundStyle(hit.tint).frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(hit.title).lineLimit(1)
                                    Text(hit.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(offset == index ? Theme.blue.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                            .onTapGesture { index = offset; open(hits) }
                            .id(offset)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: index) { _, value in proxy.scrollTo(value) }
            }
            .frame(height: 380)
        }
        .frame(width: 620)
        .onAppear { focused = true }
        .task(id: text) {
            remote = []
            let q = text.trimmingCharacters(in: .whitespaces)
            guard q.count >= 3, GitHubLink.parse(q) == nil else { return }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            let found = await store.searchPulls(q)
            if !Task.isCancelled { remote = found }
        }
        .onKeyPress(.downArrow) { index = min(index + 1, max(hits.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func prHit(_ pr: PullRequest, detail: String) -> Hit {
        let pane: Pane = pr.lane == .mine ? .mine : .reviews
        return Hit(id: "pr:\(pr.nodeID)", symbol: pane.symbol, tint: pane.tint, title: "#\(pr.number) \(pr.title)",
                   detail: "\(pr.repo) · \(pr.author) · \(detail)") {
            go(pane, .pr(pr))
        }
    }

    private func open(_ hits: [Hit]) {
        guard hits.indices.contains(index) else { return }
        hits[index].go()
    }

    private func go(_ pane: Pane, _ selection: Selection) {
        dismiss()
        router.open(pane, selection)
    }

    private var results: [Hit] {
        let q = text.trimmingCharacters(in: .whitespaces)
        if let link = GitHubLink.parse(q) {
            if case .repository(let repo) = link {
                return [Hit(id: "link-prs", symbol: Pane.repos.symbol, tint: Pane.repos.tint, title: "Open pull requests in \(repo)", detail: q) {
                    dismiss(); router.browse(repo)
                }, Hit(id: "link", symbol: "safari", tint: Theme.blue, title: "Open \(repo) on GitHub", detail: q) {
                    dismiss(); if let url = URL(string: q) { NSWorkspace.shared.open(url) }
                }]
            }
            return [Hit(id: "link", symbol: "link", tint: Theme.blue, title: "Open this link in GH Hub", detail: q) {
                resolving = true
                Task {
                    let target = await store.resolve(link)
                    resolving = false
                    if let target { go(target.0, target.1) }
                }
            }]
        }
        func matches(_ fields: [String]) -> Bool {
            q.isEmpty || q.split(separator: " ").allSatisfy { word in fields.contains { $0.localizedCaseInsensitiveContains(word) } }
        }
        var hits: [Hit] = []
        for pane in Pane.allCases where !q.isEmpty && pane.title.localizedCaseInsensitiveContains(q) {
            hits.append(Hit(id: "pane:\(pane.rawValue)", symbol: pane.symbol, tint: pane.tint, title: pane.title, detail: "Go to") {
                dismiss(); router.section = pane
            })
        }
        var shownPRs = Set<String>()
        let loaded = store.visibleReviews + store.visibleReviewed + store.visibleMine
        let browsed = store.repoPulls.values.flatMap(\.pulls)
        for pr in loaded + browsed where matches([pr.title, pr.repo, pr.author, pr.headRef, "#\(pr.number)"]) {
            guard shownPRs.insert("\(pr.repo.lowercased())#\(pr.number)").inserted else { continue }
            hits.append(prHit(pr, detail: loaded.contains(pr) ? (pr.lane == .reviewRequested ? "review requested" : "yours") : "open"))
        }
        // GitHub's own search: titles and bodies Hub hasn't loaded.
        for pr in remote where shownPRs.insert("\(pr.repo.lowercased())#\(pr.number)").inserted {
            hits.append(prHit(pr, detail: "found on GitHub"))
        }
        for issue in store.visibleIssues where matches([issue.title, issue.repo, "#\(issue.number)"] + issue.labels.map(\.name)) {
            hits.append(Hit(id: "issue:\(issue.nodeID)", symbol: Pane.issues.symbol, tint: Pane.issues.tint,
                            title: "#\(issue.number) \(issue.title)", detail: "\(issue.repo) · issue") {
                go(.issues, .issue(issue))
            })
        }
        for run in store.visibleRuns.prefix(80) where !q.isEmpty && matches([run.name, run.title, run.repo, run.branch ?? ""]) {
            hits.append(Hit(id: "run:\(run.id)", symbol: "bolt.circle.fill", tint: RunGlyph.tint(run.phase),
                            title: "\(run.name) #\(run.runNumber) — \(run.title)", detail: "\(run.repo) · \(run.branch ?? "")") {
                go(.actions, .run(run))
            })
        }
        for session in store.claude.sessions.prefix(200) where !q.isEmpty && matches([session.prompt] + session.branches) {
            hits.append(Hit(id: "session:\(session.id)", symbol: "sparkles", tint: Theme.claude, title: session.prompt,
                            detail: "Claude session · \(session.cwd.abbreviatingHome)") {
                go(.claude, .session(session.id))
            })
        }
        // Repositories: the pushed ones, and any a loaded pull request lives in.
        var repoNames: [String] = []
        for name in store.repos.map(\.nameWithOwner) + loaded.map(\.repo) + Array(store.repoPulls.keys)
        where !repoNames.contains(where: { $0.lowercased() == name.lowercased() }) { repoNames.append(name) }
        for name in repoNames where !q.isEmpty && matches([name]) {
            hits.append(Hit(id: "repo:\(name)", symbol: Pane.repos.symbol, tint: Pane.repos.tint,
                            title: name, detail: "Repository · all its open pull requests") {
                dismiss()
                router.browse(name)
            })
        }
        if q.split(separator: "/").count == 2, !q.contains(" "), !repoNames.contains(where: { $0.lowercased() == q.lowercased() }) {
            hits.append(Hit(id: "repo-typed", symbol: Pane.repos.symbol, tint: Pane.repos.tint,
                            title: "Open pull requests in \(q)", detail: "Repository") {
                dismiss()
                router.browse(q)
            })
        }
        return Array(hits.prefix(60))
    }
}

/// A system-wide shortcut that brings Hub forward with ⌘K open. Carbon's
/// hot keys need no Accessibility permission.
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: (() -> Void)?

    enum Choice: String, CaseIterable, Identifiable {
        case off, ctrlOptH, ctrlOptCmdH, ctrlOptSpace
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: "Off"
            case .ctrlOptH: "⌃⌥H"
            case .ctrlOptCmdH: "⌃⌥⌘H"
            case .ctrlOptSpace: "⌃⌥Space"
            }
        }
        var key: (code: UInt32, modifiers: UInt32)? {
            switch self {
            case .off: nil
            case .ctrlOptH: (UInt32(kVK_ANSI_H), UInt32(controlKey | optionKey))
            case .ctrlOptCmdH: (UInt32(kVK_ANSI_H), UInt32(controlKey | optionKey | cmdKey))
            case .ctrlOptSpace: (UInt32(kVK_Space), UInt32(controlKey | optionKey))
            }
        }
        static var current: Choice { Choice(rawValue: UserDefaults.standard.string(forKey: "hotKey") ?? "") ?? .ctrlOptH }
    }

    func apply(_ choice: Choice = .current) {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        guard let key = choice.key else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.shared.action?() } }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4855_4221), id: 1) // "HUB!"
        RegisterEventHotKey(key.code, key.modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }
}

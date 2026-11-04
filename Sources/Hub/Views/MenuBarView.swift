import AppKit
import HubKit
import SwiftUI

/// The glanceable version: what needs you, one click from the full window.
struct MenuBarView: View {
    @Environment(Store.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("GH Hub").font(.headline)
                Spacer()
                if store.isRefreshing { ProgressView().controlSize(.mini) }
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
            }
            .padding(12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    block("Review requests", tint: Theme.violet, section: .reviews, count: store.allReviews.count) {
                        ForEach(store.allReviews.prefix(6)) { pr in
                            item(.pr(pr), section: .reviews) {
                                AccountStripe(accountID: pr.accountID).frame(height: 26)
                                Avatar(url: pr.authorAvatar, size: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(pr.title).lineLimit(1)
                                    Text("\(pr.repo) #\(pr.number)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                ChecksGlyph(state: pr.checks).font(.caption)
                            }
                        }
                    }
                    block("Assigned issues", tint: Theme.green, section: .issues, count: store.allAssigned.count) {
                        ForEach(store.allAssigned.prefix(4)) { issue in
                            item(.issue(issue), section: .issues) {
                                AccountStripe(accountID: issue.accountID).frame(height: 26)
                                Image(systemName: "smallcircle.filled.circle").foregroundStyle(Theme.green).frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(issue.title).lineLimit(1)
                                    Text(verbatim: "\(issue.repo) #\(issue.number)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }
                        }
                    }
                    block("Awaiting approval", tint: Theme.pink, section: .waiting, count: store.allWaiting.count) {
                        ForEach(store.allWaiting.prefix(4)) { run in runItem(run, section: .waiting) }
                    }
                    let failing = store.allFailingMine
                    block("Your failed runs", tint: Theme.red, section: .actions, count: failing.count) {
                        ForEach(failing.prefix(4)) { run in runItem(run, section: .actions) }
                    }
                    block("Running", tint: Theme.amber, section: .actions, count: store.allActive.count) {
                        ForEach(store.allActive.prefix(4)) { run in runItem(run, section: .actions) }
                    }
                    if store.allReviews.isEmpty && store.allAssigned.isEmpty && store.allWaiting.isEmpty && store.allActive.isEmpty && failing.isEmpty {
                        Label("All clear", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Theme.green)
                            .frame(maxWidth: .infinity)
                            .padding(24)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 460)

            Divider()

            HStack {
                Button("Open GH Hub") { open(nil) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .padding(12)
        }
        .frame(width: 360)
    }

    @ViewBuilder
    private func block<Content: View>(_ title: String, tint: Color, section: Pane, count: Int, @ViewBuilder content: () -> Content) -> some View {
        if count > 0 {
            HStack {
                Text(title.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(tint)
                Spacer()
                Text("\(count)").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.top, 8)
            content()
        }
    }

    private func runItem(_ run: WorkflowRun, section: Pane) -> some View {
        item(.run(run), section: section) {
            AccountStripe(accountID: run.accountID).frame(height: 26)
            RunGlyph(phase: run.phase, size: 14).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.title).lineLimit(1)
                Text("\(run.repo) · \(run.name)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(run.createdAt.short).font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func item<Content: View>(_ selection: Selection, section: Pane, @ViewBuilder content: () -> Content) -> some View {
        Button { open(section, selection) } label: {
            HStack(spacing: 8) { content() }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
    }

    private func open(_ section: Pane?, _ selection: Selection? = nil) {
        // The menu bar shows every account; make sure the window can show the pick.
        if selection != nil { store.scope = nil }
        if let section { router.section = section }
        if let selection {
            // Let the section change clear the old selection first.
            DispatchQueue.main.async { router.selection = selection }
        }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct HoverRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering || configuration.isPressed ? 0.08 : 0)))
            .onHover { hovering = $0 }
    }
}

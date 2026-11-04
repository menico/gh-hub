import AppKit
import HubKit
import SwiftUI

struct RunDetailView: View {
    @Environment(Store.self) private var store
    var initial: WorkflowRun
    /// A newer copy fetched while the run is going.
    @State private var fresh: WorkflowRun?
    private var run: WorkflowRun {
        if let fresh, fresh.updatedAt >= initial.updatedAt { return fresh }
        return initial
    }
    private var actor: String { store.acting(for: run) }

    @State private var jobs: [Job] = []
    @State private var pending: [PendingDeployment] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var busy = false
    @State private var logs: [Int: String] = [:]
    @State private var loadingLog: Int?
    @State private var approvalComment = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if !pending.isEmpty { approvalCard }
                    if run.phase == .failure || !store.claudeSessions(for: run).isEmpty {
                        ClaudeCard(repo: run.repo, accountID: actor, worktree: "run-\(run.id)", sessions: store.claudeSessions(for: run)) {
                            if run.phase == .failure {
                                Button {
                                    Task { await store.startClaude(on: run, as: actor) }
                                } label: { Label("Fix with Claude", systemImage: "wrench.and.screwdriver") }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.claude)
                            }
                        }
                    }
                    jobsSection
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            actionBar
        }
        .task(id: run.updatedAt) { await load() }
        .task(id: initial.id) { await follow() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "book.closed.fill").foregroundStyle(.tertiary)
                Text(run.repo).foregroundStyle(.secondary)
                Text(verbatim: "· \(run.name) #\(run.runNumber)").foregroundStyle(.tertiary)
                if run.runAttempt > 1 { Pill(text: "attempt \(run.runAttempt)", tint: .secondary) }
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

            HStack(alignment: .center, spacing: 12) {
                RunGlyph(phase: run.phase, size: 26)
                Text(run.title)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                Pill(text: phaseLabel, tint: RunGlyph.tint(run.phase))
                if let branch = run.branch { BranchChip(name: branch) }
                Pill(text: run.event.replacingOccurrences(of: "_", with: " "), symbol: "bolt", tint: .secondary)
                if let actor = run.actor {
                    HStack(spacing: 4) {
                        Avatar(url: run.actorAvatar, size: 16)
                        Text(actor)
                    }
                    .font(.caption)
                }
                Spacer()
                Text("started \(run.createdAt.short == "now" ? "just now" : "\(run.createdAt.short) ago")" + (duration.map { " · \($0)" } ?? "")).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var approvalCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Waiting for your review to deploy", systemImage: "hand.raised.fill")
                .font(.headline)
                .foregroundStyle(Theme.pink)
            HStack(spacing: 6) {
                ForEach(pending, id: \.environment.id) { deployment in
                    Pill(text: deployment.environment.name ?? "environment", symbol: "server.rack",
                         tint: deployment.currentUserCanApprove ? Theme.pink : .secondary)
                }
            }
            TextField("Comment (optional)", text: $approvalComment)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button(role: .destructive) { Task { await reviewDeployments(approve: false) } } label: {
                    Label("Reject", systemImage: "xmark")
                }
                Spacer()
                Button { Task { await reviewDeployments(approve: true) } } label: {
                    Label("Approve and deploy", systemImage: "checkmark.seal.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.green)
            }
            .controlSize(.large)
            .disabled(busy || !pending.contains(where: \.currentUserCanApprove))
            if !pending.contains(where: \.currentUserCanApprove) {
                Text("This account is not a required reviewer for these environments.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .card()
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.pink.opacity(0.5)))
    }

    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Jobs").font(.headline)
                Text("\(jobs.count)").foregroundStyle(.secondary)
            }
            if loading && jobs.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Loading jobs…").foregroundStyle(.secondary) }
            }
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.red)
            }
            ForEach(jobs) { job in
                JobCard(job: job, log: logs[job.id], loadingLog: loadingLog == job.id) {
                    Task { await loadLog(job) }
                }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button { NSWorkspace.shared.open(run.url) } label: {
                Label("Open on GitHub", systemImage: "safari")
            }
            Spacer()
            if run.isActive {
                Toggle(isOn: Binding(get: { store.watchedRuns.contains(run.id) },
                                     set: { if $0 { store.watchedRuns.insert(run.id) } else { store.watchedRuns.remove(run.id) } })) {
                    Label("Notify when done", systemImage: store.watchedRuns.contains(run.id) ? "bell.fill" : "bell")
                }
                .toggleStyle(.button)
                .help("A notification when this run finishes")
                Button(role: .destructive) {
                    Task { await act("Cancelled run #\(run.runNumber)") { try await $0.cancel(run) } }
                } label: {
                    Label("Cancel run", systemImage: "stop.circle")
                }
            } else {
                Button {
                    Task { await act("Re-running all jobs") { try await $0.rerun(run, failedOnly: false) } }
                } label: {
                    Label("Re-run all", systemImage: "arrow.clockwise")
                }
                if run.phase == .failure {
                    Button {
                        Task { await act("Re-running failed jobs") { try await $0.rerun(run, failedOnly: true) } }
                    } label: {
                        Label("Re-run failed", systemImage: "arrow.clockwise.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.amber)
                }
            }
        }
        .controlSize(.large)
        .disabled(busy)
        .padding(14)
        .background(.bar)
    }

    private var phaseLabel: String {
        switch run.phase {
        case .queued: "Queued"
        case .running: "Running"
        case .waiting: "Waiting"
        case .success: "Succeeded"
        case .failure: "Failed"
        case .cancelled: "Cancelled"
        case .skipped: "Skipped"
        case .neutral: run.conclusion?.capitalized ?? "Done"
        }
    }

    private var duration: String? {
        let end = run.isActive ? Date.now : run.updatedAt
        let seconds = Int(end.timeIntervalSince(run.createdAt))
        // GitHub's timestamps can run ahead of the local clock; say nothing rather than something negative.
        guard seconds >= 0 else { return nil }
        return seconds < 60 ? "\(seconds)s" : seconds < 3600 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }

    // MARK: Work

    /// While the run is going: fetch it and its jobs every few seconds, so
    /// steps tick over live.
    private func follow() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(run.isActive ? 5 : 30))
            guard run.isActive, let client = store.client(actor) else { continue }
            guard let latest = try? await client.run(repo: run.repo, id: run.id) else { continue }
            fresh = latest
            store.replace(latest)
            if let jobs = try? await client.jobs(of: latest) { self.jobs = jobs }
            if !latest.isActive, store.watchedRuns.contains(latest.id) {
                store.watchedRuns.remove(latest.id)
                store.notify(title: "\(latest.phase == .success ? "✓ Finished" : latest.phase == .failure ? "✗ Failed" : "Finished") · \(latest.repo)",
                             body: "\(latest.name) #\(latest.runNumber) — \(latest.title)")
            }
        }
    }

    private func load() async {
        guard let client = store.client(actor) else { return }
        do {
            async let jobs = client.jobs(of: run)
            async let pending: [PendingDeployment] = run.phase == .waiting ? client.pendingDeployments(of: run) : []
            self.jobs = try await jobs
            self.pending = (try? await pending) ?? []
            loadError = nil
            // A failed run opens on the log of its first failed job.
            if run.phase == .failure, logs.isEmpty, let failed = self.jobs.first(where: { $0.conclusion == "failure" }) {
                await loadLog(failed)
            }
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }

    private func loadLog(_ job: Job) async {
        if logs[job.id] != nil { logs[job.id] = nil; return }
        guard let client = store.client(actor) else { return }
        loadingLog = job.id
        defer { loadingLog = nil }
        do {
            logs[job.id] = try await client.logTail(repo: run.repo, job: job)
        } catch {
            logs[job.id] = "Could not load the log: \(error.localizedDescription)"
        }
    }

    private func act(_ message: String, _ work: @escaping (GitHubClient) async throws -> Void) async {
        busy = true
        defer { busy = false }
        _ = await store.perform(message, work, as: actor)
    }

    private func reviewDeployments(approve: Bool) async {
        let ids = pending.filter(\.currentUserCanApprove).map(\.environment.id)
        let run = run, comment = approvalComment
        await act(approve ? "Approved deployment" : "Rejected deployment") {
            try await $0.reviewDeployments(of: run, environments: ids, approve: approve, comment: comment)
        }
        pending = []
    }
}

struct JobCard: View {
    var job: Job
    var log: String?
    var loadingLog: Bool
    var toggleLog: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RunGlyph(phase: phase(job.status, job.conclusion), size: 15)
                Text(job.name).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let start = job.startedAt, (job.completedAt ?? .now) >= start {
                    let end = job.completedAt ?? .now
                    Text(format(end.timeIntervalSince(start))).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if job.status == "in_progress" {
                    Text("log when the job ends").font(.caption).foregroundStyle(.tertiary)
                        .help("GitHub only serves a job's log once it has finished; the steps update live.")
                }
                if job.status == "completed" {
                    Button(action: toggleLog) {
                        if loadingLog { ProgressView().controlSize(.mini) } else {
                            Label(log == nil ? "Log" : "Hide log", systemImage: "text.alignleft")
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                if let steps = job.steps, !steps.isEmpty {
                    Button { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } } label: {
                        Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(12)

            if expanded, let steps = job.steps {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(steps, id: \.number) { step in
                        HStack(spacing: 8) {
                            RunGlyph(phase: phase(step.status, step.conclusion), size: 11)
                            Text(step.name).font(.callout)
                                .foregroundStyle(step.conclusion == "skipped" ? .tertiary : .primary)
                        }
                    }
                }
                .padding(12)
            }

            if let log {
                Divider()
                ScrollView([.vertical, .horizontal]) {
                    Text(log)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .frame(maxHeight: 360)
                .background(.black.opacity(0.25))
            }
        }
        .background(.background.secondary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.5)))
        .onAppear { expanded = job.conclusion == "failure" || job.status == "in_progress" }
        .onChange(of: job.status) { _, status in if status == "in_progress" { expanded = true } }
    }

    private func phase(_ status: String, _ conclusion: String?) -> WorkflowRun.Phase {
        WorkflowRun.phase(status: status, conclusion: conclusion)
    }

    private func format(_ interval: TimeInterval) -> String {
        let s = Int(interval)
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }
}

import Foundation
import HubKit
import Observation

/// Runs Claude Code headless over a pull request's diff and keeps what it
/// said, so a review starts from a summary, the risky spots and draft comments.
@MainActor
@Observable
final class ClaudeReviewer {
    enum State {
        case running(started: Date)
        case done(ClaudeReview)
        case failed(String)
    }

    /// By pull request node id.
    private(set) var states: [String: State] = [:]
    /// The head commit each review looked at, to say when the PR moved on.
    private(set) var reviewedHead: [String: String] = [:]
    @ObservationIgnored private var processes: [String: Process] = [:]

    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.menico.gh-hub/reviews", isDirectory: true)
    }

    private struct Saved: Codable { var review: ClaudeReview; var head: String? }

    func state(for pr: PullRequest) -> State? {
        if states[pr.nodeID] == nil, let saved = load(pr.nodeID) {
            states[pr.nodeID] = .done(saved.review)
            reviewedHead[pr.nodeID] = saved.head
        }
        return states[pr.nodeID]
    }

    func isRunning(_ pr: PullRequest) -> Bool {
        if case .running = states[pr.nodeID] { return true }
        return false
    }

    var runningCount: Int { states.values.filter { if case .running = $0 { true } else { false } }.count }

    func cancel(_ pr: PullRequest) {
        processes[pr.nodeID]?.terminate()
        processes[pr.nodeID] = nil
        states[pr.nodeID] = nil
    }

    func discard(_ pr: PullRequest) {
        states[pr.nodeID] = nil
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(Self.fileName(pr.nodeID)))
    }

    /// Reviews with the account's Claude profile, from the clone when there is
    /// one (so Claude can read around the change), read-only.
    enum Mode: String, CaseIterable, Identifiable {
        /// Hub's own prompt over the numbered diff: one agent, under a minute.
        case quick
        /// Anthropic's /code-review plugin: parallel agents, each finding validated.
        case codeReview = "code-review"
        var id: String { rawValue }
        var label: String { self == .quick ? "Quick" : "/code-review" }
    }

    func review(_ pr: PullRequest, files: [PRFile], head: String?, claude: ClaudeLink, accountID: String, focus: String?,
                mode: Mode = .quick, persona: ReviewPersona = .general, ghToken: String? = nil, profileOverride: String? = nil) {
        guard !isRunning(pr) else { return }
        let clone = claude.clonePath(for: pr.repo)
        // "@claude" is plain claude; a name is that cpx profile, chosen for this review only.
        let profile = profileOverride.map { key in key == "@claude" ? nil : claude.cpx.profiles.first { $0.name == key } }
            ?? claude.profile(for: accountID, clone: clone.path)
        let command = claude.claudeCommand(profile)
        var prompt = mode == .quick
            ? ClaudeReview.prompt(for: pr, files: files, hasCheckout: clone.exists, focus: focus?.nilIfEmpty, persona: persona)
            : ClaudeReview.codeReviewPrompt(for: pr, persona: persona)
        if mode == .codeReview, let focus = focus?.nilIfEmpty { prompt += "\n(The reviewer also asks you to pay attention to: \(focus))" }
        let plugin = claude.codeReviewPlugin(for: profile)
        let id = pr.nodeID
        let cwd = clone.exists ? clone.path : NSTemporaryDirectory()
        let profileName = profile?.name
        states[id] = .running(started: .now)

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hub-review-\(UUID().uuidString).md")
        do { try prompt.write(to: tmp, atomically: true, encoding: .utf8) } catch {
            states[id] = .failed(error.localizedDescription); return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // The findings come back as structured output, so the conversation stays readable.
        let schema = Shell.quote(ClaudeReview.schema.split(whereSeparator: \.isNewline).joined())
        switch mode {
        case .quick:
            process.arguments = ["-c", "\(command) -p --output-format json --setting-sources user --max-turns \(persona.id == ReviewPersona.general.id ? 20 : 30) --allowedTools Read Grep Glob "
                + "--json-schema \(schema) < \(Shell.quote(tmp.path))"]
        case .codeReview:
            // Reading tools and read-only gh only; anything that could post is denied outright.
            let allowed = ["Read", "Grep", "Glob", "Task", "Agent", "TodoWrite",
                           "Bash(gh pr view:*)", "Bash(gh pr diff:*)", "Bash(gh issue view:*)", "Bash(gh issue list:*)",
                           "Bash(gh search:*)", "Bash(gh pr list:*)"]
            let denied = ["Bash(gh pr comment:*)", "Bash(gh pr review:*)", "Bash(gh api:*)",
                          "mcp__github_inline_comment__create_inline_comment", "Edit", "Write", "NotebookEdit"]
            let pluginFlag = plugin.enabled ? "" : plugin.dir.map { "--plugin-dir \(Shell.quote($0)) " } ?? ""
            process.arguments = ["-c", "\(command) -p --output-format json --setting-sources user --max-turns 120 \(pluginFlag)--json-schema \(schema) "
                + "--allowedTools \(allowed.map(Shell.quote).joined(separator: " ")) "
                + "--disallowedTools \(denied.map(Shell.quote).joined(separator: " ")) "
                + "-- \"$(cat \(Shell.quote(tmp.path)))\""]
        }
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ShellEnv.environment()
        // gh inside the review reads GitHub as the account that sees the PR; Quick never runs gh.
        if mode == .codeReview, let ghToken {
            env["GH_TOKEN"] = ghToken
            env["GITHUB_TOKEN"] = nil
        }
        process.environment = ReviewGuard.environment(env)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        processes[id] = process

        Task.detached(priority: .userInitiated) { [weak self] in
            var result: Result<ClaudeReview, Error>
            do {
                try process.run()
                // Read both pipes while it runs so neither fills up and stalls it.
                async let stdout = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
                async let stderr = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }.value
                let (data, errData) = await (stdout, stderr)
                process.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self)
                if var review = ClaudeReview.parse(text) {
                    review.cwd = cwd
                    review.profile = profileName
                    review.mode = mode.rawValue
                    review.persona = persona.name
                    result = .success(review.anchored(to: files))
                } else if process.terminationReason == .uncaughtSignal {
                    result = .failure(ReviewError(message: "Cancelled."))
                } else {
                    let detail = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    result = .failure(ReviewError(message: "Claude didn't return a review"
                        + (detail.isEmpty ? (said.isEmpty ? "." : ": " + String(said.suffix(400))) : ": " + String(detail.suffix(400)))))
                }
            } catch {
                result = .failure(error)
            }
            try? FileManager.default.removeItem(at: tmp)
            await self?.finish(id: id, process: process, head: head, result: result)
        }
    }

    private func finish(id: String, process: Process, head: String?, result: Result<ClaudeReview, Error>) {
        guard processes[id] === process else { return }
        processes[id] = nil
        switch result {
        case .success(var review):
            review.reviewedAt = .now
            states[id] = .done(review)
            reviewedHead[id] = head
            save(id, Saved(review: review, head: head))
        case .failure(let error):
            states[id] = .failed(error.localizedDescription)
        }
    }

    struct ReviewError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func fileName(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_") + ".json"
    }

    /// Changes the finished review for a PR and saves it.
    private func update(_ pr: PullRequest, _ change: (inout ClaudeReview) -> Void) {
        guard case .done(var review) = state(for: pr) else { return }
        change(&review)
        states[pr.nodeID] = .done(review)
        save(pr.nodeID, Saved(review: review, head: reviewedHead[pr.nodeID]))
    }

    /// A suggestion was added to the review or dismissed.
    func markHandled(_ pr: PullRequest, _ ids: [String]) {
        update(pr) { $0.handled.formUnion(ids) }
    }

    /// The review went to GitHub: Claude's card shows it as sent.
    func markSubmitted(_ pr: PullRequest, event: ReviewEvent) {
        update(pr) {
            $0.submitted = event.rawValue
            $0.submittedAt = .now
        }
    }

    private func save(_ id: String, _ saved: Saved) {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(saved).write(to: Self.folder.appendingPathComponent(Self.fileName(id)))
    }

    private func load(_ id: String) -> Saved? {
        guard let data = try? Data(contentsOf: Self.folder.appendingPathComponent(Self.fileName(id))) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Saved.self, from: data)
    }
}

extension ClaudeReviewer {
    /// Asks Claude whether the other side's answer to a review thread
    /// addresses it, and for a reply. Read-only, in the clone when there is one.
    func check(_ thread: ReviewThread, on pr: PullRequest, reviewer: String, files: [PRFile], claude: ClaudeLink,
               accountID: String, persona: ReviewPersona) async throws -> ThreadCheck {
        let clone = claude.clonePath(for: pr.repo)
        let profile = claude.profile(for: accountID, clone: clone.path)
        let patch = files.first { $0.filename == thread.path }?.patch
        let prompt = ThreadCheck.prompt(pr: pr, thread: thread, reviewer: reviewer, currentPatch: patch,
                                        hasCheckout: clone.exists, persona: persona)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hub-thread-\(UUID().uuidString).md")
        try prompt.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let schema = Shell.quote(ThreadCheck.schema.split(whereSeparator: \.isNewline).joined())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "\(claude.claudeCommand(profile)) -p --output-format json --setting-sources user --max-turns 12 --allowedTools Read Grep Glob "
            + "--json-schema \(schema) < \(Shell.quote(tmp.path))"]
        process.currentDirectoryURL = URL(fileURLWithPath: clone.exists ? clone.path : NSTemporaryDirectory())
        process.environment = ReviewGuard.environment(ShellEnv.environment())
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        return try await Task.detached(priority: .userInitiated) {
            try process.run()
            async let stdout = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
            async let stderr = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }.value
            let (data, errData) = await (stdout, stderr)
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            if let check = ThreadCheck.parse(text) { return check }
            let detail = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ReviewError(message: "Claude didn't answer" + (detail.isEmpty ? "." : ": " + String(detail.suffix(300))))
        }.value
    }
}

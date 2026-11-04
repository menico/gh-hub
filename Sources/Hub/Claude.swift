import AppKit
import Foundation
import HubKit
import Observation

/// Hub's link to Claude Code on this Mac: which sessions worked on which
/// repository and branch, where each repository is cloned, and how to start
/// Claude on a pull request, an issue or a failed run.
@MainActor
@Observable
final class ClaudeLink {
    private(set) var sessions: [ClaudeSession] = []
    /// Session id → lowercased "owner/repo" it ran in.
    private(set) var sessionRepo: [String: String] = [:]
    /// Lowercased "owner/repo" → local clones.
    private(set) var clones: [String: [String]] = [:]
    private(set) var cpx = CpxConfig()
    /// Rate-limit usage per Claude account, from cpx.
    private(set) var usage = CpxUsage()
    private(set) var lastScan: Date?
    private(set) var scanning = false

    @ObservationIgnored private let index = SessionIndex()
    @ObservationIgnored private var originCache: [String: String?] = [:]

    /// Bumped when a setting the views read from UserDefaults changes.
    var revision = 0
    /// Terminals running inside Hub.
    let terminals = TerminalManager()
    /// Called with a terminal Hub just opened, so the window can show it.
    @ObservationIgnored var showTerminal: ((UUID) -> Void)?

    var isStale: Bool { (lastScan ?? .distantPast) < .now.addingTimeInterval(-120) }

    // MARK: Scanning

    static var defaultCodeFolders: [String] {
        let home = CpxConfig.home
        return ["~/Documents", "~/Developer", "~/code", "~/src", "~/Projects", "~/GitHub", "~/repos"]
            .filter { FileManager.default.fileExists(atPath: ($0 as NSString).expandingTildeInPath.replacingOccurrences(of: "~", with: home)) }
    }

    var codeFolders: [String] {
        let custom = (UserDefaults.standard.string(forKey: "codeFolders") ?? "")
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // cpx's bound directories are always worth a look.
        let bound = cpx.bindings.map { ($0.path as NSString).deletingLastPathComponent }
        var seen = Set<String>()
        return ((custom.isEmpty ? Self.defaultCodeFolders : custom) + bound).filter { seen.insert($0).inserted }
    }

    func scan() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let cpx = CpxConfig.load()
        self.cpx = cpx
        reloadUsage()
        let folders = codeFolders
        let index = self.index
        let known = originCache
        let hidden = Self.hiddenSessionDirs
        let result = await Task.detached(priority: .utility) { () -> ([ClaudeSession], [String: String?], [String: [String]]) in
            let sessions = index.scan(configDirs: cpx.configDirs.filter { !hidden.contains(ClaudeLink.key(forConfigDir: $0)) })
            var origins = known
            for cwd in Set(sessions.map(\.cwd)) where origins[cwd] == nil {
                origins[cwd] = Git.origin(of: cwd)?.nameWithOwner.lowercased()
            }
            return (sessions, origins, Git.findClones(in: folders))
        }.value
        sessions = result.0
        originCache = result.1
        sessionRepo = Dictionary(result.0.compactMap { session in
            result.1[session.cwd].flatMap { $0 }.map { (session.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        clones = result.2
        lastScan = .now
    }

    // MARK: Hidden profiles

    /// Config dirs whose sessions Hub leaves out (Settings › Claude), by resolved path.
    static var hiddenSessionDirs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "hiddenSessionDirs") ?? [])
    }

    nonisolated static func key(forConfigDir dir: String) -> String {
        URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
    }

    func setSessionsShown(_ shown: Bool, configDir: String) {
        var hidden = Self.hiddenSessionDirs
        if shown { hidden.remove(Self.key(forConfigDir: configDir)) } else { hidden.insert(Self.key(forConfigDir: configDir)) }
        UserDefaults.standard.set(Array(hidden).sorted(), forKey: "hiddenSessionDirs")
        Task { await scan() }
    }

    /// "claude (default)", a cpx profile's name, or the folder for a hand-made one.
    func label(forConfigDir dir: String) -> String {
        if Self.key(forConfigDir: dir) == Self.key(forConfigDir: CpxConfig.home + "/.claude") { return "claude (default)" }
        if let profile = cpx.profile(forConfigDir: dir) { return profile.name }
        return (dir as NSString).lastPathComponent
    }

    // MARK: cpx

    /// Picks up what cpx's menu-bar app last wrote. Hub never runs
    /// `cpx usage` itself: reading a login can raise a Keychain dialog.
    func reloadUsage() {
        if let snapshot = CpxUsage.loadSnapshot() { usage = snapshot }
    }

    /// Binds a folder to a profile with `cpx bind`, which writes the folder's
    /// .envrc and ignores it locally (.git/info/exclude).
    func bind(_ folder: String, to profile: String) async throws {
        _ = try await Self.cpx(["bind", profile, folder])
        cpx = CpxConfig.load()
        revision += 1
    }

    static var cpxInstalled: Bool { cpxPath != nil }

    private static var cpxPath: String? {
        let path = ShellEnv.environment()["PATH"] ?? ""
        return path.split(separator: ":").map { "\($0)/cpx" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func cpx(_ arguments: [String]) async throws -> String {
        guard let executable = cpxPath else { throw Git.Failure(message: "cpx is not installed (brew install menico/tap/cpx).") }
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = ShellEnv.environment()
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errors = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw Git.Failure(message: message.isEmpty ? "cpx \(arguments.first ?? "") failed." : message)
            }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    /// Opens cpx's menu-bar app (its settings window when it is already running).
    static func openCpxApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.github.menico.cpx") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    static var cpxAppInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.github.menico.cpx") != nil
    }

    // MARK: Matching

    private func sessions(in repo: String, where match: (ClaudeSession) -> Bool) -> [ClaudeSession] {
        let repo = repo.lowercased()
        return sessions.filter { sessionRepo[$0.id] == repo && match($0) }
    }

    func sessions(for pr: PullRequest) -> [ClaudeSession] {
        sessions(in: pr.repo) { $0.branches.contains(pr.headRef) }
    }

    func sessions(for issue: Issue, prBranches: [String]) -> [ClaudeSession] {
        let number = String(issue.number)
        return sessions(in: issue.repo) { session in
            if session.branches.contains(where: prBranches.contains) { return true }
            if session.prompt.contains("#\(number)") || session.prompt.contains(issue.url.absoluteString) { return true }
            // A branch named after the issue: 786-fix, feat/786-thing, issue-786.
            return issue.number >= 10 && session.branches.contains { branch in
                branch.split(whereSeparator: { "/-_.".contains($0) }).contains { $0 == number }
            }
        }
    }

    func sessions(for run: WorkflowRun, defaultBranch: String?) -> [ClaudeSession] {
        guard let branch = run.branch, branch != defaultBranch else { return [] }
        return sessions(in: run.repo) { $0.branches.contains(branch) }
    }

    // MARK: Where and as whom

    /// The clone to work from: one Hub found, or where a fresh clone will go.
    func clonePath(for repo: String) -> (path: String, exists: Bool) {
        if let found = clones[repo.lowercased()]?.sorted(by: { a, b in
            // Prefer a clone cpx has bound to a profile, then the shortest path.
            let boundA = cpx.boundProfile(for: a) != nil, boundB = cpx.boundProfile(for: b) != nil
            return boundA != boundB ? boundA : a.count < b.count
        }).first {
            return (found, true)
        }
        let base = (UserDefaults.standard.string(forKey: "cloneFolder")?.nilIfEmpty ?? Self.defaultCloneFolder) as NSString
        let name = repo.split(separator: "/").last.map(String.init) ?? repo
        return (base.expandingTildeInPath + "/" + name, false)
    }

    static var defaultCloneFolder: String {
        FileManager.default.fileExists(atPath: CpxConfig.home + "/Documents/GitHub") ? "~/Documents/GitHub" : "~/Developer"
    }

    /// The Claude profile to start as for an account in a clone: the one
    /// chosen in Settings, else the one cpx bound to the clone, else plain `claude`.
    func profile(for accountID: String, clone: String) -> CpxConfig.Profile? {
        let choice = UserDefaults.standard.string(forKey: "claudeProfile.\(accountID)") ?? ""
        switch choice {
        case "": return cpx.boundProfile(for: clone).flatMap { name in cpx.profiles.first { $0.name == name } }
        case "default": return nil
        default: return cpx.profiles.first { $0.name == choice }
        }
    }

    /// The shell command that starts Claude as a profile (or as plain `claude`).
    func claudeCommand(_ profile: CpxConfig.Profile?) -> String {
        if let profile {
            let wrapper = CpxConfig.home + "/.local/bin/claude-\(profile.name)"
            if FileManager.default.isExecutableFile(atPath: wrapper) { return Shell.quote(wrapper) }
            return "env CLAUDE_CONFIG_DIR=\(Shell.quote(profile.dir)) claude"
        }
        return "env -u CLAUDE_CONFIG_DIR -u CLAUDE_PROFILE claude"
    }

    /// Where Anthropic's code-review plugin is for a profile: switched on in
    /// its settings, or on disk somewhere so Hub can load it for one run.
    func codeReviewPlugin(for profile: CpxConfig.Profile?) -> (enabled: Bool, dir: String?) {
        let home = CpxConfig.home
        let own = profile?.dir ?? home + "/.claude"
        var enabled = false
        if let data = FileManager.default.contents(atPath: own + "/settings.json"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let plugins = json["enabledPlugins"] as? [String: Any] {
            enabled = plugins["code-review@claude-plugins-official"] as? Bool ?? false
        }
        let candidates = [own] + cpx.configDirs + [home + "/.claude"]
        let dir = candidates
            .map { $0 + "/plugins/marketplaces/claude-plugins-official/plugins/code-review" }
            .first { FileManager.default.fileExists(atPath: $0 + "/commands/code-review.md") }
        return (enabled, dir)
    }

    func profileName(forSession session: ClaudeSession) -> String {
        cpx.profile(forConfigDir: session.configDir)?.name
            ?? (session.configDir.hasSuffix("/.claude") ? "default" : (session.configDir as NSString).lastPathComponent)
    }

    func profileColor(forSession session: ClaudeSession) -> String? {
        cpx.profile(forConfigDir: session.configDir)?.color
    }

    // MARK: Launching

    enum Setup {
        /// `gh pr checkout` into the worktree.
        case pullRequest(Int, base: String)
        /// A new branch from the default branch.
        case newBranch(String, base: String)
        /// A detached checkout of a remote branch.
        case detached(String)
    }

    struct Plan {
        var title: String
        var repo: String
        var account: Account
        var worktree: String
        var setup: Setup
        var prompt: String?
    }

    /// Writes a script that clones if needed, makes or reuses a worktree,
    /// signs gh in as the right account, and starts Claude with the prompt;
    /// then opens it in Terminal.
    func launch(_ plan: Plan) throws -> String {
        let clone = clonePath(for: plan.repo)
        let worktree = clone.path + "-worktrees/" + plan.worktree
        let profile = profile(for: plan.account.id, clone: clone.path)

        var lines = [
            "#!/bin/bash",
            "# Written by GH Hub to start Claude on \(plan.repo).",
            "printf '\\033]0;%s\\007' \(Shell.quote("Hub · " + plan.title))",
            "clear",
            // gh (and git pushes through gh) act as the account Hub saw this with.
            "export GH_TOKEN=\"$(env -u GH_TOKEN -u GITHUB_TOKEN gh auth token --hostname \(Shell.quote(plan.account.host)) --user \(Shell.quote(plan.account.login)))\"",
            "CLONE=\(Shell.quote(clone.path))",
            "WT=\(Shell.quote(worktree))",
            "if [ ! -e \"$CLONE/.git\" ]; then",
            "  echo \"Cloning \(plan.repo) into $CLONE…\"",
            "  mkdir -p \"$(dirname \"$CLONE\")\" && gh repo clone \(Shell.quote(plan.repo)) \"$CLONE\" || { echo 'Clone failed.'; exec $SHELL; }",
            "fi",
            "cd \"$CLONE\" || exec $SHELL",
            "git fetch origin --prune --quiet",
            "if [ ! -e \"$WT\" ]; then",
            "  echo \"Making a worktree at $WT…\"",
        ]
        switch plan.setup {
        case .pullRequest(let number, let base):
            lines += [
                "  git worktree add --quiet --detach \"$WT\" \(Shell.quote("origin/" + base)) || exec $SHELL",
                "  cd \"$WT\" && { gh pr checkout \(number) || gh pr checkout \(number) --branch pr-\(number); } || exec $SHELL",
                "else",
                "  cd \"$WT\" && git pull --ff-only --quiet || true",
            ]
        case .newBranch(let branch, let base):
            lines += [
                "  git worktree add --quiet -b \(Shell.quote(branch)) \"$WT\" \(Shell.quote("origin/" + base)) 2>/dev/null"
                    + " || git worktree add --quiet \"$WT\" \(Shell.quote(branch)) || exec $SHELL",
            ]
        case .detached(let branch):
            lines += [
                "  git worktree add --quiet --detach \"$WT\" \(Shell.quote("origin/" + branch)) || exec $SHELL",
            ]
        }
        lines += ["fi", "cd \"$WT\" || exec $SHELL"]

        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.menico.gh-hub/launch", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID().uuidString.prefix(8)
        let command = claudeCommand(profile)
        lines += [
            "echo",
            "echo \"Claude\(profile.map { " (\($0.name))" } ?? "") in $WT, on $(git branch --show-current 2>/dev/null || echo detached)\"",
            "echo",
        ]
        if let prompt = plan.prompt {
            let promptFile = dir.appendingPathComponent("prompt-\(id).md")
            try prompt.write(to: promptFile, atomically: true, encoding: .utf8)
            lines.append("\(command) \"$(cat \(Shell.quote(promptFile.path)))\"")
        } else {
            lines.append(command)
        }
        // When Claude ends, stay in the worktree with a shell.
        lines += ["echo", "echo \"Claude has exited. This shell is in $WT.\"", "exec \"${SHELL:-/bin/zsh}\" -l"]
        return try open(lines, in: dir, id: String(id), title: plan.title, repo: plan.repo)
    }

    /// A shell in a folder, in whichever terminal is chosen.
    func openShell(in folder: String, title: String, repo: String?, command: String? = nil) throws {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.menico.gh-hub/launch", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try open([
            "#!/bin/bash",
            "cd \(Shell.quote(folder)) || exit 1",
            command ?? "",
            "exec \"${SHELL:-/bin/zsh}\" -l",
        ], in: dir, id: String(UUID().uuidString.prefix(8)), title: title, repo: repo)
    }

    /// Opens a past session where it ran, as the profile it ran under.
    func resume(_ session: ClaudeSession) throws {
        let profile = cpx.profile(forConfigDir: session.configDir)
        let command: String
        if let profile {
            command = claudeCommand(profile)
        } else if session.configDir.hasSuffix("/.claude") {
            command = claudeCommand(nil)
        } else {
            command = "env CLAUDE_CONFIG_DIR=\(Shell.quote(session.configDir)) claude"
        }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.menico.gh-hub/launch", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try open([
            "#!/bin/bash",
            "printf '\\033]0;%s\\007' \(Shell.quote("Hub · resume " + session.prompt.prefix(40)))",
            "clear",
            "cd \(Shell.quote(session.cwd)) || { echo 'That folder is gone (a removed worktree?).'; exec $SHELL; }",
            "\(command) --resume \(Shell.quote(session.id))",
            "exec \"${SHELL:-/bin/zsh}\" -l",
        ], in: dir, id: String(UUID().uuidString.prefix(8)), title: "Resume · " + String(session.prompt.prefix(40)),
           repo: sessionRepo[session.id])
    }

    /// Picks up a headless review as a conversation, to ask Claude about it.
    func resumeReview(_ review: ClaudeReview, title: String, repo: String) throws {
        guard let id = review.sessionID, let cwd = review.cwd else { return }
        let profile = review.profile.flatMap { name in cpx.profiles.first { $0.name == name } }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.menico.gh-hub/launch", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try open([
            "#!/bin/bash",
            "printf '\\033]0;%s\\007' \(Shell.quote("Hub · " + title))",
            "clear",
            "cd \(Shell.quote(cwd)) || exit 1",
            "\(claudeCommand(profile)) --resume \(Shell.quote(id))",
            "exec \"${SHELL:-/bin/zsh}\" -l",
        ], in: dir, id: String(UUID().uuidString.prefix(8)), title: title, repo: repo)
    }

    /// Writes the script and runs it where the person chose: a terminal
    /// inside Hub, Ghostty, Terminal or iTerm. A `.command` file opens in
    /// Terminal or iTerm without asking for Automation access.
    private func open(_ lines: [String], in dir: URL, id: String, title: String, repo: String?) throws -> String {
        let script = dir.appendingPathComponent("hub-\(id).command")
        try (lines.joined(separator: "\n") + "\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        // HUB_NO_OPEN writes the script without running it (for checking what Hub would do).
        if ProcessInfo.processInfo.environment["HUB_NO_OPEN"] == nil {
            switch TerminalChoice.current {
            case .hub:
                let session = terminals.start(script: script.path, title: title, repo: repo)
                showTerminal?(session.id)
            case .ghostty:
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-na", "Ghostty", "--args", "-e", "/bin/bash", script.path]
                try process.run()
            case .terminal, .iterm:
                let choice = TerminalChoice.current
                if let bundleID = choice.bundleID, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    NSWorkspace.shared.open([script], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                } else {
                    NSWorkspace.shared.open(script)
                }
            }
        }
        // Old launch files are of no further use.
        if let old = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for file in old where ((try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now) < .now.addingTimeInterval(-86_400) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        return script.path
    }
}

enum Shell {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }

    /// "~/Documents/x" for paths in the home folder.
    var abbreviatingHome: String { (self as NSString).abbreviatingWithTildeInPath }

    /// "fix-the-login-bug" from a title, for branch names.
    var slug: String {
        let words = lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(6)
        return String(words.joined(separator: "-").prefix(40))
    }
}

// MARK: Prompts

enum Prompts {
    static func reviewComments(_ pr: PullRequest) -> String {
        """
        Address the review feedback on pull request #\(pr.number) in \(pr.repo): "\(pr.title)" (\(pr.headRef) → \(pr.baseRef)).

        This worktree is checked out on the PR branch. Read the open review threads first:
          gh pr view \(pr.number) --comments
          gh api repos/\(pr.repo)/pulls/\(pr.number)/comments
        Make the changes the reviewers asked for, run the relevant tests, then commit and push to the PR branch \
        (if `git push` complains about the branch name, use `git push origin HEAD:\(pr.headRef)`). \
        Tell me which comments you addressed and which you think need a reply instead of a change.
        """
    }

    static func failingChecks(_ pr: PullRequest, runs: [WorkflowRun], log: String?) -> String {
        var text = """
        The checks on pull request #\(pr.number) in \(pr.repo) are failing: "\(pr.title)" (\(pr.headRef) → \(pr.baseRef)).

        This worktree is checked out on the PR branch.
        """
        if !runs.isEmpty {
            text += "\n\nFailed runs:\n" + runs.prefix(5).map { "- \($0.name) #\($0.runNumber): \($0.url.absoluteString) (run id \($0.id))" }.joined(separator: "\n")
        }
        if let log, !log.isEmpty {
            text += "\n\nEnd of the first failed job's log:\n```\n\(log)\n```"
        }
        text += """


        Use `gh pr checks \(pr.number)` and `gh run view <run id> --log-failed` for more. Find the cause, fix it, \
        reproduce and run the check locally where you can, then commit and push to the PR branch \
        (or `git push origin HEAD:\(pr.headRef)`).
        """
        return text
    }

    static func implement(_ issue: Issue, branch: String, base: String) -> String {
        let body = issue.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Implement issue #\(issue.number) in \(issue.repo): "\(issue.title)"
        \(issue.url.absoluteString)

        \(body.isEmpty ? "(The issue has no description; read its comments with `gh issue view \(issue.number) --comments`.)" : String(body.prefix(6000)))

        This worktree is on a new branch, \(branch), from \(base). Read the comments too (`gh issue view \(issue.number) --comments`). \
        Start with a short plan, then implement it with tests. Commit as you go. \
        When it works, ask me before pushing and opening a pull request; the PR should say "Closes #\(issue.number)".
        """
    }

    static func failedRun(_ run: WorkflowRun, job: String?, log: String?) -> String {
        var text = """
        Workflow run "\(run.name)" #\(run.runNumber) failed on \(run.branch ?? "?") in \(run.repo): "\(run.title)"
        \(run.url.absoluteString) (run id \(run.id))
        """
        if let job { text += "\nFailing job: \(job)" }
        if let log, !log.isEmpty { text += "\n\nEnd of its log:\n```\n\(log)\n```" }
        text += """


        This worktree is a detached checkout of origin/\(run.branch ?? "HEAD"). Use `gh run view \(run.id) --log-failed` for the full log. \
        Find the cause and fix it; reproduce it locally where you can. Don't push until I've seen the fix.
        """
        return text
    }
}

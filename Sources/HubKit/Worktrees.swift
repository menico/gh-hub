import Foundation

/// A git worktree Hub made next to a clone (`<clone>-worktrees/<name>`).
public struct Worktree: Identifiable, Hashable, Sendable {
    public let path: String
    public let clone: String
    public let branch: String?
    public let head: String?
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String, clone: String, branch: String? = nil, head: String? = nil) {
        self.path = path
        self.clone = clone
        self.branch = branch
        self.head = head
    }

    /// `pr-123` → 123.
    public var pullRequestNumber: Int? { name.hasPrefix("pr-") ? Int(name.dropFirst(3)) : nil }
    public var issueNumber: Int? { name.hasPrefix("issue-") ? Int(name.dropFirst(6)) : nil }
}

/// What is left in a worktree that removing it would throw away.
public struct WorktreeChanges: Hashable, Sendable {
    public var modifiedFiles: Int
    /// Commits not on the upstream branch; nil when there is no upstream.
    public var unpushedCommits: Int?
    public var isClean: Bool { modifiedFiles == 0 && (unpushedCommits ?? 0) == 0 }

    public init(modifiedFiles: Int, unpushedCommits: Int?) {
        self.modifiedFiles = modifiedFiles
        self.unpushedCommits = unpushedCommits
    }
}

extension Git {
    /// Parses `git worktree list --porcelain`.
    public static func parseWorktrees(_ text: String, clone: String) -> [Worktree] {
        var found: [Worktree] = []
        var path: String?, branch: String?, head: String?
        func flush() {
            if let path { found.append(Worktree(path: path, clone: clone, branch: branch, head: head)) }
            path = nil; branch = nil; head = nil
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("worktree ") { flush(); path = String(line.dropFirst(9)) }
            else if line.hasPrefix("HEAD ") { head = String(line.dropFirst(5)) }
            else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst(7))
                branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : ref
            }
        }
        flush()
        return found
    }

    /// The worktrees Hub made for a clone (the ones under `<clone>-worktrees/`).
    public static func hubWorktrees(of clone: String) -> [Worktree] {
        let folder = clone + "-worktrees/"
        guard FileManager.default.fileExists(atPath: folder) else { return [] }
        guard let out = try? run(["-C", clone, "worktree", "list", "--porcelain"]) else { return [] }
        return parseWorktrees(out, clone: clone).filter { $0.path.hasPrefix(folder) }
    }

    public static func changes(in worktree: String) -> WorktreeChanges {
        let status = (try? run(["-C", worktree, "status", "--porcelain"])) ?? ""
        let modified = status.split(separator: "\n").count
        // Without an upstream, count commits that no remote branch has: work only this folder holds.
        let ahead = ((try? run(["-C", worktree, "rev-list", "--count", "@{u}..HEAD"]))
            ?? (try? run(["-C", worktree, "rev-list", "--count", "HEAD", "--not", "--remotes"])))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return WorktreeChanges(modifiedFiles: modified, unpushedCommits: ahead)
    }

    public static func removeWorktree(_ worktree: Worktree, force: Bool) throws {
        var args = ["-C", worktree.clone, "worktree", "remove"]
        if force { args.append("--force") }
        args.append(worktree.path)
        _ = try run(args)
        _ = try? run(["-C", worktree.clone, "worktree", "prune"])
    }

    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(message: String) { self.message = message }
    }

    /// Runs git and returns its output, or throws with what it printed to stderr.
    @discardableResult
    public static func run(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(message: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: data, as: UTF8.self)
    }
}

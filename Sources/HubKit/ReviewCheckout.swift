import Foundation

/// A throwaway checkout of a pull request's head commit for Claude to review
/// in, so Read, Grep and Glob see the PR's code rather than whatever the
/// clone has checked out. It is a detached worktree of the clone, in Hub's
/// caches; nothing in the clone's own folder changes.
public enum ReviewCheckout {
    /// Where review checkouts live.
    public static var folder: String {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.menico.gh-hub/review-checkouts", isDirectory: true).path
    }

    /// A new folder name for a review of `repo`#`number`.
    public static func newPath(repo: String, number: Int) -> String {
        let name = repo.split(separator: "/").last.map(String.init) ?? "repo"
        return folder + "/\(name)-\(number)-\(UUID().uuidString.prefix(6).lowercased())"
    }

    /// Fetches the pull request's head into the clone (no branch is made or
    /// moved) and checks out `sha`, or the fetched head when `sha` isn't known,
    /// detached at `path`. Never asks for a password: it fails instead.
    public static func add(clone: String, number: Int, sha: String?, at path: String) throws {
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        if env["GIT_SSH_COMMAND"] == nil { env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes" }
        let hasSHA = sha.map { (try? Git.run(["-C", clone, "cat-file", "-e", "\($0)^{commit}"])) != nil } ?? false
        if !hasSHA {
            try Git.run(["-C", clone, "fetch", "--quiet", "--no-tags", "origin", "pull/\(number)/head"], environment: env)
        }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let target = sha.flatMap { s in (try? Git.run(["-C", clone, "cat-file", "-e", "\(s)^{commit}"])) != nil ? s : nil } ?? "FETCH_HEAD"
        try Git.run(["-C", clone, "worktree", "add", "--quiet", "--detach", path, target])
    }

    /// Removes a review checkout; it never holds work of its own.
    public static func remove(_ path: String, clone: String) {
        _ = try? Git.run(["-C", clone, "worktree", "remove", "--force", path])
        try? FileManager.default.removeItem(atPath: path)
        _ = try? Git.run(["-C", clone, "worktree", "prune"])
    }

    /// The clone's review checkouts.
    public static func leftovers(of clone: String) -> [String] {
        guard let out = try? Git.run(["-C", clone, "worktree", "list", "--porcelain"]) else { return [] }
        return Git.parseWorktrees(out, clone: clone).map(\.path).filter { $0.hasPrefix(folder + "/") }
    }
}

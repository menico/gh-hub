import Foundation

// What Hub knows about this Mac: local clones of GitHub repositories, the
// Claude Code sessions that ran in them, and cpx's profiles and bindings.

// MARK: Git

public enum Git {
    /// "owner/repo" from any GitHub remote URL, with its host.
    ///   git@github.com:owner/repo.git, https://github.com/owner/repo,
    ///   ssh://git@github.com/owner/repo.git
    public static func repo(fromRemote url: String) -> (host: String, nameWithOwner: String)? {
        var rest = url.trimmingCharacters(in: .whitespaces)
        var host: String
        if let scheme = rest.range(of: "://") {
            rest = String(rest[scheme.upperBound...])
            if let at = rest.firstIndex(of: "@"), rest[..<at].firstIndex(of: "/") == nil { rest = String(rest[rest.index(after: at)...]) }
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            host = String(rest[..<slash])
            rest = String(rest[rest.index(after: slash)...])
        } else if let at = rest.firstIndex(of: "@"), let colon = rest.firstIndex(of: ":"), at < colon {
            host = String(rest[rest.index(after: at)..<colon])
            rest = String(rest[rest.index(after: colon)...])
        } else {
            return nil
        }
        if let port = host.firstIndex(of: ":") { host = String(host[..<port]) }
        if rest.hasSuffix(".git") { rest = String(rest.dropLast(4)) }
        let parts = rest.split(separator: "/").map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (host, parts.joined(separator: "/"))
    }

    /// The repository a directory belongs to: walks up to the nearest `.git`,
    /// follows a worktree's `.git` file back to the main repository, and reads
    /// its origin remote.
    public static func origin(of directory: String) -> (root: String, nameWithOwner: String)? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: directory).standardizedFileURL
        while dir.path != "/" {
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                guard let gitDir = isDir.boolValue ? dotGit : linkedGitDir(dotGit),
                      let config = try? String(contentsOf: commonDir(gitDir).appendingPathComponent("config"), encoding: .utf8),
                      let url = originURL(inConfig: config),
                      let repo = repo(fromRemote: url)
                else { return nil }
                return (dir.path, repo.nameWithOwner)
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    /// A worktree's `.git` file says "gitdir: <path>".
    static func linkedGitDir(_ file: URL) -> URL? {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return URL(fileURLWithPath: path, relativeTo: file.deletingLastPathComponent()).standardizedFileURL
    }

    /// A linked worktree's git dir points at the shared one through `commondir`.
    static func commonDir(_ gitDir: URL) -> URL {
        guard let text = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8) else { return gitDir }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path, relativeTo: gitDir).standardizedFileURL
    }

    static func originURL(inConfig config: String) -> String? {
        var inOrigin = false
        for raw in config.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line.replacingOccurrences(of: " ", with: "") == "[remote\"origin\"]"
            } else if inOrigin, line.hasPrefix("url") {
                return line.split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }
        return nil
    }

    /// Main clones (not worktrees) under the given folders, by lowercased "owner/repo".
    public static func findClones(in roots: [String], depth: Int = 4) -> [String: [String]] {
        let fm = FileManager.default
        let skip: Set<String> = ["node_modules", "Library", "Pods", "DerivedData", "build", "dist", "target", "vendor", "venv"]
        var found: [String: [String]] = [:]
        var seen = Set<String>()

        func visit(_ dir: URL, _ level: Int) {
            guard seen.insert(dir.resolvingSymlinksInPath().path).inserted else { return }
            var isDir: ObjCBool = false
            let dotGit = dir.appendingPathComponent(".git")
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                if isDir.boolValue,
                   let config = try? String(contentsOf: dotGit.appendingPathComponent("config"), encoding: .utf8),
                   let url = originURL(inConfig: config), let repo = repo(fromRemote: url) {
                    found[repo.nameWithOwner.lowercased(), default: []].append(dir.path)
                }
                return
            }
            guard level < depth,
                  let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            else { return }
            for child in children where !skip.contains(child.lastPathComponent) && !child.lastPathComponent.hasSuffix("-worktrees") {
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { visit(child, level + 1) }
            }
        }
        for root in roots { visit(URL(fileURLWithPath: (root as NSString).expandingTildeInPath), 0) }
        return found
    }
}

// MARK: cpx

/// cpx's profiles (name → config dir, colour) and directory bindings.
public struct CpxConfig: Sendable {
    public struct Profile: Sendable, Hashable {
        public let name: String
        public let dir: String
        public let color: String?
    }

    public var profiles: [Profile] = []
    /// (directory, profile name), longest path first.
    public var bindings: [(path: String, profile: String)] = []

    public static let home = FileManager.default.homeDirectoryForCurrentUser.path

    public init(profiles: [Profile] = [], bindings: [(path: String, profile: String)] = []) {
        self.profiles = profiles
        self.bindings = bindings
    }

    public static func load() -> CpxConfig {
        let base = home + "/.claude-profiles"
        let config = (try? String(contentsOfFile: base + "/config.toml", encoding: .utf8)) ?? ""
        let bindings = (try? String(contentsOfFile: base + "/bindings.toml", encoding: .utf8)) ?? ""
        return parse(config: config, bindings: bindings)
    }

    static func parse(config: String, bindings: String) -> CpxConfig {
        var result = CpxConfig()
        // [profiles.<name>] followed by dir = "…" and color = "…".
        var current: String?
        var fields: [String: [String: String]] = [:]
        var order: [String] = []
        for raw in config.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let name = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                if name.hasPrefix("profiles."), !name.dropFirst("profiles.".count).contains(".") {
                    current = String(name.dropFirst("profiles.".count))
                    if !order.contains(current!) { order.append(current!) }
                } else {
                    current = nil
                }
            } else if let current, let (key, value) = keyValue(line) {
                fields[current, default: [:]][key] = value
            }
        }
        result.profiles = order.compactMap { name in
            let dir = fields[name]?["dir"].map { ($0 as NSString).expandingTildeInPath } ?? home + "/.claude-profiles/\(name)"
            return Profile(name: name, dir: dir, color: fields[name]?["color"])
        }
        // [[bindings]] path = "…" profile = "…" provider = "claude"
        var path: String?, profile: String?, provider: String?
        func flush() {
            if let path, let profile, provider ?? "claude" == "claude" { result.bindings.append((path, profile)) }
            path = nil; profile = nil; provider = nil
        }
        for raw in bindings.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "[[bindings]]" { flush(); continue }
            guard let (key, value) = keyValue(line) else { continue }
            switch key {
            case "path": path = (value as NSString).expandingTildeInPath
            case "profile": profile = value
            case "provider": provider = value
            default: break
            }
        }
        flush()
        result.bindings.sort { $0.path.count > $1.path.count }
        return result
    }

    private static func keyValue(_ line: String) -> (String, String)? {
        guard let eq = line.firstIndex(of: "="), !line.hasPrefix("#") else { return nil }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return (key, value)
    }

    /// The profile bound to a directory or any of its parents.
    public func boundProfile(for directory: String) -> String? {
        bindings.first { directory == $0.path || directory.hasPrefix($0.path + "/") }?.profile
    }

    /// The profile whose config dir this is; nil for the default ~/.claude.
    public func profile(forConfigDir dir: String) -> Profile? {
        let target = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
        return profiles.first { URL(fileURLWithPath: $0.dir).resolvingSymlinksInPath().path == target }
    }

    /// Every Claude config dir that may hold sessions: ~/.claude and each profile's.
    public var configDirs: [String] {
        var dirs = [CpxConfig.home + "/.claude"] + profiles.map(\.dir)
        // Profiles made before cpx, or by hand: ~/.claude-<name>.
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: CpxConfig.home) {
            dirs += entries.filter { $0.hasPrefix(".claude-") && $0 != ".claude-profiles" }.map { CpxConfig.home + "/" + $0 }
        }
        var seen = Set<String>()
        return dirs.filter { seen.insert(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path).inserted }
            .filter { FileManager.default.fileExists(atPath: $0 + "/projects") }
    }
}

// MARK: Claude sessions

public struct ClaudeSession: Identifiable, Hashable, Sendable {
    public let id: String
    public let configDir: String
    public let file: String
    public let cwd: String
    /// Every branch the session was on.
    public let branches: [String]
    /// The first thing asked, trimmed.
    public let prompt: String
    public let startedAt: Date
    public let updatedAt: Date
}

/// Reads Claude Code transcripts, remembering each by modification date so a
/// rescan only opens files that changed.
public final class SessionIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: (modified: Date, session: ClaudeSession?)] = [:]

    public init() {}

    public func scan(configDirs: [String], within days: Double = 60) -> [ClaudeSession] {
        let fm = FileManager.default
        let cutoff = Date.now.addingTimeInterval(-days * 86_400)
        var sessions: [ClaudeSession] = []
        for dir in configDirs {
            let projects = dir + "/projects"
            guard let folders = try? fm.contentsOfDirectory(atPath: projects) else { continue }
            for folder in folders {
                guard let files = try? fm.contentsOfDirectory(atPath: projects + "/" + folder) else { continue }
                for name in files where name.hasSuffix(".jsonl") {
                    let path = projects + "/" + folder + "/" + name
                    guard let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                          modified > cutoff else { continue }
                    let cached = lock.withLock { cache[path] }
                    if let cached, cached.modified == modified {
                        if let session = cached.session { sessions.append(session) }
                        continue
                    }
                    let session = Self.read(path, configDir: dir, modified: modified)
                    lock.withLock { cache[path] = (modified, session) }
                    if let session { sessions.append(session) }
                }
            }
        }
        // A session copied between profiles appears twice; keep the latest copy.
        var seen = Set<String>()
        return sessions.sorted { $0.updatedAt > $1.updatedAt }.filter { seen.insert($0.id).inserted }
    }

    /// Reads the start and the end of a transcript: enough for where it ran,
    /// on which branches, and what it was asked first.
    static func read(_ path: String, configDir: String, modified: Date) -> ClaudeSession? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        var tail = Data()
        if let size = try? handle.seekToEnd(), size > 256 * 1024 {
            try? handle.seek(toOffset: size - 96 * 1024)
            tail = (try? handle.readToEnd()) ?? Data()
        }
        return parse(head: head, tail: tail, path: path, configDir: configDir, modified: modified)
    }

    static func parse(head: Data, tail: Data, path: String, configDir: String, modified: Date) -> ClaudeSession? {
        var id: String?, cwd: String?, prompt: String?, summary: String?, started: Date?
        var branches: [String] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for chunk in [head, tail] {
            for line in chunk.split(separator: UInt8(ascii: "\n")) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                // Claude Code titles a session with a "summary" line.
                if object["type"] as? String == "summary", let text = object["summary"] as? String, !text.isEmpty { summary = text }
                if id == nil { id = object["sessionId"] as? String }
                if cwd == nil { cwd = object["cwd"] as? String }
                if let branch = object["gitBranch"] as? String, !branch.isEmpty, branch != "HEAD", !branches.contains(branch) {
                    branches.append(branch)
                }
                if started == nil, let stamp = object["timestamp"] as? String { started = iso.date(from: stamp) }
                if prompt == nil, object["type"] as? String == "user", object["isMeta"] as? Bool != true,
                   let message = object["message"] as? [String: Any] {
                    prompt = firstText(message["content"])
                }
            }
        }
        guard let id, let cwd else { return nil }
        return ClaudeSession(
            id: id, configDir: configDir, file: path, cwd: cwd, branches: branches,
            prompt: summary ?? prompt ?? "", startedAt: started ?? modified, updatedAt: modified)
    }

    /// The human text of a user message, skipping command wrappers and tool results.
    static func firstText(_ content: Any?) -> String? {
        var text: String?
        if let string = content as? String {
            text = string
        } else if let parts = content as? [[String: Any]] {
            text = parts.first { $0["type"] as? String == "text" }?["text"] as? String
        }
        guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix("<") || text.hasPrefix("Caveat:") || text.hasPrefix("[Request interrupted") { return nil }
        text = text.replacingOccurrences(of: "\n", with: " ")
        return String(text.prefix(240))
    }
}

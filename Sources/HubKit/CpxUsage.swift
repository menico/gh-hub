import Foundation

/// How much of each Claude account's rate limits is used, as cpx's menu-bar
/// app last saw it (`~/.claude-profiles/cache/usage.json`). The parser also
/// reads `cpx --json usage` output, which has the same shape.
public struct CpxUsage: Sendable, Equatable {
    public struct Window: Sendable, Equatable, Decodable {
        public var id: String
        public var title: String
        public var usedPercent: Double
        public var resetsAtEpoch: Int?
        public var resetDate: Date? { resetsAtEpoch.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    }

    public struct Account: Sendable, Equatable {
        /// The profile name, or nil for the plain `~/.claude` session.
        public var profile: String?
        public var windows: [Window]
        /// cpx's error kind ("tokenExpired", "notSignedIn", …) when the last fetch failed.
        public var error: String?
        public var command: String?
        public var fetchedAt: Date?

        public var session: Window? { windows.first { $0.id == "session" } }
        public var weekly: Window? { windows.first { $0.id == "weekly" } }
        /// The fuller of the 5-hour and weekly windows: what runs out first.
        public var tightest: Window? { [session, weekly].compactMap { $0 }.max { $0.usedPercent < $1.usedPercent } }
        public var isLoginProblem: Bool {
            ["notSignedIn", "tokenExpired", "keychainDenied", "keychainNeedsPermission", "unauthorized"].contains(error ?? "")
        }
    }

    public var accounts: [Account]
    /// When cpx wrote the snapshot (nil for plain command output).
    public var writtenAt: Date?

    public init(accounts: [Account] = [], writtenAt: Date? = nil) {
        self.accounts = accounts
        self.writtenAt = writtenAt
    }

    public static var snapshotFile: String { CpxConfig.home + "/.claude-profiles/cache/usage.json" }

    /// HUB_CPX_USAGE points Hub at another file, for development.
    public static func loadSnapshot(path: String = ProcessInfo.processInfo.environment["HUB_CPX_USAGE"] ?? snapshotFile) -> CpxUsage? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return parse(data)
    }

    /// Reads the snapshot file or `cpx --json usage` output; Claude accounts only.
    public static func parse(_ data: Data) -> CpxUsage? {
        struct Raw: Decodable {
            struct Snapshot: Decodable { var windows: [Window]?; var fetchedAt: Int? }
            struct RawError: Decodable { var kind: String }
            struct RawAccount: Decodable {
                var profile: String?
                var provider: String
                var command: String?
                var usage: Snapshot?
                var error: RawError?
            }
            var writtenAt: String?
            var accounts: [RawAccount]
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        let accounts = raw.accounts.filter { $0.provider == "claude" }.map { a in
            Account(profile: a.profile, windows: a.usage?.windows ?? [], error: a.error?.kind, command: a.command,
                    fetchedAt: a.usage?.fetchedAt.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil })
        }
        return CpxUsage(accounts: accounts, writtenAt: raw.writtenAt.flatMap { ISO8601DateFormatter().date(from: $0) })
    }

    /// The account for a profile; nil profile means plain `claude`.
    public func account(_ profile: String?) -> Account? {
        accounts.first { $0.profile == profile }
    }

    /// When a profile is close enough to a limit that a review could hit it:
    /// the 5-hour window at 80% or the weekly one at 90%.
    public static func isNearLimit(_ account: Account) -> Bool {
        (account.session?.usedPercent ?? 0) >= 80 || (account.weekly?.usedPercent ?? 0) >= 90
    }

    /// The signed-in profile with the most room left, other than `excluding`.
    public func roomiest(among profiles: [String?], excluding: String?) -> Account? {
        profiles.filter { $0 != excluding }
            .compactMap { account($0) }
            .filter { $0.error == nil && $0.tightest != nil && !Self.isNearLimit($0) }
            .min { ($0.tightest?.usedPercent ?? 100) < ($1.tightest?.usedPercent ?? 100) }
    }
}

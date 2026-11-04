import Foundation

/// The perspective a Claude review takes: what it looks for, and what it
/// leaves alone. Hub ships a few; you can add your own in Settings.
public struct ReviewPersona: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var symbol: String
    /// What the reviewer looks for, in the second person ("Judge the change…").
    public var lens: String

    public init(id: String = UUID().uuidString, name: String, symbol: String = "person.crop.circle", lens: String) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.lens = lens
    }

    public var isBuiltIn: Bool { Self.builtIn.contains { $0.id == id } }

    public static let general = ReviewPersona(
        id: "general", name: "General", symbol: "sparkles",
        lens: """
        Review the diff for correctness bugs, security problems, data loss, race conditions, broken error handling, \
        missing tests for risky logic, and API or behaviour changes the description doesn't mention. Skip style nits \
        and anything a formatter or linter would catch.
        """)

    public static let architect = ReviewPersona(
        id: "architect", name: "Architect", symbol: "building.columns",
        lens: """
        Review as a software architect: judge the change at the level of design, not individual lines. \
        Does each responsibility sit in the right module, layer or service, or does the change blur a boundary, add coupling, \
        or leak an abstraction? Does it duplicate something the codebase already has, or go against the patterns it already uses? \
        Look hard at interfaces and contracts (public APIs, data models, schemas, events, configuration): are they coherent, \
        backwards compatible, and easy to change later? Consider data ownership and flow, failure between components, \
        consistency, migrations and rollback, scalability, and how it will be operated (logging, metrics, configuration, deployment). \
        Ask whether this approach fits the problem; if a simpler or better-fitting design exists, say what it is and why. \
        Read the surrounding code to judge this rather than guessing. Leave line-level bugs and style alone unless they \
        point at a design problem. Put design concerns that span files in risks; anchor a comment on the line where a \
        design decision is made when there is one.
        """)

    public static let security = ReviewPersona(
        id: "security", name: "Security", symbol: "lock.shield",
        lens: """
        Review as an application security engineer. Look for broken authentication or authorization, missing input \
        validation, injection (SQL, shell, template, path), SSRF, unsafe deserialization, secrets or tokens in code, logs or \
        config, sensitive data exposed in responses or logs, weak crypto, insecure defaults, overly broad permissions \
        (cloud IAM, CI tokens, GitHub Actions triggers such as pull_request_target), and risky new dependencies. \
        Explain how each issue could be exploited and how to fix it. Ignore anything that isn't security.
        """)

    public static let performance = ReviewPersona(
        id: "performance", name: "Performance & reliability", symbol: "gauge.with.dots.needle.67percent",
        lens: """
        Review for performance and reliability. Look for work on hot paths that grows with data (N+1 queries, \
        loops over network or disk calls, missing pagination or indexes), blocking calls where async is expected, \
        unbounded memory or queues, resource leaks, missing timeouts, retries without backoff, races and deadlocks, \
        cache invalidation mistakes, and behaviour under partial failure or load. Say what it costs and when it bites. \
        Ignore style and anything that doesn't affect speed or uptime.
        """)

    public static let builtIn: [ReviewPersona] = [general, architect, security, performance]

    // MARK: Saved

    private static let customKey = "reviewPersonas"
    public static let selectedKey = "reviewPersona"

    /// Your own personas, after the built-in ones.
    public static func custom(_ defaults: UserDefaults = .standard) -> [ReviewPersona] {
        guard let data = defaults.data(forKey: customKey) else { return [] }
        return (try? JSONDecoder().decode([ReviewPersona].self, from: data)) ?? []
    }

    public static func saveCustom(_ personas: [ReviewPersona], _ defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(personas), forKey: customKey)
    }

    public static func all(_ defaults: UserDefaults = .standard) -> [ReviewPersona] {
        builtIn + custom(defaults)
    }

    /// The persona with this id, or General when it is gone.
    public static func named(_ id: String?, _ defaults: UserDefaults = .standard) -> ReviewPersona {
        all(defaults).first { $0.id == id } ?? general
    }
}

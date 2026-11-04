import Foundation

/// Remembers each GET's ETag and body, so an unchanged answer comes back as
/// `304 Not Modified`, which GitHub does not count against the rate limit.
/// Also keeps the rate-limit headers and a tally of how often that worked.
public final class ResponseCache: @unchecked Sendable {
    public struct Rate: Sendable, Hashable {
        public var remaining: Int
        public var limit: Int
        public var reset: Date
    }

    public struct Stats: Sendable, Hashable {
        /// Rate limit per resource: "core" for REST, "graphql" for GraphQL.
        public var rates: [String: Rate] = [:]
        public var requests = 0
        public var notModified = 0
    }

    private let lock = NSLock()
    private var entries: [String: (etag: String, data: Data)] = [:]
    private var stats = Stats()
    private let capacity = 600

    public init() {}

    public var snapshot: Stats { lock.withLock { stats } }

    func etag(for key: String) -> String? { lock.withLock { entries[key]?.etag } }

    func cached(_ key: String) -> Data? { lock.withLock { entries[key]?.data } }

    func store(_ key: String, etag: String, data: Data) {
        lock.withLock {
            if entries.count >= capacity, entries[key] == nil, let victim = entries.keys.randomElement() {
                entries.removeValue(forKey: victim)
            }
            entries[key] = (etag, data)
        }
    }

    func record(_ response: HTTPURLResponse?, notModified: Bool) {
        lock.withLock {
            stats.requests += 1
            if notModified { stats.notModified += 1 }
            guard let response,
                  let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init),
                  let limit = response.value(forHTTPHeaderField: "X-RateLimit-Limit").flatMap(Int.init)
            else { return }
            let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
                .map(Date.init(timeIntervalSince1970:)) ?? .now
            let resource = response.value(forHTTPHeaderField: "X-RateLimit-Resource") ?? "core"
            stats.rates[resource] = Rate(remaining: remaining, limit: limit, reset: reset)
        }
    }
}

import Foundation

public enum GitHubError: LocalizedError {
    case http(Int, String)
    case graphQL(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code, let message): message.isEmpty ? "GitHub answered \(code)." : "\(message) (\(code))"
        case .graphQL(let message): message
        }
    }
}

/// One signed-in account's view of the GitHub API.
public struct GitHubClient: Sendable {
    public let account: Account
    private let token: String
    private let restBase: String
    private let graphQLURL: URL
    /// Shared by every copy of this client: ETags, rate limits, tallies.
    public let cache = ResponseCache()
    var graphQLURLString: String { graphQLURL.absoluteString }

    public init(account: Account, token: String) {
        self.account = account
        self.token = token
        if account.host == "github.com" {
            restBase = "https://api.github.com"
            graphQLURL = URL(string: "https://api.github.com/graphql")!
        } else {
            restBase = "https://\(account.host)/api/v3"
            graphQLURL = URL(string: "https://\(account.host)/api/graphql")!
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    @discardableResult
    public func send(
        _ method: String, _ path: String, json: [String: Any]? = nil,
        accept: String = "application/vnd.github+json"
    ) async throws -> Data {
        guard let url = URL(string: path.hasPrefix("http") ? path : restBase + path) else {
            throw GitHubError.http(0, "Bad path \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        // Plain GETs are asked conditionally; "nothing changed" costs no rate limit.
        let key = method == "GET" && json == nil ? url.absoluteString + "|" + accept : nil
        if let key, let etag = cache.etag(for: key) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        if code == 304, let key, let cached = cache.cached(key) {
            cache.record(http, notModified: true)
            return cached
        }
        cache.record(http, notModified: false)
        guard (200..<300).contains(code) else { throw GitHubError.http(code, Self.message(in: data)) }
        if let key, let etag = http?.value(forHTTPHeaderField: "ETag") {
            cache.store(key, etag: etag, data: data)
        }
        return data
    }

    public func get<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
        try Self.decoder.decode(T.self, from: try await send("GET", path))
    }

    public func graphQL<T: Decodable>(_ query: String, variables: [String: Any] = [:], as type: T.Type = T.self) async throws -> T {
        let raw = try await send("POST", graphQLURL.absoluteString, json: ["query": query, "variables": variables])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(GraphQLEnvelope<T>.self, from: raw)
        if let data = envelope.data { return data }
        throw GitHubError.graphQL(envelope.errors?.map(\.message).joined(separator: "\n") ?? "Empty GraphQL answer.")
    }

    struct GraphQLEnvelope<T: Decodable>: Decodable {
        struct Problem: Decodable { var message: String }
        var data: T?
        var errors: [Problem]?
    }

    static func message(in data: Data) -> String {
        struct Body: Decodable { var message: String? }
        if let body = try? JSONDecoder().decode(Body.self, from: data), let message = body.message { return message }
        let text = String(decoding: data.prefix(2000), as: UTF8.self)
        // Gateway errors come back as an HTML page; its title is the useful part.
        if text.range(of: "<html", options: .caseInsensitive) != nil {
            if let open = text.range(of: "<title>", options: .caseInsensitive),
               let close = text.range(of: "</title>", options: .caseInsensitive, range: open.upperBound..<text.endIndex) {
                return "GitHub: " + text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return "GitHub returned an error page"
        }
        return String(text.prefix(300))
    }
}

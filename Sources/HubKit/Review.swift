import Foundation

// MARK: Models

/// Which side of the diff a comment sits on: the new file (RIGHT) or the old one (LEFT).
public enum DiffSide: String, Sendable, Codable, Hashable {
    case left = "LEFT", right = "RIGHT"
}

public struct ReviewComment: Identifiable, Hashable, Sendable {
    public let id: String
    public let databaseID: Int?
    public let author: String
    public let authorAvatar: URL?
    public let body: String
    public let createdAt: Date
    public let url: URL?
}

/// A conversation pinned to a line of the diff.
public struct ReviewThread: Identifiable, Hashable, Sendable {
    public let id: String
    public let path: String
    /// The line in the current diff, or nil once the code moved on (outdated).
    public let line: Int?
    public let originalLine: Int?
    public let side: DiffSide
    public let isResolved: Bool
    public let isOutdated: Bool
    public let comments: [ReviewComment]
    /// The code the thread started on, as GitHub shows it above the first comment.
    public var diffHunk: String? = nil

    /// Someone other than `login` wrote last, in a thread `login` is part of: your turn.
    public func waitsOn(_ login: String) -> Bool {
        let me = login.lowercased()
        guard !isResolved, let last = comments.last, last.author.lowercased() != me else { return false }
        return comments.contains { $0.author.lowercased() == me }
    }
}

/// A comment written in Hub that goes out with the next review.
public struct DraftComment: Identifiable, Hashable, Sendable, Codable {
    public var id = UUID()
    public var path: String
    public var line: Int
    public var side: DiffSide
    public var body: String
    /// Suggested by Claude rather than typed.
    public var fromClaude = false

    public init(path: String, line: Int, side: DiffSide, body: String, fromClaude: Bool = false) {
        self.path = path
        self.line = line
        self.side = side
        self.body = body
        self.fromClaude = fromClaude
    }
}

/// One entry of a pull request's conversation: a comment or a submitted review.
public struct TimelineEntry: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case comment, review(String) }
    public let id: String
    public let kind: Kind
    public let author: String
    public let authorAvatar: URL?
    public let body: String
    public let date: Date
    /// For a review: the line comments that went out with it.
    public var lineComments: [LineNote] = []

    public struct LineNote: Hashable, Sendable {
        public let path: String
        public let line: Int?
        public let body: String
    }
}

/// Everything about a pull request beyond the dashboard row: threads,
/// conversation, merge state and who could review it.
public struct PRConversation: Sendable {
    public var headSHA: String
    public var mergeState: String
    public var canEnableAutoMerge: Bool
    public var canDisableAutoMerge: Bool
    public var canUpdateBranch: Bool
    public var autoMergeMethod: String?
    public var requestedReviewers: [String]
    public var suggestedReviewers: [Person]
    public var threads: [ReviewThread]
    public var timeline: [TimelineEntry]
}

// MARK: GitHub

extension GitHubClient {
    static let conversationQuery = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          headRefOid mergeStateStatus viewerCanEnableAutoMerge viewerCanDisableAutoMerge viewerCanUpdateBranch
          autoMergeRequest { mergeMethod }
          suggestedReviewers { reviewer { login avatarUrl } }
          reviewRequests(first: 20) { nodes { requestedReviewer { ... on User { login } ... on Team { name } } } }
          reviewThreads(first: 100) {
            nodes {
              id isResolved isOutdated path line originalLine diffSide
              comments(first: 50) { nodes { id databaseId body createdAt url diffHunk author { login avatarUrl } } }
            }
          }
          comments(last: 60) { nodes { id body createdAt author { login avatarUrl } } }
          reviews(last: 40) { nodes { id state body submittedAt author { login avatarUrl }
                                      comments(first: 30) { nodes { path line originalLine body } } } }
        }
      }
    }
    """

    public func conversation(of pr: PullRequest) async throws -> PRConversation {
        struct Login: Decodable { var login: String; var avatarUrl: URL? }
        struct RawComment: Decodable {
            var id: String; var databaseId: Int?; var body: String; var createdAt: Date; var url: URL?; var author: Login?
            var diffHunk: String?
        }
        struct RawThread: Decodable {
            var id: String; var isResolved: Bool; var isOutdated: Bool; var path: String
            var line: Int?; var originalLine: Int?; var diffSide: String?
            var comments: Nodes<RawComment>
        }
        struct RawReview: Decodable {
            var id: String; var state: String; var body: String; var submittedAt: Date?; var author: Login?
            struct Note: Decodable { var path: String; var line: Int?; var originalLine: Int?; var body: String }
            var comments: Nodes<Note>?
        }
        struct Reviewer: Decodable { var login: String?; var name: String? }
        struct Request: Decodable { var requestedReviewer: Reviewer? }
        struct Suggested: Decodable { var reviewer: Login }
        struct PR: Decodable {
            var headRefOid: String
            var mergeStateStatus: String?
            var viewerCanEnableAutoMerge: Bool?
            var viewerCanDisableAutoMerge: Bool?
            var viewerCanUpdateBranch: Bool?
            var autoMergeRequest: [String: String?]?
            var suggestedReviewers: [Suggested]?
            var reviewRequests: Nodes<Request>
            var reviewThreads: Nodes<RawThread>
            var comments: Nodes<RawComment>
            var reviews: Nodes<RawReview>
        }
        struct Answer: Decodable {
            struct Repository: Decodable { var pullRequest: PR? }
            var repository: Repository?
        }
        let parts = pr.repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw GitHubError.graphQL("Bad repository name \(pr.repo)") }
        let answer: Answer = try await graphQL(Self.conversationQuery, variables: ["owner": parts[0], "name": parts[1], "number": pr.number])
        guard let raw = answer.repository?.pullRequest else { throw GitHubError.graphQL("Pull request not found.") }

        func comment(_ c: RawComment) -> ReviewComment {
            ReviewComment(id: c.id, databaseID: c.databaseId, author: c.author?.login ?? "ghost", authorAvatar: c.author?.avatarUrl,
                          body: c.body, createdAt: c.createdAt, url: c.url)
        }
        var timeline = raw.comments.nodes.map {
            TimelineEntry(id: $0.id, kind: .comment, author: $0.author?.login ?? "ghost", authorAvatar: $0.author?.avatarUrl,
                          body: $0.body, date: $0.createdAt)
        }
        // Every submitted review with something in it: a body, a verdict, or line comments.
        timeline += raw.reviews.nodes.filter {
            $0.state != "PENDING" && !($0.state == "COMMENTED" && $0.body.isEmpty && ($0.comments?.nodes.isEmpty ?? true))
        }.map {
            var entry = TimelineEntry(id: $0.id, kind: .review($0.state), author: $0.author?.login ?? "ghost", authorAvatar: $0.author?.avatarUrl,
                                      body: $0.body, date: $0.submittedAt ?? .distantPast)
            entry.lineComments = ($0.comments?.nodes ?? []).map { TimelineEntry.LineNote(path: $0.path, line: $0.line ?? $0.originalLine, body: $0.body) }
            return entry
        }
        return PRConversation(
            headSHA: raw.headRefOid,
            mergeState: raw.mergeStateStatus ?? "UNKNOWN",
            canEnableAutoMerge: raw.viewerCanEnableAutoMerge ?? false,
            canDisableAutoMerge: raw.viewerCanDisableAutoMerge ?? false,
            canUpdateBranch: raw.viewerCanUpdateBranch ?? false,
            autoMergeMethod: raw.autoMergeRequest.flatMap { $0["mergeMethod"] ?? nil },
            requestedReviewers: raw.reviewRequests.nodes.compactMap { $0.requestedReviewer.flatMap { $0.login ?? $0.name } },
            suggestedReviewers: (raw.suggestedReviewers ?? []).map { Person(login: $0.reviewer.login, avatar: $0.reviewer.avatarUrl) },
            threads: raw.reviewThreads.nodes.map {
                ReviewThread(id: $0.id, path: $0.path, line: $0.line, originalLine: $0.originalLine,
                             side: DiffSide(rawValue: $0.diffSide ?? "RIGHT") ?? .right,
                             isResolved: $0.isResolved, isOutdated: $0.isOutdated, comments: $0.comments.nodes.map(comment),
                             diffHunk: $0.comments.nodes.first?.diffHunk)
            },
            timeline: timeline.sorted { $0.date < $1.date })
    }

    /// Submits a review, with any line comments written for it.
    public func submitReview(_ pr: PullRequest, event: ReviewEvent, body: String, comments: [DraftComment], commit: String?) async throws {
        var json: [String: Any] = ["event": event.rawValue]
        if !body.isEmpty { json["body"] = body }
        if let commit { json["commit_id"] = commit }
        if !comments.isEmpty {
            json["comments"] = comments.map { ["path": $0.path, "line": $0.line, "side": $0.side.rawValue, "body": $0.body] as [String: Any] }
        }
        try await send("POST", "/repos/\(pr.repo)/pulls/\(pr.number)/reviews", json: json)
    }

    /// One line comment, published at once.
    public func comment(on pr: PullRequest, _ draft: DraftComment, commit: String) async throws {
        try await send("POST", "/repos/\(pr.repo)/pulls/\(pr.number)/comments", json: [
            "body": draft.body, "commit_id": commit, "path": draft.path, "line": draft.line, "side": draft.side.rawValue,
        ])
    }

    public func reply(on pr: PullRequest, to comment: Int, body: String) async throws {
        try await send("POST", "/repos/\(pr.repo)/pulls/\(pr.number)/comments/\(comment)/replies", json: ["body": body])
    }

    /// A comment on the pull request's conversation.
    public func comment(onConversationOf pr: PullRequest, body: String) async throws {
        try await send("POST", "/repos/\(pr.repo)/issues/\(pr.number)/comments", json: ["body": body])
    }

    public func setResolved(thread: String, _ resolved: Bool) async throws {
        struct Answer: Decodable {}
        let mutation = resolved ? "resolveReviewThread" : "unresolveReviewThread"
        let _: Answer = try await graphQL("mutation($id: ID!) { \(mutation)(input: {threadId: $id}) { clientMutationId } }",
                                          variables: ["id": thread])
    }

    // MARK: Pull request state

    public func setAutoMerge(_ pr: PullRequest, method: MergeMethod?) async throws {
        struct Answer: Decodable {}
        if let method {
            let _: Answer = try await graphQL(
                "mutation($id: ID!, $method: PullRequestMergeMethod!) { enablePullRequestAutoMerge(input: {pullRequestId: $id, mergeMethod: $method}) { clientMutationId } }",
                variables: ["id": pr.nodeID, "method": method.rawValue.uppercased()])
        } else {
            let _: Answer = try await graphQL(
                "mutation($id: ID!) { disablePullRequestAutoMerge(input: {pullRequestId: $id}) { clientMutationId } }",
                variables: ["id": pr.nodeID])
        }
    }

    public func setDraft(_ pr: PullRequest, _ draft: Bool) async throws {
        struct Answer: Decodable {}
        let mutation = draft ? "convertPullRequestToDraft" : "markPullRequestReadyForReview"
        let _: Answer = try await graphQL("mutation($id: ID!) { \(mutation)(input: {pullRequestId: $id}) { clientMutationId } }",
                                          variables: ["id": pr.nodeID])
    }

    /// Merges the base branch into the pull request's branch.
    public func updateBranch(_ pr: PullRequest) async throws {
        try await send("PUT", "/repos/\(pr.repo)/pulls/\(pr.number)/update-branch", json: [:])
    }

    public func requestReviewers(_ pr: PullRequest, logins: [String]) async throws {
        try await send("POST", "/repos/\(pr.repo)/pulls/\(pr.number)/requested_reviewers", json: ["reviewers": logins])
    }

    // MARK: Single items, for links

    public func pullRequest(repo: String, number: Int, lane: PullRequest.Lane) async throws -> PullRequest {
        struct Answer: Decodable {
            struct Repository: Decodable { var pullRequest: RawPR? }
            var repository: Repository?
        }
        let parts = repo.split(separator: "/").map(String.init)
        let fragment = Self.dashboardQuery[Self.dashboardQuery.range(of: "fragment pr on")!.lowerBound...]
        let query = "query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { ...pr } } }\n" + fragment
        let answer: Answer = try await graphQL(query, variables: ["owner": parts.first ?? "", "name": parts.last ?? "", "number": number])
        guard let pr = answer.repository?.pullRequest?.pullRequest(lane: lane, accountID: account.id) else {
            throw GitHubError.graphQL("\(repo)#\(number) is not a pull request this account can see.")
        }
        return pr
    }

    public func issue(repo: String, number: Int) async throws -> Issue {
        struct Answer: Decodable {
            struct Repository: Decodable { var issue: RawIssue? }
            var repository: Repository?
        }
        let parts = repo.split(separator: "/").map(String.init)
        let start = Self.dashboardQuery.range(of: "fragment ref on")!.lowerBound
        let end = Self.dashboardQuery.range(of: "fragment pr on")!.lowerBound
        let query = "query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { issue(number: $number) { ...issue } } }\n"
            + Self.dashboardQuery[start..<end]
        let answer: Answer = try await graphQL(query, variables: ["owner": parts.first ?? "", "name": parts.last ?? "", "number": number])
        guard let issue = answer.repository?.issue?.issue(lane: .created, accountID: account.id) else {
            throw GitHubError.graphQL("\(repo)#\(number) is not an issue this account can see.")
        }
        return issue
    }

    /// Open, merged or closed, for the pull requests behind a set of worktrees.
    public func pullRequestStates(repo: String, numbers: [Int], branches: [String]) async throws -> (byNumber: [Int: String], byBranch: [String: String]) {
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2, !(numbers.isEmpty && branches.isEmpty) else { return ([:], [:]) }
        var fields: [String] = []
        for (i, n) in numbers.prefix(30).enumerated() { fields.append("n\(i): pullRequest(number: \(n)) { number state }") }
        for (i, b) in branches.prefix(30).enumerated() {
            let quoted = b.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            fields.append("b\(i): pullRequests(headRefName: \"\(quoted)\", first: 1, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { number state } }")
        }
        let query = "query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { \(fields.joined(separator: " ")) } }"
        let data = try await send("POST", graphQLURLString, json: ["query": query, "variables": ["owner": parts[0], "name": parts[1]]])
        let object = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [String: Any]
        let repository = object?["repository"] as? [String: Any] ?? [:]
        var byNumber: [Int: String] = [:], byBranch: [String: String] = [:]
        for (i, n) in numbers.prefix(30).enumerated() {
            if let state = (repository["n\(i)"] as? [String: Any])?["state"] as? String { byNumber[n] = state }
        }
        for (i, b) in branches.prefix(30).enumerated() {
            if let node = ((repository["b\(i)"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first, let state = node["state"] as? String {
                byBranch[b] = state
            }
        }
        return (byNumber, byBranch)
    }
}

// MARK: Links

/// What a github.com link points at.
public enum GitHubLink: Equatable, Sendable {
    case pullRequest(repo: String, number: Int)
    case issue(repo: String, number: Int)
    case run(repo: String, id: Int)
    case repository(String)

    public static func parse(_ text: String) -> GitHubLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host, host.contains("github"),
              !host.hasPrefix("api.") else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let repo = "\(parts[0])/\(parts[1])"
        if parts.count >= 4 {
            switch parts[2] {
            case "pull": if let n = Int(parts[3]) { return .pullRequest(repo: repo, number: n) }
            case "issues": if let n = Int(parts[3]) { return .issue(repo: repo, number: n) }
            case "actions": if parts.count >= 5, parts[3] == "runs", let id = Int(parts[4]) { return .run(repo: repo, id: id) }
            default: break
            }
        }
        return .repository(repo)
    }
}

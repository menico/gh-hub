import Foundation

/// One thread in an account's GitHub notifications inbox: a mention, a
/// reply, a review request, a release, CI on your branch…
public struct GHNotification: Identifiable, Hashable, Sendable {
    /// GitHub's thread id; only unique within one account.
    public let threadID: String
    public let accountID: String
    public var unread: Bool
    /// mention, review_requested, comment, author, assign, ci_activity, …
    public let reason: String
    public let updatedAt: Date
    public let title: String
    /// PullRequest, Issue, Release, Discussion, CheckSuite, Commit, …
    public let type: String
    public let repo: String
    public let repoURL: URL?
    public let subjectURL: URL?

    public var id: String { "\(accountID)|\(threadID)" }

    public init(threadID: String, accountID: String, unread: Bool, reason: String, updatedAt: Date, title: String,
                type: String, repo: String, repoURL: URL?, subjectURL: URL?) {
        self.threadID = threadID
        self.accountID = accountID
        self.unread = unread
        self.reason = reason
        self.updatedAt = updatedAt
        self.title = title
        self.type = type
        self.repo = repo
        self.repoURL = repoURL
        self.subjectURL = subjectURL
    }

    /// The pull request or issue number, read from the subject's API address.
    public var number: Int? {
        guard let parts = subjectURL?.pathComponents, parts.count >= 2,
              ["pulls", "issues"].contains(parts[parts.count - 2]) else { return nil }
        return Int(parts[parts.count - 1])
    }

    public var isPullRequest: Bool { type == "PullRequest" && number != nil }
    public var isIssue: Bool { type == "Issue" && number != nil }

    /// Where it lives on the website. The API gives API addresses, so this
    /// rebuilds the page address; anything it can't map goes to the repository.
    public var webURL: URL? {
        guard let repoURL else { return nil }
        if let number {
            return repoURL.appending(path: isPullRequest ? "pull" : "issues").appending(path: String(number))
        }
        let parts = subjectURL?.pathComponents ?? []
        switch type {
        case "Commit":
            if let sha = parts.last, parts.dropLast().last == "commits" { return repoURL.appending(path: "commit").appending(path: sha) }
        case "Release":
            return repoURL.appending(path: "releases")
        case "Discussion":
            if let n = parts.last, parts.dropLast().last == "discussions" { return repoURL.appending(path: "discussions").appending(path: n) }
            return repoURL.appending(path: "discussions")
        case "CheckSuite":
            return repoURL.appending(path: "actions")
        default:
            break
        }
        return repoURL
    }

    /// Why GitHub told you, in words.
    public var reasonLabel: String {
        switch reason {
        case "mention": "Mentioned"
        case "team_mention": "Team mentioned"
        case "review_requested": "Review requested"
        case "comment": "Comment"
        case "author": "Your thread"
        case "assign": "Assigned"
        case "state_change": "State changed"
        case "ci_activity": "CI"
        case "subscribed": "Watching"
        case "manual": "Subscribed"
        case "approval_requested": "Approval requested"
        case "security_alert": "Security alert"
        case "invitation": "Invitation"
        case "member_feature_requested": "Feature request"
        default: reason.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Worth a banner: talk aimed at you. Review requests, assignments and
    /// CI have banners of their own; watched repositories are just noise.
    public var deservesBanner: Bool {
        unread && !["review_requested", "assign", "ci_activity", "subscribed"].contains(reason)
    }
}

extension GitHubClient {
    struct RawNotification: Decodable {
        struct Subject: Decodable { var title: String; var url: URL?; var type: String }
        struct Repository: Decodable { var fullName: String; var htmlUrl: URL? }
        var id: String
        var unread: Bool
        var reason: String
        var updatedAt: Date
        var subject: Subject
        var repository: Repository
    }

    /// Unread notifications (or every recent one with `all`), newest first.
    public func notifications(all: Bool = false) async throws -> [GHNotification] {
        let raw: [RawNotification] = try await get("/notifications?per_page=50&all=\(all)")
        let accountID = account.id
        return raw.map {
            GHNotification(threadID: $0.id, accountID: accountID, unread: $0.unread, reason: $0.reason, updatedAt: $0.updatedAt,
                           title: $0.subject.title, type: $0.subject.type, repo: $0.repository.fullName,
                           repoURL: $0.repository.htmlUrl, subjectURL: $0.subject.url)
        }
    }

    public func markRead(_ notification: GHNotification) async throws {
        try await send("PATCH", "/notifications/threads/\(notification.threadID)")
    }

    /// Done: out of the inbox on github.com too, until something new happens.
    public func markDone(_ notification: GHNotification) async throws {
        try await send("DELETE", "/notifications/threads/\(notification.threadID)")
    }

    /// Everything up to now, read.
    public func markAllNotificationsRead() async throws {
        try await send("PUT", "/notifications", json: ["last_read_at": ISO8601DateFormatter().string(from: .now), "read": true])
    }
}

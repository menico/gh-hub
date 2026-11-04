import Foundation

public struct Account: Identifiable, Hashable, Sendable, Codable {
    public let login: String
    public let host: String
    public var id: String { "\(host)/\(login)" }

    public init(login: String, host: String) {
        self.login = login
        self.host = host
    }
}

public enum ReviewDecision: String, Sendable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"
}

public enum Mergeable: String, Sendable {
    case mergeable = "MERGEABLE"
    case conflicting = "CONFLICTING"
    case unknown = "UNKNOWN"
}

public enum CheckState: String, Sendable {
    case success = "SUCCESS"
    case failure = "FAILURE"
    case error = "ERROR"
    case pending = "PENDING"
    case expected = "EXPECTED"

    public var isFailing: Bool { self == .failure || self == .error }
    public var isPending: Bool { self == .pending || self == .expected }
}

public struct PullRequest: Identifiable, Hashable, Sendable {
    public enum Lane: String, Sendable { case reviewRequested, mine }

    public let nodeID: String
    public let number: Int
    public let title: String
    public let body: String
    public let url: URL
    public let repo: String
    public let author: String
    public let authorAvatar: URL?
    public let isDraft: Bool
    public let createdAt: Date
    public let updatedAt: Date
    public let additions: Int
    public let deletions: Int
    public let changedFiles: Int
    public let reviewDecision: ReviewDecision?
    public let mergeable: Mergeable
    public let checks: CheckState?
    public let headRef: String
    public let baseRef: String
    public let lane: Lane
    /// The account that saw this pull request, and acts on it.
    public let accountID: String
    /// Issues this pull request closes when merged.
    public let linkedIssues: [LinkedItem]
    /// Your own latest review on it, if you have reviewed it.
    public var myReview: MyReview? = nil

    public var id: String { nodeID }

    public enum MyReview: String, Sendable {
        case approved = "APPROVED"
        case changesRequested = "CHANGES_REQUESTED"
        case commented = "COMMENTED"
        case dismissed = "DISMISSED"
    }
}

/// One end of a pull request ↔ issue relation.
public struct LinkedItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case pullRequest, issue }
    public enum Relation: String, Sendable {
        /// The pull request closes the issue when merged.
        case closes
        /// The pull request only mentions the issue.
        case mentions
    }

    public let kind: Kind
    public let relation: Relation
    public let number: Int
    public let title: String
    public let repo: String
    public let url: URL
    /// OPEN, CLOSED or MERGED.
    public let state: String
    public let isDraft: Bool

    public var id: String { "\(repo)#\(number)" }

    public init(kind: Kind, relation: Relation, number: Int, title: String, repo: String, url: URL, state: String, isDraft: Bool) {
        self.kind = kind
        self.relation = relation
        self.number = number
        self.title = title
        self.repo = repo
        self.url = url
        self.state = state
        self.isDraft = isDraft
    }
}

public struct Person: Hashable, Sendable {
    public let login: String
    public let avatar: URL?
}

public struct IssueLabel: Hashable, Sendable {
    public let name: String
    /// Six hex digits, no "#".
    public let color: String
}

public struct Issue: Identifiable, Hashable, Sendable {
    public enum Lane: String, Sendable { case assigned, created }

    public let nodeID: String
    public let number: Int
    public let title: String
    public let body: String
    public let url: URL
    public let repo: String
    public let author: String
    public let authorAvatar: URL?
    public let createdAt: Date
    public let updatedAt: Date
    public let comments: Int
    public let labels: [IssueLabel]
    public let assignees: [Person]
    /// Pull requests that close or mention this issue.
    public let linked: [LinkedItem]
    public let lane: Lane
    public let accountID: String

    public var id: String { nodeID }
}

public struct Repo: Identifiable, Hashable, Sendable {
    public let nameWithOwner: String
    public let defaultBranch: String
    public let pushedAt: Date?
    public let accountID: String
    public var id: String { nameWithOwner }
}

public struct WorkflowRun: Identifiable, Hashable, Sendable {
    public enum Phase: Sendable {
        case queued, running, waiting, success, failure, cancelled, skipped, neutral
    }

    public let id: Int
    public let repo: String
    public let name: String
    public let title: String
    public let status: String
    public let conclusion: String?
    public let branch: String?
    public let event: String
    public let url: URL
    public let createdAt: Date
    public let updatedAt: Date
    public let runNumber: Int
    public let runAttempt: Int
    public let actor: String?
    public let actorAvatar: URL?
    public let accountID: String

    public var phase: Phase { Self.phase(status: status, conclusion: conclusion) }

    /// Runs, jobs and steps all report progress as a status plus a conclusion.
    public static func phase(status: String, conclusion: String?) -> Phase {
        switch status {
        case "queued", "requested", "pending": return .queued
        case "in_progress": return .running
        case "waiting", "action_required": return .waiting
        default: break
        }
        switch conclusion {
        case "success": return .success
        case "failure", "timed_out", "startup_failure": return .failure
        case "cancelled": return .cancelled
        case "skipped": return .skipped
        case "action_required": return .waiting
        default: return .neutral
        }
    }

    public var isActive: Bool { [.queued, .running, .waiting].contains(phase) }
}

public struct Job: Identifiable, Hashable, Sendable, Decodable {
    public struct Step: Hashable, Sendable, Decodable {
        public let name: String
        public let status: String
        public let conclusion: String?
        public let number: Int
    }

    public let id: Int
    public let name: String
    public let status: String
    public let conclusion: String?
    public let startedAt: Date?
    public let completedAt: Date?
    public let htmlUrl: URL?
    public let steps: [Step]?
}

public struct PendingDeployment: Hashable, Sendable, Decodable {
    public struct Environment: Hashable, Sendable, Decodable {
        public let id: Int
        public let name: String?
    }

    public let environment: Environment
    public let currentUserCanApprove: Bool
}

public struct PRFile: Identifiable, Hashable, Sendable, Decodable {
    public let filename: String
    public let status: String
    public let additions: Int
    public let deletions: Int
    public let patch: String?
    public var id: String { filename }
}

public struct Workflow: Identifiable, Hashable, Sendable, Decodable {
    public let id: Int
    public let name: String
    public let path: String
    public let state: String
}

public struct WorkflowInput: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case string, choice, boolean, number, environment }

    public let name: String
    public var description: String?
    public var required = false
    public var defaultValue: String?
    public var kind: Kind = .string
    public var options: [String] = []
    public var id: String { name }

    public init(name: String) { self.name = name }
}

public struct DispatchableWorkflow: Identifiable, Hashable, Sendable {
    public let workflow: Workflow
    public let inputs: [WorkflowInput]
    public var id: Int { workflow.id }
}

public enum MergeMethod: String, CaseIterable, Sendable {
    case squash, merge, rebase

    public var label: String {
        switch self {
        case .squash: "Squash and merge"
        case .merge: "Create a merge commit"
        case .rebase: "Rebase and merge"
        }
    }
}

public enum ReviewEvent: String, Sendable {
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"
    case comment = "COMMENT"
}

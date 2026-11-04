import Foundation

/// Everything one account contributes to the dashboard, fetched in one query.
public struct Snapshot: Sendable {
    public var login: String
    public var avatar: URL?
    public var reviewRequests: [PullRequest]
    /// Open pull requests you have reviewed and nobody is asking you about
    /// again: GitHub drops them from review-requested once you review.
    public var reviewed: [PullRequest]
    public var mine: [PullRequest]
    public var assignedIssues: [Issue]
    public var createdIssues: [Issue]
    public var repos: [Repo]
}

extension GitHubClient {
    static let prFragment = """
    fragment pr on PullRequest {
      id number title body url isDraft createdAt updatedAt additions deletions changedFiles
      reviewDecision mergeable headRefName baseRefName
      viewerLatestReview { state }
      author { login avatarUrl }
      repository { nameWithOwner }
      commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
      closingIssuesReferences(first: 6) { nodes { number title state url repository { nameWithOwner } } }
    }
    """

    /// Open pull requests you reviewed, asked apart from the dashboard: one
    /// more search there pushes the query past GitHub's time limit (502).
    static let reviewedQuery = """
    query($q: String!) { reviewed: search(query: $q, type: ISSUE, first: 30) { nodes { ...pr } } }
    """ + prFragment

    static let repoPullsQuery = """
    query($q: String!) { prs: search(query: $q, type: ISSUE, first: 80) { issueCount nodes { ...pr } } }
    """ + prFragment

    /// Every open pull request in a repository, newest activity first (up to
    /// 80), and how many there are in all. Yours get the `.mine` lane.
    public func openPullRequests(in repo: String) async throws -> (pulls: [PullRequest], total: Int) {
        struct Answer: Decodable {
            struct Search: Decodable { var issueCount: Int; var nodes: [RawPR] }
            var prs: Search
        }
        let answer: Answer = try await graphQL(Self.repoPullsQuery, variables: ["q": "is:open is:pr repo:\(repo) archived:false sort:updated-desc"])
        let me = account.login.lowercased()
        let accountID = account.id
        let pulls = answer.prs.nodes.compactMap { raw -> PullRequest? in
            let lane: PullRequest.Lane = raw.author?.login.lowercased() == me ? .mine : .reviewRequested
            return raw.pullRequest(lane: lane, accountID: accountID)
        }
        return (pulls, answer.prs.issueCount)
    }

    /// Open pull requests whose title or body match `text`, in one repository
    /// or in repositories under `owners` (users or organisations).
    public func searchPullRequests(_ text: String, owners: [String] = [], repo: String? = nil) async throws -> [PullRequest] {
        struct Answer: Decodable {
            struct Search: Decodable { var issueCount: Int; var nodes: [RawPR] }
            var prs: Search
        }
        let scope = repo.map { "repo:\($0)" } ?? owners.prefix(12).map { "user:\($0)" }.joined(separator: " ")
        let answer: Answer = try await graphQL(Self.repoPullsQuery,
                                               variables: ["q": "is:open is:pr archived:false \(scope) \(text) sort:updated-desc"])
        let me = account.login.lowercased()
        let accountID = account.id
        return answer.prs.nodes.prefix(20).compactMap { raw in
            raw.pullRequest(lane: raw.author?.login.lowercased() == me ? .mine : .reviewRequested, accountID: accountID)
        }
    }

    static let dashboardQuery = """
    query($review: String!, $mine: String!, $assigned: String!, $created: String!) {
      viewer {
        login
        avatarUrl
        repositories(first: 40, orderBy: {field: PUSHED_AT, direction: DESC},
                     ownerAffiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER]) {
          nodes { nameWithOwner pushedAt isArchived defaultBranchRef { name } }
        }
      }
      review: search(query: $review, type: ISSUE, first: 50) { nodes { ...pr } }
      mine: search(query: $mine, type: ISSUE, first: 50) { nodes { ...pr } }
      assigned: search(query: $assigned, type: ISSUE, first: 50) { nodes { ...issue } }
      created: search(query: $created, type: ISSUE, first: 50) { nodes { ...issue } }
    }
    fragment ref on PullRequest { number title state isDraft url repository { nameWithOwner } }
    fragment issue on Issue {
      id number title body url createdAt updatedAt
      author { login avatarUrl }
      repository { nameWithOwner }
      comments { totalCount }
      labels(first: 8) { nodes { name color } }
      assignees(first: 6) { nodes { login avatarUrl } }
      closedByPullRequestsReferences(first: 6, includeClosedPrs: true) { nodes { ...ref } }
      timelineItems(itemTypes: [CROSS_REFERENCED_EVENT], last: 8) {
        nodes { ... on CrossReferencedEvent { source { ... on PullRequest { ...ref } } } }
      }
    }
    """ + prFragment

    struct RawRef: Decodable {
        struct Repository: Decodable { var nameWithOwner: String }
        var number: Int?
        var title: String?
        var state: String?
        var isDraft: Bool?
        var url: URL?
        var repository: Repository?

        func item(_ kind: LinkedItem.Kind, _ relation: LinkedItem.Relation) -> LinkedItem? {
            guard let number, let url, let repository else { return nil }
            return LinkedItem(kind: kind, relation: relation, number: number, title: title ?? "", repo: repository.nameWithOwner,
                              url: url, state: state ?? "OPEN", isDraft: isDraft ?? false)
        }
    }

    struct Nodes<T: Decodable>: Decodable { var nodes: [T] }

    struct RawIssue: Decodable {
        struct Login: Decodable { var login: String; var avatarUrl: URL? }
        struct Repository: Decodable { var nameWithOwner: String }
        struct Count: Decodable { var totalCount: Int }
        struct Label: Decodable { var name: String; var color: String }
        struct CrossReference: Decodable { var source: RawRef? }

        var id: String?
        var number: Int?
        var title: String?
        var body: String?
        var url: URL?
        var createdAt: Date?
        var updatedAt: Date?
        var author: Login?
        var repository: Repository?
        var comments: Count?
        var labels: Nodes<Label>?
        var assignees: Nodes<Login>?
        var closedByPullRequestsReferences: Nodes<RawRef>?
        var timelineItems: Nodes<CrossReference>?

        func issue(lane: Issue.Lane, accountID: String) -> Issue? {
            guard let id, let number, let url, let repository else { return nil }
            var linked = closedByPullRequestsReferences?.nodes.compactMap { $0.item(.pullRequest, .closes) } ?? []
            for ref in timelineItems?.nodes.compactMap(\.source) ?? [] {
                guard let item = ref.item(.pullRequest, .mentions), !linked.contains(where: { $0.id == item.id }) else { continue }
                linked.append(item)
            }
            return Issue(
                nodeID: id, number: number, title: title ?? "", body: body ?? "", url: url, repo: repository.nameWithOwner,
                author: author?.login ?? "ghost", authorAvatar: author?.avatarUrl,
                createdAt: createdAt ?? .distantPast, updatedAt: updatedAt ?? .distantPast,
                comments: comments?.totalCount ?? 0,
                labels: labels?.nodes.map { IssueLabel(name: $0.name, color: $0.color) } ?? [],
                assignees: assignees?.nodes.map { Person(login: $0.login, avatar: $0.avatarUrl) } ?? [],
                linked: linked, lane: lane, accountID: accountID)
        }
    }

    struct RawPR: Decodable {
        struct Login: Decodable { var login: String; var avatarUrl: URL? }
        struct Repository: Decodable { var nameWithOwner: String }
        struct Commits: Decodable {
            struct Node: Decodable {
                struct Commit: Decodable {
                    struct Rollup: Decodable { var state: String }
                    var statusCheckRollup: Rollup?
                }
                var commit: Commit
            }
            var nodes: [Node]
        }

        var id: String?
        var number: Int?
        var title: String?
        var body: String?
        var url: URL?
        var isDraft: Bool?
        var createdAt: Date?
        var updatedAt: Date?
        var additions: Int?
        var deletions: Int?
        var changedFiles: Int?
        var reviewDecision: String?
        var mergeable: String?
        var headRefName: String?
        var baseRefName: String?
        var author: Login?
        var repository: Repository?
        var commits: Commits?
        var closingIssuesReferences: Nodes<RawRef>?
        struct Review: Decodable { var state: String }
        var viewerLatestReview: Review?

        func pullRequest(lane: PullRequest.Lane, accountID: String) -> PullRequest? {
            guard let id, let number, let url, let repository else { return nil }
            return PullRequest(
                nodeID: id, number: number, title: title ?? "", body: body ?? "", url: url,
                repo: repository.nameWithOwner,
                author: author?.login ?? "ghost", authorAvatar: author?.avatarUrl,
                isDraft: isDraft ?? false,
                createdAt: createdAt ?? .distantPast, updatedAt: updatedAt ?? .distantPast,
                additions: additions ?? 0, deletions: deletions ?? 0, changedFiles: changedFiles ?? 0,
                reviewDecision: reviewDecision.flatMap(ReviewDecision.init(rawValue:)),
                mergeable: mergeable.flatMap(Mergeable.init(rawValue:)) ?? .unknown,
                checks: commits?.nodes.last?.commit.statusCheckRollup.flatMap { CheckState(rawValue: $0.state) },
                headRef: headRefName ?? "", baseRef: baseRefName ?? "",
                lane: lane, accountID: accountID,
                linkedIssues: closingIssuesReferences?.nodes.compactMap { $0.item(.issue, .closes) } ?? [],
                myReview: viewerLatestReview.flatMap { PullRequest.MyReview(rawValue: $0.state) })
        }
    }

    public func snapshot() async throws -> Snapshot {
        struct Answer: Decodable {
            struct Viewer: Decodable {
                struct Repos: Decodable {
                    struct Node: Decodable {
                        struct Ref: Decodable { var name: String }
                        var nameWithOwner: String
                        var pushedAt: Date?
                        var isArchived: Bool
                        var defaultBranchRef: Ref?
                    }
                    var nodes: [Node]
                }
                var login: String
                var avatarUrl: URL?
                var repositories: Repos
            }
            struct Search: Decodable { var nodes: [RawPR] }
            var viewer: Viewer
            var review: Search
            var mine: Search
            var assigned: Nodes<RawIssue>
            var created: Nodes<RawIssue>
        }
        struct Reviewed: Decodable { var reviewed: Answer.Search }
        // Its own request, in parallel; if it fails, the rest still loads.
        async let reviewedAnswer: Reviewed? = try? graphQL(Self.reviewedQuery, variables: [
            "q": "is:open is:pr reviewed-by:@me -author:@me archived:false sort:updated-desc",
        ])
        let answer: Answer = try await graphQL(Self.dashboardQuery, variables: [
            "review": "is:open is:pr review-requested:@me archived:false sort:updated-desc",
            "mine": "is:open is:pr author:@me archived:false sort:updated-desc",
            "assigned": "is:open is:issue assignee:@me archived:false sort:updated-desc",
            "created": "is:open is:issue author:@me archived:false sort:updated-desc",
        ])
        let accountID = account.id
        let requested = answer.review.nodes.compactMap { $0.pullRequest(lane: .reviewRequested, accountID: accountID) }
        let requestedIDs = Set(requested.map(\.nodeID))
        return Snapshot(
            login: answer.viewer.login,
            avatar: answer.viewer.avatarUrl,
            reviewRequests: requested,
            reviewed: (await reviewedAnswer)?.reviewed.nodes.compactMap { $0.pullRequest(lane: .reviewRequested, accountID: accountID) }
                .filter { !requestedIDs.contains($0.nodeID) } ?? [],
            mine: answer.mine.nodes.compactMap { $0.pullRequest(lane: .mine, accountID: accountID) },
            assignedIssues: answer.assigned.nodes.compactMap { $0.issue(lane: .assigned, accountID: accountID) },
            createdIssues: answer.created.nodes.compactMap { $0.issue(lane: .created, accountID: accountID) },
            repos: answer.viewer.repositories.nodes
                .filter { !$0.isArchived }
                .map {
                    Repo(nameWithOwner: $0.nameWithOwner, defaultBranch: $0.defaultBranchRef?.name ?? "main",
                         pushedAt: $0.pushedAt, accountID: accountID)
                })
    }

    // MARK: Repositories

    struct RawRepo: Decodable {
        var fullName: String
        var defaultBranch: String?
        var pushedAt: Date?
        var archived: Bool?
    }

    private func repo(_ raw: RawRepo) -> Repo {
        Repo(nameWithOwner: raw.fullName, defaultBranch: raw.defaultBranch ?? "main", pushedAt: raw.pushedAt, accountID: account.id)
    }

    /// Every repository the account owns, collaborates on or reaches through
    /// an organisation, most recently pushed first.
    public func repositories(limit: Int = 500) async throws -> [Repo] {
        var found: [Repo] = []
        var page = 1
        while found.count < limit {
            let batch: [RawRepo] = try await get("/user/repos?per_page=100&sort=pushed&page=\(page)")
            found += batch.filter { !($0.archived ?? false) }.map(repo)
            if batch.count < 100 { break }
            page += 1
        }
        return found
    }

    public func repository(_ nameWithOwner: String) async throws -> Repo {
        repo(try await get("/repos/\(nameWithOwner)"))
    }

    // MARK: Pull requests

    public func files(of pr: PullRequest) async throws -> [PRFile] {
        // GitHub lists up to 3,000 files, 100 a page.
        var all: [PRFile] = []
        for page in 1...30 {
            let batch: [PRFile] = try await get("/repos/\(pr.repo)/pulls/\(pr.number)/files?per_page=100&page=\(page)")
            all += batch
            if batch.count < 100 { break }
        }
        return all
    }

    /// GitHub's "Viewed" marks for you on a pull request's files: viewed, and
    /// the ones viewed before they changed again (GitHub calls those dismissed).
    public func viewedFiles(of pr: PullRequest) async throws -> (viewed: Set<String>, changedSince: Set<String>) {
        struct File: Decodable { var path: String; var viewerViewedState: String }
        struct Page: Decodable {
            struct Info: Decodable { var hasNextPage: Bool; var endCursor: String? }
            var nodes: [File]; var pageInfo: Info
        }
        struct Answer: Decodable { struct PR: Decodable { var files: Page? }; var node: PR? }
        let query = """
        query($id: ID!, $after: String) { node(id: $id) { ... on PullRequest {
          files(first: 100, after: $after) { nodes { path viewerViewedState } pageInfo { hasNextPage endCursor } } } } }
        """
        var viewed = Set<String>(), changed = Set<String>()
        var after: String?
        for _ in 0..<30 {
            var variables: [String: Any] = ["id": pr.nodeID]
            if let after { variables["after"] = after }
            let answer: Answer = try await graphQL(query, variables: variables)
            guard let page = answer.node?.files else { break }
            for file in page.nodes {
                if file.viewerViewedState == "VIEWED" { viewed.insert(file.path) }
                if file.viewerViewedState == "DISMISSED" { changed.insert(file.path) }
            }
            guard page.pageInfo.hasNextPage, let cursor = page.pageInfo.endCursor else { break }
            after = cursor
        }
        return (viewed, changed)
    }

    /// Ticks or unticks "Viewed" on a file, the same mark GitHub's website shows.
    public func setViewed(_ pr: PullRequest, path: String, _ viewed: Bool) async throws {
        struct Answer: Decodable {}
        let mutation = viewed ? "markFileAsViewed" : "unmarkFileAsViewed"
        let _: Answer = try await graphQL("mutation($id: ID!, $path: String!) { \(mutation)(input: {pullRequestId: $id, path: $path}) { clientMutationId } }",
                                          variables: ["id": pr.nodeID, "path": path])
    }

    public func review(_ pr: PullRequest, event: ReviewEvent, body: String) async throws {
        var json: [String: Any] = ["event": event.rawValue]
        if !body.isEmpty { json["body"] = body }
        try await send("POST", "/repos/\(pr.repo)/pulls/\(pr.number)/reviews", json: json)
    }

    public func merge(_ pr: PullRequest, method: MergeMethod) async throws {
        try await send("PUT", "/repos/\(pr.repo)/pulls/\(pr.number)/merge", json: ["merge_method": method.rawValue])
    }

    // MARK: Issues

    public func comment(on issue: Issue, body: String) async throws {
        try await send("POST", "/repos/\(issue.repo)/issues/\(issue.number)/comments", json: ["body": body])
    }

    /// Closes an issue as completed, or as not planned.
    public func close(_ issue: Issue, completed: Bool) async throws {
        try await send("PATCH", "/repos/\(issue.repo)/issues/\(issue.number)", json: [
            "state": "closed", "state_reason": completed ? "completed" : "not_planned",
        ])
    }

    // MARK: Actions

    struct RawRun: Decodable {
        struct Actor: Decodable { var login: String; var avatarUrl: URL? }
        var id: Int
        var name: String?
        var displayTitle: String?
        var status: String?
        var conclusion: String?
        var headBranch: String?
        var event: String
        var htmlUrl: URL
        var createdAt: Date
        var updatedAt: Date
        var runNumber: Int
        var runAttempt: Int?
        var actor: Actor?

        func run(repo: String, accountID: String) -> WorkflowRun {
            WorkflowRun(
                id: id, repo: repo, name: name ?? "workflow", title: displayTitle ?? name ?? "",
                status: status ?? "completed", conclusion: conclusion, branch: headBranch,
                event: event, url: htmlUrl, createdAt: createdAt, updatedAt: updatedAt,
                runNumber: runNumber, runAttempt: runAttempt ?? 1,
                actor: actor?.login, actorAvatar: actor?.avatarUrl, accountID: accountID)
        }
    }

    public func runs(in repo: String, limit: Int = 10) async throws -> [WorkflowRun] {
        struct Page: Decodable { var workflowRuns: [RawRun] }
        let page: Page = try await get("/repos/\(repo)/actions/runs?per_page=\(limit)")
        let accountID = account.id
        return page.workflowRuns.map { $0.run(repo: repo, accountID: accountID) }
    }

    /// One run, fresh, for watching it while it goes.
    public func run(repo: String, id: Int) async throws -> WorkflowRun {
        let raw: RawRun = try await get("/repos/\(repo)/actions/runs/\(id)")
        return raw.run(repo: repo, accountID: account.id)
    }

    public func jobs(of run: WorkflowRun) async throws -> [Job] {
        struct Page: Decodable { var jobs: [Job] }
        let page: Page = try await get("/repos/\(run.repo)/actions/runs/\(run.id)/jobs?per_page=100")
        return page.jobs
    }

    /// The tail of a job's log, with the timestamp prefix GitHub puts on each line removed.
    public func logTail(repo: String, job: Job, lines: Int = 250) async throws -> String {
        let data = try await send("GET", "/repos/\(repo)/actions/jobs/\(job.id)/logs")
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(lines)
            .map { line -> Substring in
                // "2026-10-31T12:00:00.1234567Z message"
                if line.count > 29, line.dropFirst(4).first == "-", line.dropFirst(28).first == " " {
                    return line.dropFirst(29)
                }
                return line
            }
            .joined(separator: "\n")
    }

    public func rerun(_ run: WorkflowRun, failedOnly: Bool) async throws {
        try await send("POST", "/repos/\(run.repo)/actions/runs/\(run.id)/\(failedOnly ? "rerun-failed-jobs" : "rerun")")
    }

    public func cancel(_ run: WorkflowRun) async throws {
        try await send("POST", "/repos/\(run.repo)/actions/runs/\(run.id)/cancel")
    }

    public func pendingDeployments(of run: WorkflowRun) async throws -> [PendingDeployment] {
        try await get("/repos/\(run.repo)/actions/runs/\(run.id)/pending_deployments")
    }

    public func reviewDeployments(of run: WorkflowRun, environments: [Int], approve: Bool, comment: String) async throws {
        try await send("POST", "/repos/\(run.repo)/actions/runs/\(run.id)/pending_deployments", json: [
            "environment_ids": environments,
            "state": approve ? "approved" : "rejected",
            "comment": comment.isEmpty ? (approve ? "Approved from Hub" : "Rejected from Hub") : comment,
        ])
    }

    /// Workflows that can be started by hand, with the inputs each one asks for.
    public func dispatchableWorkflows(in repo: Repo) async throws -> [DispatchableWorkflow] {
        struct Page: Decodable { var workflows: [Workflow] }
        let page: Page = try await get("/repos/\(repo.nameWithOwner)/actions/workflows?per_page=100")
        let active = page.workflows.filter { $0.state == "active" && $0.path.hasPrefix(".github/workflows/") }
        return try await withThrowingTaskGroup(of: DispatchableWorkflow?.self) { group in
            for workflow in active {
                group.addTask {
                    let raw = try await send(
                        "GET", "/repos/\(repo.nameWithOwner)/contents/\(workflow.path)?ref=\(repo.defaultBranch)",
                        accept: "application/vnd.github.raw")
                    guard let inputs = WorkflowFile.dispatchInputs(in: String(decoding: raw, as: UTF8.self)) else { return nil }
                    return DispatchableWorkflow(workflow: workflow, inputs: inputs)
                }
            }
            var found: [DispatchableWorkflow] = []
            for try await item in group { if let item { found.append(item) } }
            return found.sorted { $0.workflow.name.localizedStandardCompare($1.workflow.name) == .orderedAscending }
        }
    }

    public func dispatch(_ workflow: Workflow, in repo: String, ref: String, inputs: [String: String]) async throws {
        try await send("POST", "/repos/\(repo)/actions/workflows/\(workflow.id)/dispatches", json: ["ref": ref, "inputs": inputs])
    }
}

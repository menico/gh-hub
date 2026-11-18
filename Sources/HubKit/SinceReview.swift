import Foundation

/// Something someone else said on a pull request after your last review.
public struct Reply: Identifiable, Hashable, Sendable {
    public let id: String
    public let author: String
    public let authorAvatar: URL?
    public let body: String
    public let date: Date
    /// Set for a reply in a line thread.
    public let path: String?
    public let line: Int?
    public let url: URL?
    /// The thread is one you wrote in, so the reply is likely to you.
    public let inYourThread: Bool
}

/// A commit pushed after your last review.
public struct NewCommit: Identifiable, Hashable, Sendable {
    public let sha: String
    public let message: String
    public let author: String
    public let date: Date?
    public let url: URL?
    public var id: String { sha }
    public var shortSHA: String { String(sha.prefix(7)) }
    public var title: String { message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? message }
}

/// What changed in the code between the commit you reviewed and the branch now.
public struct CodeSinceReview: Sendable {
    public var commits: [NewCommit]
    public var files: [String]
    /// The branch was rewritten (force-push or rebase): the commit you
    /// reviewed is gone, so the list may include changes from the base branch.
    public var rewritten: Bool
}

extension PRConversation {
    /// Comments, reviews and thread replies by anyone but `me`, after your last review.
    public func replies(since: Date, me: String) -> [Reply] {
        let me = me.lowercased()
        var out: [Reply] = []
        for thread in threads {
            let yours = thread.comments.contains { $0.author.lowercased() == me }
            for c in thread.comments where c.createdAt > since && c.author.lowercased() != me {
                out.append(Reply(id: c.id, author: c.author, authorAvatar: c.authorAvatar, body: c.body, date: c.createdAt,
                                 path: thread.path, line: thread.line ?? thread.originalLine, url: c.url, inYourThread: yours))
            }
        }
        // Thread replies also show up as review line comments; count them once.
        let threadBodies = Set(out.map { "\($0.author)|\($0.body)" })
        for entry in timeline where entry.date > since && entry.author.lowercased() != me {
            let body = entry.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if case .review = entry.kind, body.isEmpty,
               entry.lineComments.allSatisfy({ threadBodies.contains("\(entry.author)|\($0.body)") }) { continue }
            out.append(Reply(id: entry.id, author: entry.author, authorAvatar: entry.authorAvatar,
                             body: body.isEmpty ? Self.verdict(entry.kind) : body, date: entry.date,
                             path: nil, line: nil, url: nil, inYourThread: false))
        }
        return out.sorted { $0.date < $1.date }
    }

    static func verdict(_ kind: TimelineEntry.Kind) -> String {
        switch kind {
        case .review("APPROVED"): "Approved"
        case .review("CHANGES_REQUESTED"): "Requested changes"
        case .review: "Reviewed"
        case .comment: ""
        }
    }
}

extension GitHubClient {
    /// The commits and files between `base` (the commit you reviewed) and `head`.
    public func changes(in pr: PullRequest, from base: String, to head: String) async throws -> CodeSinceReview {
        struct Compare: Decodable {
            struct Person: Decodable { var login: String }
            struct Commit: Decodable {
                struct Inner: Decodable {
                    struct Who: Decodable { var name: String?; var date: Date? }
                    var message: String; var author: Who?
                }
                var sha: String; var html_url: URL?; var commit: Inner; var author: Person?
            }
            struct File: Decodable { var filename: String }
            var status: String
            var commits: [Commit]
            var files: [File]?
        }
        let answer: Compare
        do {
            answer = try await get("/repos/\(pr.repo)/compare/\(base)...\(head)")
        } catch GitHubError.http(404, _) {
            // The reviewed commit no longer exists anywhere: the branch was rewritten.
            return CodeSinceReview(commits: [], files: [], rewritten: true)
        }
        return CodeSinceReview(
            commits: answer.commits.map {
                NewCommit(sha: $0.sha, message: $0.commit.message, author: $0.author?.login ?? $0.commit.author?.name ?? "someone",
                          date: $0.commit.author?.date, url: $0.html_url)
            },
            files: (answer.files ?? []).map(\.filename),
            rewritten: answer.status == "diverged")
    }
}

extension ClaudeReview {
    /// The focus note for a re-review: what was pushed since your last review,
    /// and the open threads you are part of, so Claude checks they were addressed.
    public static func reReviewFocus(code: CodeSinceReview, threads: [ReviewThread], me: String) -> String {
        var text = "This is a follow-up review. The reviewer already reviewed this pull request; judge only what changed since then"
        text += code.files.isEmpty ? ".\n" : " (the diff below is limited to the files touched since: \(code.files.joined(separator: ", "))).\n"
        if code.rewritten {
            text += "The branch was force-pushed or rebased since, so some of these changes may come from the base branch; don't comment on those.\n"
        }
        if !code.commits.isEmpty {
            text += "\nCommits pushed since the last review:\n"
            text += code.commits.suffix(30).map { "- \($0.shortSHA) \($0.title) (\($0.author))" }.joined(separator: "\n") + "\n"
        }
        text += openThreads(threads, me: me)
        text += "\nDon't repeat feedback the reviewer already gave unless it is still unaddressed."
        return text
    }

    /// The reviewer's unresolved threads: what the author was actually asked
    /// to fix, and so what a re-review checks. Empty when there are none.
    public static func openThreads(_ threads: [ReviewThread], me: String) -> String {
        let me = me.lowercased()
        let open = threads.filter { t in !t.isResolved && t.comments.contains { $0.author.lowercased() == me } }
        guard !open.isEmpty else { return "" }
        var text = "\nThe reviewer's open threads, already on GitHub. Check each against the new code. In the summary, say which are addressed "
            + "and name any that are not (those block the merge). Do not add a comment or a risk that repeats one of these threads: "
            + "the reviewer will answer in the thread itself.\n"
        for t in open.prefix(20) {
            let line = (t.line ?? t.originalLine).map { ":\($0)" } ?? ""
            let said = t.comments.map { "\($0.author): \($0.body.replacingOccurrences(of: "\n", with: " ").prefix(300))" }
            text += "- \(t.path)\(line)\(t.isOutdated ? " (code since changed)" : "")\n" + said.map { "    \($0)" }.joined(separator: "\n") + "\n"
        }
        return text
    }
}

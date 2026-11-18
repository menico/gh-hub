import Foundation

/// What Claude made of a pull request: a summary, the risky spots, and line
/// comments you can add to your review.
public struct ClaudeReview: Codable, Hashable, Sendable {
    public struct Risk: Codable, Hashable, Sendable {
        public var level: String
        public var text: String
        public var path: String?
    }

    public struct Suggestion: Codable, Hashable, Sendable, Identifiable {
        public var path: String
        public var line: Int
        public var side: DiffSide?
        public var body: String
        /// Stable across launches (unlike `hashValue`), so handled ones stay handled.
        public var id: String {
            var hash: UInt64 = 0xcbf29ce484222325 // FNV-1a
            for byte in body.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
            return "\(path):\(side?.rawValue ?? "RIGHT"):\(line):\(String(hash, radix: 16))"
        }
    }

    public var summary: String
    /// approve, comment or request_changes.
    public var verdict: String
    public var risks: [Risk]
    public var comments: [Suggestion]
    public var reviewedAt: Date?
    public var costUSD: Double?
    /// The Claude session behind the review, to continue the conversation.
    public var sessionID: String?
    /// Where it ran and as which Claude profile (nil: plain `claude`).
    public var cwd: String?
    public var profile: String?
    /// "quick" (Hub's own prompt) or "code-review" (the /code-review plugin).
    public var mode: String?
    /// The persona it reviewed as ("Architect"); nil for reviews from before personas.
    public var persona: String?
    /// Suggestions added to a review or dismissed, by id: never offered again.
    public var handled: Set<String> = []
    /// The review you sent after this one ("APPROVE", "COMMENT", "REQUEST_CHANGES") and when.
    public var submitted: String?
    public var submittedAt: Date?

    public init(summary: String, verdict: String, risks: [Risk], comments: [Suggestion]) {
        self.summary = summary
        self.verdict = verdict
        self.risks = risks
        self.comments = comments
    }

    enum CodingKeys: String, CodingKey { case summary, verdict, risks, comments, reviewedAt, costUSD, sessionID, cwd, profile, mode, persona, handled, submitted, submittedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
        verdict = (try? c.decode(String.self, forKey: .verdict)) ?? "comment"
        risks = (try? c.decode([Risk].self, forKey: .risks)) ?? []
        comments = (try? c.decode([Suggestion].self, forKey: .comments)) ?? []
        reviewedAt = try? c.decode(Date.self, forKey: .reviewedAt)
        costUSD = try? c.decode(Double.self, forKey: .costUSD)
        sessionID = try? c.decode(String.self, forKey: .sessionID)
        cwd = try? c.decode(String.self, forKey: .cwd)
        profile = try? c.decode(String.self, forKey: .profile)
        mode = try? c.decode(String.self, forKey: .mode)
        persona = try? c.decode(String.self, forKey: .persona)
        handled = (try? c.decode(Set<String>.self, forKey: .handled)) ?? []
        submitted = try? c.decode(String.self, forKey: .submitted)
        submittedAt = try? c.decode(Date.self, forKey: .submittedAt)
    }

    // MARK: Prompt

    /// The diff with every line numbered the way GitHub addresses comments:
    /// `R12` is line 12 of the new file, `L7` line 7 of the old one.
    public static func numberedDiff(_ files: [PRFile], limit: Int = 180_000) -> String {
        var out = ""
        for file in files {
            out += "\n=== \(file.filename) (\(file.status), +\(file.additions) −\(file.deletions))\n"
            guard let patch = file.patch else { out += "(binary or too large to show)\n"; continue }
            if file.filename.hasSuffix(".lock") || file.filename.hasSuffix("-lock.json") || file.filename.hasSuffix("lock.yaml") {
                out += "(lock file, not shown)\n"; continue
            }
            var old = 0, new = 0
            for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(raw)
                if line.hasPrefix("@@") {
                    let parts = line.split(separator: " ")
                    if parts.count > 2 {
                        old = Int(parts[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                        new = Int(parts[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                    }
                    out += line + "\n"
                } else if line.hasPrefix("+") {
                    out += "R\(new) +\(line.dropFirst())\n"; new += 1
                } else if line.hasPrefix("-") {
                    out += "L\(old) -\(line.dropFirst())\n"; old += 1
                } else if !line.hasPrefix("\\") {
                    out += "R\(new)  \(line.dropFirst())\n"; old += 1; new += 1
                }
            }
            if out.count > limit { out += "\n(diff cut here: too long)\n"; break }
        }
        return out
    }

    /// `followUp`: the reviewer already reviewed this pull request, so only
    /// blocking problems count (`followUpBar`) instead of everything (`onePass`).
    /// `atHead`: the current folder is a checkout of the pull request's head
    /// commit, not just some clone of the repository.
    public static func prompt(for pr: PullRequest, files: [PRFile], hasCheckout: Bool, atHead: Bool = false, focus: String?,
                              persona: ReviewPersona = .general, followUp: Bool = false) -> String {
        """
        You are reviewing pull request #\(pr.number) in \(pr.repo): "\(pr.title)" by \(pr.author) (\(pr.headRef) → \(pr.baseRef)).

        Description:
        \(pr.body.isEmpty ? "(none)" : String(pr.body.prefix(4000)))

        \(atHead ? checkoutNote : hasCheckout ? "The current folder is a local clone of the repository (it may be on a different commit than this PR; the diff below is the truth). Read surrounding code when it helps you judge a change, but keep it brief." : "")
        \(focus.map { "The reviewer asks you to focus on: \($0)\n" } ?? "")
        \(persona.lens) Only comment where you are fairly confident\(followUp ? ". " + followUpBar : ", but be complete: " + onePass)

        Every diff line below starts with its address: R<n> is line n of the new file, L<n> is line n of the old file. \
        Comment only on lines that appear in the diff, using that number and side (RIGHT for R, LEFT for L).

        First write your findings for a person, in short markdown: the reviewer reads this when they open the conversation. \
        Then return the structured result: summary (2–4 sentences: what the PR does and whether it is safe to merge), verdict, \
        risks, and comments (markdown bodies that say what is wrong and what to do).

        The diff:
        \(numberedDiff(files))
        """
    }

    /// Runs Anthropic's code-review plugin (by its full name: Claude Code
    /// also has a built-in /code-review) on the pull request, without
    /// --comment so it posts nothing, and asks for the findings as JSON so
    /// they can become draft comments.
    public static func codeReviewPrompt(for pr: PullRequest, persona: ReviewPersona = .general, followUp: Bool = false, atHead: Bool = false) -> String {
        let lens = persona.id == ReviewPersona.general.id ? "" : """

        (The reviewer wants this review from a particular perspective; give it to every agent you launch and judge findings by it: \(persona.lens))
        """
        return """
        /code-review:code-review \(pr.url.absoluteString)

        (Hub runs this review for the user. Follow the command's steps as written, including launching its review agents in parallel, \
        even for a small pull request. Do not post anything to GitHub: no gh pr comment, no inline comments. \
        When the review is finished, write the findings for a person in short markdown (the reviewer reads this when they open \
        the conversation), then return the structured result: summary (2–4 sentences: what the PR does and whether it is safe to merge), \
        verdict, risks, and comments. \(followUp ? followUpBar + " Hold every agent's findings to this bar and drop the rest." : onePass) \
        Put each validated issue in "comments" when it points at a line the PR changed (use the new file's line number; \
        side LEFT with the old line number only for a removed line), otherwise in "risks". If nothing was found, say so in the summary and leave both lists empty.)
        """ + (atHead ? "\n\n" + checkoutNote + " Tell every agent you launch." : "") + lens
    }

    /// Said when the review runs in a checkout of the pull request's head.
    public static let checkoutNote = """
    The current folder is a checkout of this pull request at its head commit: Read, Grep and Glob see the code as the PR \
    leaves it, including files it adds. Use it to check callers, definitions and surrounding code before you call something \
    a problem, but keep it brief. It is a temporary copy: do not edit anything.
    """

    /// Asks for everything in one go: a review that holds findings back, or
    /// finds a few more each time it runs, sends the author round and round.
    public static let onePass = """
    The author will fix everything you raise in one round, and the reviewer does not want another round of new findings \
    after that. So report every real problem you see now, in one pass: go through every changed file and every hunk, \
    and include smaller issues too (start those comments with "nit:"). Do not keep anything back for a later review.
    """

    /// A re-review's bar. Without it every run finds a fresh crop of nits
    /// and design opinions, and the author never gets a clean "done".
    public static let followUpBar = """
    This is a re-review: the reviewer has already been through this pull request and the author has responded. \
    The only thing that matters now is whether it can merge. Raise a point only if it would block the merge: \
    a bug, a crash, broken or wrong behaviour, a security or data-loss problem, a missing piece the change needs to work, \
    or an earlier point that is still not addressed. Do not raise nits, style, naming, wording, comments/docs, small refactors, \
    duplication or design preferences, not even as "nit:" and not in risks. \
    Returning no comments is the expected, good outcome when the earlier points are addressed: then say plainly \
    "All earlier points are addressed; nothing blocking." in the summary, leave comments and risks empty, and set verdict to approve.
    """

    /// What an earlier Claude review of the same pull request raised, so a
    /// re-review checks those instead of starting over and finding a fresh
    /// set of things to say about code nobody touched.
    public static func priorFindings(_ previous: ClaudeReview, headChanged: Bool) -> String {
        guard !previous.comments.isEmpty || !previous.risks.isEmpty else {
            return """

            You reviewed this pull request before and found nothing to raise. \
            \(headChanged ? "Look only at what changed since; do not start raising points about code that was already there and unchanged." : "Unless you find a clear bug you missed, keep it that way.")
            """
        }
        // Not a to-do list: the reviewer chose which of these to send to the
        // author (those are the open threads), and ignored or dismissed the
        // rest. Asking for "still open" ones again re-posts every ignored nit.
        var text = """

        An earlier Claude review of this pull request already made the points below, and the reviewer has decided \
        what to pass on to the author (the reviewer's own threads, if any, are what the author was asked to fix). \
        Do not raise any of these points again, in comments or risks, reworded or not, whether or not the code changed. \
        The one exception: a point that blocks the merge by the bar above and is still in the current code; \
        mention that once in the summary.

        Already raised before:
        """
        for c in previous.comments.prefix(40) {
            text += "\n- \(c.path):\(c.line): \(c.body.replacingOccurrences(of: "\n", with: " ").prefix(300))"
        }
        for r in previous.risks.prefix(20) {
            text += "\n- risk (\(r.level))\(r.path.map { " in \($0)" } ?? ""): \(r.text.replacingOccurrences(of: "\n", with: " ").prefix(300))"
        }
        return text + "\n"
    }

    /// What `claude -p --json-schema` must return. Claude hands it over
    /// through a tool call, so the conversation itself stays prose.
    public static let schema = """
    {"type":"object","additionalProperties":false,"required":["summary","verdict","risks","comments"],
     "properties":{
      "summary":{"type":"string"},
      "verdict":{"type":"string","enum":["approve","comment","request_changes"]},
      "risks":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["level","text"],
        "properties":{"level":{"type":"string","enum":["high","medium","low"]},"text":{"type":"string"},"path":{"type":["string","null"]}}}},
      "comments":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["path","line","side","body"],
        "properties":{"path":{"type":"string"},"line":{"type":"integer"},"side":{"type":"string","enum":["RIGHT","LEFT"]},"body":{"type":"string"}}}}}}
    """

    // MARK: Answer

    /// Reads Claude's answer: the `claude -p --output-format json` envelope,
    /// or plain text holding a JSON object (possibly in a code fence).
    public static func parse(_ output: String) -> ClaudeReview? {
        var text = output
        var cost: Double?
        var session: String?
        // The envelope is the last line that is a JSON object with a "result".
        for line in output.split(separator: "\n").reversed() where line.hasPrefix("{") {
            if let data = line.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = object["result"] as? String {
                // With --json-schema the answer is its own field; the result text may be prose.
                if let structured = object["structured_output"],
                   let data = try? JSONSerialization.data(withJSONObject: structured),
                   let json = String(data: data, encoding: .utf8) {
                    text = json
                } else {
                    text = result
                }
                cost = object["total_cost_usd"] as? Double
                session = object["session_id"] as? String
                break
            }
        }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              var review = try? JSONDecoder().decode(ClaudeReview.self, from: data),
              !review.summary.isEmpty || !review.comments.isEmpty
        else { return nil }
        review.costUSD = cost
        review.sessionID = session
        return review
    }

    /// Why a `claude -p --output-format json` run stopped without an answer.
    public struct Failure: Equatable, Sendable {
        public var message: String
        /// The account's login expired or is missing: `claude auth login` fixes it.
        public var needsLogin: Bool
    }

    /// The error a failed run reports in its envelope (`is_error` with a
    /// `result` message), or nil when there is none.
    public static func failure(in output: String) -> Failure? {
        for line in output.split(separator: "\n").reversed() where line.hasPrefix("{") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "result"
            else { continue }
            guard object["is_error"] as? Bool == true else { return nil }
            let message = (object["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let text = message.isEmpty ? "Claude stopped with an error (\(object["subtype"] as? String ?? "unknown"))." : message
            let lower = text.lowercased()
            let login = ["failed to authenticate", "oauth", "/login", "not logged in", "invalid api key"].contains { lower.contains($0) }
            return Failure(message: text, needsLogin: login)
        }
        return nil
    }

    /// Keeps only comments that land on a line of the diff, the only places
    /// GitHub accepts them.
    public func anchored(to files: [PRFile]) -> ClaudeReview {
        var lines: [String: (left: Set<Int>, right: Set<Int>)] = [:]
        for file in files {
            guard let patch = file.patch else { continue }
            var left = Set<Int>(), right = Set<Int>()
            var old = 0, new = 0
            for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
                if raw.hasPrefix("@@") {
                    let parts = raw.split(separator: " ")
                    if parts.count > 2 {
                        old = Int(parts[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                        new = Int(parts[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                    }
                } else if raw.hasPrefix("+") { right.insert(new); new += 1 }
                else if raw.hasPrefix("-") { left.insert(old); old += 1 }
                else if !raw.hasPrefix("\\") { right.insert(new); left.insert(old); old += 1; new += 1 }
            }
            lines[file.filename] = (left, right)
        }
        var copy = self
        func lands(_ c: Suggestion) -> Bool {
            guard let known = lines[c.path] else { return false }
            return (c.side ?? .right) == .right ? known.right.contains(c.line) : known.left.contains(c.line)
        }
        copy.comments = comments.filter(lands)
        // A finding off the diff can't be a line comment, but it is still worth reading.
        copy.risks += comments.filter { !lands($0) }.map { Risk(level: "medium", text: $0.body, path: "\($0.path):\($0.line)") }
        return copy
    }
}

import Foundation

/// Claude's read of a review thread after the other side answered: was the
/// comment addressed, and a reply to send.
public struct ThreadCheck: Codable, Hashable, Sendable {
    /// "yes", "partly" or "no".
    public var addressed: String
    /// What the answer and the current code say, in a sentence or two.
    public var assessment: String
    /// A reply in the reviewer's voice, ready to edit.
    public var reply: String
    /// Whether the thread can be resolved once the reply is sent.
    public var resolve: Bool

    public static let schema = """
    {"type":"object","additionalProperties":false,"required":["addressed","assessment","reply","resolve"],
     "properties":{"addressed":{"type":"string","enum":["yes","partly","no"]},"assessment":{"type":"string"},
      "reply":{"type":"string"},"resolve":{"type":"boolean"}}}
    """

    public static func prompt(pr: PullRequest, thread: ReviewThread, reviewer: String, currentPatch: String?,
                              hasCheckout: Bool, persona: ReviewPersona = .general) -> String {
        let conversation = thread.comments.map { "@\($0.author) (\($0.createdAt.formatted(.iso8601))):\n\($0.body)" }
            .joined(separator: "\n\n---\n\n")
        return """
        You help @\(reviewer) follow up on their review of pull request #\(pr.number) in \(pr.repo): "\(pr.title)" by @\(pr.author).

        @\(reviewer) left a comment on \(thread.path)\(thread.line.map { ":\($0)" } ?? thread.originalLine.map { " (originally line \($0))" } ?? "")\
        \(thread.isOutdated ? ", and the code there has changed since" : ""). Here is the thread so far:

        \(conversation)

        The code the comment was made on:
        ```diff
        \(thread.diffHunk ?? "(not available)")
        ```

        \(currentPatch.map { "The pull request's current diff for \(thread.path):\n```diff\n\(String($0.prefix(30_000)))\n```" } ?? "The file is no longer in the pull request's diff.")

        \(hasCheckout ? "The current folder is a clone of the repository (it may be on another commit; the diffs above are the truth). Read around the change if you need to." : "")

        \(persona.id == ReviewPersona.general.id ? "" : "@\(reviewer) reviews from this perspective: \(persona.lens)\n")
        Decide whether the latest answer and the current code address @\(reviewer)'s point: yes, partly or no. \
        An explanation can address it as well as a code change, if it is convincing; say so when it isn't. \
        Then write the reply @\(reviewer) would send: first person, short, friendly and specific, in markdown, no greeting or sign-off. \
        If it is addressed, a brief acknowledgement is enough; if not, say exactly what is still missing. \
        Say whether the thread can be resolved after this reply.

        First write your reasoning briefly for a person, then return the structured result.
        """
    }

    /// Reads the `claude -p --output-format json` envelope.
    public static func parse(_ output: String) -> ThreadCheck? {
        for line in output.split(separator: "\n").reversed() where line.hasPrefix("{") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let structured = object["structured_output"],
               let json = try? JSONSerialization.data(withJSONObject: structured) {
                return try? JSONDecoder().decode(ThreadCheck.self, from: json)
            }
            if object["type"] as? String == "result" { return nil }
        }
        return nil
    }
}

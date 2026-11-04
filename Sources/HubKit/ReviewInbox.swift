import Foundation

/// Line comments a Claude conversation hands back to GH Hub.
///
/// A conversation started from GH Hub has `gh-hub-comment` on its PATH. Each
/// call writes one file to the inbox folder; GH Hub picks it up, adds it to
/// the pull request's pending comments and deletes the file. Nothing is sent
/// to GitHub until you send the review.
///
/// File format:
///
///     pr: PR_kwDO…
///     path: src/app.ts
///     line: 42
///     side: RIGHT
///     ---
///     The comment, in Markdown.
public enum ReviewInbox {
    public struct Item: Equatable, Sendable {
        public var pullRequestID: String
        public var comment: DraftComment

        public static func == (a: Item, b: Item) -> Bool {
            a.pullRequestID == b.pullRequestID && a.comment.path == b.comment.path && a.comment.line == b.comment.line
                && a.comment.side == b.comment.side && a.comment.body == b.comment.body
        }
    }

    public static let fileExtension = "comment"

    public static func parse(_ text: String) -> Item? {
        guard let split = text.range(of: "\n---\n") else { return nil }
        var fields: [String: String] = [:]
        for line in text[..<split.lowerBound].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[line[..<colon].trimmingCharacters(in: .whitespaces)] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let body = text[split.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        var path = fields["path"] ?? ""
        while path.hasPrefix("./") { path.removeFirst(2) }
        guard let pr = fields["pr"], !pr.isEmpty, !path.isEmpty, !path.hasPrefix("/"),
              let line = fields["line"].flatMap(Int.init), line > 0, !body.isEmpty else { return nil }
        let side = DiffSide(rawValue: fields["side"]?.uppercased() ?? "") ?? .right
        return Item(pullRequestID: pr, comment: DraftComment(path: path, line: line, side: side, body: body, fromClaude: true))
    }

    /// What the conversation is told, so it knows how to hand comments back.
    public static func instructions(repo: String, number: Int) -> String {
        """
        This conversation was opened from GH Hub, where the user has pull request \(repo)#\(number) open. \
        When the user asks you to add comments to their review, or to put findings back in GH Hub, run this once per comment:

        gh-hub-comment <path> <line> <<'EOF'
        <the comment, in Markdown, written to the PR author>
        EOF

        <path> is relative to the repository root. <line> is a line number in the pull request's new version of the file, \
        and it must be part of the diff (an added or changed line, or a context line next to one); for a deleted line, \
        add --old after the line number and use the line number in the old file. Check with `git diff` against the base \
        branch if you are not sure. The comments become pending comments in GH Hub, where the user edits and sends them. \
        Never post reviews or comments to GitHub yourself.
        """
    }

    /// The `gh-hub-comment` command.
    public static func helperScript(inbox: String) -> String {
        """
        #!/bin/bash
        # Written by GH Hub: hands a line comment back to GH Hub as a pending review comment.
        usage() { echo "usage: gh-hub-comment <path> <line> [--old] <<'EOF' … EOF  (the comment on stdin)" >&2; exit 2; }
        [ -n "$GH_HUB_PR" ] || { echo "gh-hub-comment: this terminal was not opened from GH Hub for a pull request." >&2; exit 1; }
        [ $# -ge 2 ] || usage
        path="$1"; line="$2"; side=RIGHT
        [ "${3:-}" = "--old" ] && side=LEFT
        case "$line" in ''|*[!0-9]*) echo "gh-hub-comment: <line> must be a number." >&2; exit 2;; esac
        case "$path" in *$'\\n'*|/*) echo "gh-hub-comment: <path> must be relative to the repository root." >&2; exit 2;; esac
        body="$(cat)"
        [ -n "${body//[[:space:]]/}" ] || { echo "gh-hub-comment: the comment is empty; pass it on stdin." >&2; exit 2; }
        inbox=\(inbox.shellQuoted)
        mkdir -p "$inbox" || exit 1
        tmp="$(mktemp "$inbox/.incoming.XXXXXX")" || exit 1
        printf 'pr: %s\\npath: %s\\nline: %s\\nside: %s\\n---\\n%s\\n' "$GH_HUB_PR" "$path" "$line" "$side" "$body" > "$tmp" \\
          && mv "$tmp" "$tmp.\(fileExtension)" \\
          && echo "Added to GH Hub as a pending comment on $path:$line."
        """
    }
}

private extension String {
    var shellQuoted: String { "'" + replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

import Foundation
import XCTest
@testable import HubKit

final class WorkflowFileTests: XCTestCase {
    func testNoDispatch() {
        XCTAssertNil(WorkflowFile.dispatchInputs(in: "on:\n  push:\n    branches: [main]\njobs: {}\n"))
    }

    func testInlineDispatch() {
        XCTAssertEqual(WorkflowFile.dispatchInputs(in: "on: [push, workflow_dispatch]\n"), [])
        XCTAssertEqual(WorkflowFile.dispatchInputs(in: "on: workflow_dispatch\n"), [])
        XCTAssertEqual(WorkflowFile.dispatchInputs(in: "on:\n  - push\n  - workflow_dispatch\n"), [])
    }

    func testDispatchWithoutInputs() {
        XCTAssertEqual(WorkflowFile.dispatchInputs(in: "on:\n  workflow_dispatch:\n  push:\njobs:\n"), [])
    }

    func testInputs() throws {
        let yaml = """
        name: Deploy
        on:
          push:
            branches: [main]
          workflow_dispatch:
            inputs:
              environment:
                description: 'Where to deploy' # comment
                required: true
                default: staging
                type: choice
                options:
                  - staging
                  - "production"
              dry_run:
                type: boolean
                default: false
              tags:
                options: [a, 'b']
          schedule:
            - cron: '0 0 * * *'
        jobs:
          deploy:
            runs-on: ubuntu-latest
        """
        let inputs = try XCTUnwrap(WorkflowFile.dispatchInputs(in: yaml))
        XCTAssertEqual(inputs.map(\.name), ["environment", "dry_run", "tags"])
        XCTAssertEqual(inputs[0].description, "Where to deploy")
        XCTAssertTrue(inputs[0].required)
        XCTAssertEqual(inputs[0].defaultValue, "staging")
        XCTAssertEqual(inputs[0].kind, .choice)
        XCTAssertEqual(inputs[0].options, ["staging", "production"])
        XCTAssertEqual(inputs[1].kind, .boolean)
        XCTAssertEqual(inputs[1].defaultValue, "false")
        XCTAssertEqual(inputs[2].options, ["a", "b"])
    }
}

final class GHCLITests: XCTestCase {
    func testParsesAccounts() throws {
        let json = """
        {"hosts":{"github.com":[
          {"state":"success","active":true,"host":"github.com","login":"alice"},
          {"state":"error","active":false,"host":"github.com","login":"broken"},
          {"state":"success","active":false,"host":"github.com","login":"bob"}]}}
        """
        let accounts = try GHCLI.parseAccounts(Data(json.utf8))
        XCTAssertEqual(accounts.map(\.login), ["alice", "bob"])
    }
}

final class RunPhaseTests: XCTestCase {
    func run(_ status: String, _ conclusion: String?) -> WorkflowRun {
        WorkflowRun(
            id: 1, repo: "o/r", name: "ci", title: "t", status: status, conclusion: conclusion, branch: "main",
            event: "push", url: URL(string: "https://github.com")!, createdAt: .now, updatedAt: .now,
            runNumber: 1, runAttempt: 1, actor: nil, actorAvatar: nil, accountID: "a")
    }

    func testPhases() {
        XCTAssertEqual(run("in_progress", nil).phase, .running)
        XCTAssertEqual(run("waiting", nil).phase, .waiting)
        XCTAssertEqual(run("completed", "timed_out").phase, .failure)
        XCTAssertEqual(run("completed", "success").phase, .success)
        XCTAssertTrue(run("queued", nil).isActive)
    }
}

final class LocalTests: XCTestCase {
    func testRemoteURLs() {
        XCTAssertEqual(Git.repo(fromRemote: "git@github.com:menico/cpx.git")?.nameWithOwner, "menico/cpx")
        XCTAssertEqual(Git.repo(fromRemote: "https://github.com/menico/cpx")?.nameWithOwner, "menico/cpx")
        XCTAssertEqual(Git.repo(fromRemote: "https://user@github.com/menico/cpx.git")?.nameWithOwner, "menico/cpx")
        XCTAssertEqual(Git.repo(fromRemote: "ssh://git@github.example.com:22/team/app.git")?.host, "github.example.com")
        XCTAssertNil(Git.repo(fromRemote: "/local/path/repo"))
    }

    func testOriginInConfig() {
        let config = """
        [core]
        \tbare = false
        [remote "upstream"]
        \turl = git@github.com:other/repo.git
        [remote "origin"]
        \turl = git@github.com:me/repo.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        """
        XCTAssertEqual(Git.originURL(inConfig: config), "git@github.com:me/repo.git")
    }

    func testOriginOfWorktree() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("hub-\(UUID().uuidString)")
        let main = root.appendingPathComponent("repo")
        let gitDir = main.appendingPathComponent(".git")
        try fm.createDirectory(at: gitDir.appendingPathComponent("worktrees/pr-1"), withIntermediateDirectories: true)
        try "[remote \"origin\"]\n\turl = https://github.com/acme/widget.git\n".write(to: gitDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: gitDir.appendingPathComponent("worktrees/pr-1/commondir"), atomically: true, encoding: .utf8)
        let worktree = root.appendingPathComponent("repo-worktrees/pr-1/src")
        try fm.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(gitDir.path)/worktrees/pr-1\n".write(to: root.appendingPathComponent("repo-worktrees/pr-1/.git"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: root) }

        XCTAssertEqual(Git.origin(of: worktree.path)?.nameWithOwner, "acme/widget")
        XCTAssertEqual(Git.origin(of: main.path)?.nameWithOwner, "acme/widget")
        let resolve = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        XCTAssertEqual(Git.findClones(in: [root.path])["acme/widget"]?.map(resolve), [resolve(main.path)])
    }

    func testCpxConfig() {
        let config = CpxConfig.parse(config: """
        version = 1
        [profiles.work]
        dir = "/Users/me/.claude-work"
        color = "#5dc794"
        [profiles.work.resources]
        settings = "own"
        [profiles.side]
        dir = "/Users/me/.claude-side"
        """, bindings: """
        [[bindings]]
        path = "/Users/me/Work"
        profile = "side"
        provider = "claude"
        [[bindings]]
        path = "/Users/me/Work/side"
        profile = "work"
        provider = "claude"
        [[bindings]]
        path = "/Users/me/Work/x"
        profile = "gpt"
        provider = "codex"
        """)
        XCTAssertEqual(config.profiles.map(\.name), ["work", "side"])
        XCTAssertEqual(config.profiles.first?.color, "#5dc794")
        XCTAssertEqual(config.boundProfile(for: "/Users/me/Work/side/app"), "work")
        XCTAssertEqual(config.boundProfile(for: "/Users/me/Work/app"), "side")
        XCTAssertNil(config.boundProfile(for: "/Users/me/Workshop"))
        XCTAssertEqual(config.bindings.count, 2)
    }

    func testSessionParse() throws {
        let lines = [
            #"{"type":"user","isMeta":true,"message":{"content":"<command-name>/login</command-name>"},"sessionId":"s1","cwd":"/r","gitBranch":"main","timestamp":"2026-10-30T10:00:00.000Z"}"#,
            #"{"type":"user","message":{"content":[{"type":"text","text":"Fix the flaky test\nin CI"}]},"sessionId":"s1","cwd":"/r","gitBranch":"fix/flaky"}"#,
            #"{"type":"assistant","message":{"content":[]},"sessionId":"s1","cwd":"/r","gitBranch":"HEAD"}"#,
        ]
        let session = try XCTUnwrap(SessionIndex.parse(
            head: Data(lines.joined(separator: "\n").utf8), tail: Data(), path: "/p.jsonl", configDir: "/c", modified: .now))
        XCTAssertEqual(session.id, "s1")
        XCTAssertEqual(session.branches, ["main", "fix/flaky"])
        XCTAssertEqual(session.prompt, "Fix the flaky test in CI")
    }
}

final class ReviewTests: XCTestCase {
    func testLinks() {
        XCTAssertEqual(GitHubLink.parse("https://github.com/menico/cpx/pull/12/files"), .pullRequest(repo: "menico/cpx", number: 12))
        XCTAssertEqual(GitHubLink.parse(" https://github.com/menico/cpx/issues/7 "), .issue(repo: "menico/cpx", number: 7))
        XCTAssertEqual(GitHubLink.parse("https://github.com/a/b/actions/runs/99/job/1"), .run(repo: "a/b", id: 99))
        XCTAssertEqual(GitHubLink.parse("https://github.com/a/b"), .repository("a/b"))
        XCTAssertNil(GitHubLink.parse("fix login"))
    }

    func testWorktreeList() {
        let text = """
        worktree /r/app
        HEAD aaa
        branch refs/heads/main

        worktree /r/app-worktrees/pr-12
        HEAD bbb
        branch refs/heads/feat/x

        worktree /r/app-worktrees/run-5
        HEAD ccc
        detached

        """
        let trees = Git.parseWorktrees(text, clone: "/r/app")
        XCTAssertEqual(trees.map(\.path), ["/r/app", "/r/app-worktrees/pr-12", "/r/app-worktrees/run-5"])
        XCTAssertEqual(trees[1].branch, "feat/x")
        XCTAssertEqual(trees[1].pullRequestNumber, 12)
        XCTAssertNil(trees[2].branch)
    }

    func testGhosttyLook() {
        var look = TerminalLook()
        look.apply("""
        font-family = "JetBrainsMono Nerd Font"
        font-size = 14
        theme = light:Day,dark:Night
        background = 101010
        """, darkMode: true) { name in
            name == "Night" ? "background = #000000\nforeground = #eeeeee\npalette = 1=#ff0000" : nil
        }
        XCTAssertEqual(look.fontFamily, "JetBrainsMono Nerd Font")
        XCTAssertEqual(look.fontSize, 14)
        XCTAssertEqual(look.background, "#101010") // the file's own colour beats the theme
        XCTAssertEqual(look.foreground, "#eeeeee")
        XCTAssertEqual(look.palette[1], "#ff0000")
    }

    func file(_ name: String, _ patch: String) -> PRFile {
        PRFile(filename: name, status: "modified", additions: 1, deletions: 1, patch: patch)
    }

    func testClaudeReviewParseAndAnchor() throws {
        let patch = "@@ -10,3 +10,3 @@\n keep\n-old\n+new\n keep2"
        let numbered = ClaudeReview.numberedDiff([file("a.swift", patch)])
        XCTAssertTrue(numbered.contains("R10  keep"))
        XCTAssertTrue(numbered.contains("L11 -old"))
        XCTAssertTrue(numbered.contains("R11 +new"))
        XCTAssertTrue(numbered.contains("R12  keep2"))

        let inner = #"{"summary":"Swaps old for new.","verdict":"comment","risks":[{"level":"low","text":"t"}],"comments":[{"path":"a.swift","line":11,"side":"RIGHT","body":"why?"},{"path":"a.swift","line":40,"side":"RIGHT","body":"off the diff"},{"path":"a.swift","line":11,"side":"LEFT","body":"old"}]}"#
        let envelope = try String(data: JSONSerialization.data(withJSONObject: ["type": "result", "result": "Here:\n```json\n\(inner)\n```", "total_cost_usd": 0.12, "session_id": "abc"]), encoding: .utf8)!
        let review = try XCTUnwrap(ClaudeReview.parse("noise from a shell\n" + envelope))
        XCTAssertEqual(review.summary, "Swaps old for new.")
        XCTAssertEqual(review.costUSD, 0.12)
        XCTAssertEqual(review.sessionID, "abc")
        let anchored = review.anchored(to: [file("a.swift", patch)])
        XCTAssertEqual(anchored.comments.map(\.body), ["why?", "old"])
        XCTAssertEqual(anchored.risks.last?.text, "off the diff") // kept, as a risk
        XCTAssertTrue(ClaudeReview.codeReviewPrompt(for: PullRequest.sample).hasPrefix("/code-review:code-review https://github.com/o/r/pull/7"))
    }
}

final class StructuredOutputTests: XCTestCase {
    func testReadsStructuredOutputOverProse() throws {
        let envelope = #"{"type":"result","result":"Looks fine overall, one nit.","session_id":"s1","total_cost_usd":0.1,"#
            + #""structured_output":{"summary":"Adds a step.","verdict":"comment","risks":[],"#
            + #""comments":[{"path":"a.yml","line":4,"side":"RIGHT","body":"Quote this."}]}}"#
        let review = try XCTUnwrap(ClaudeReview.parse("noise from a hook\n" + envelope))
        XCTAssertEqual(review.summary, "Adds a step.")
        XCTAssertEqual(review.comments.first?.path, "a.yml")
        XCTAssertEqual(review.sessionID, "s1")
    }
}

final class SuggestionIDTests: XCTestCase {
    func testIDIsStableAcrossLaunches() {
        let s = ClaudeReview.Suggestion(path: "a.swift", line: 3, side: .right, body: "Use a guard here.")
        // FNV-1a of the body, fixed: hashValue would change every launch.
        XCTAssertEqual(s.id, "a.swift:RIGHT:3:ebf5f51811474b16")
        XCTAssertEqual(s.id, ClaudeReview.Suggestion(path: "a.swift", line: 3, side: .right, body: "Use a guard here.").id)
        XCTAssertNotEqual(s.id, ClaudeReview.Suggestion(path: "a.swift", line: 3, side: .right, body: "Use a guard there.").id)
    }
}

extension PullRequest {
    static let sample = PullRequest(
        nodeID: "n", number: 7, title: "t", body: "", url: URL(string: "https://github.com/o/r/pull/7")!, repo: "o/r",
        author: "a", authorAvatar: nil, isDraft: false, createdAt: .now, updatedAt: .now, additions: 1, deletions: 0,
        changedFiles: 1, reviewDecision: nil, mergeable: .mergeable, checks: nil, headRef: "h", baseRef: "main",
        lane: .reviewRequested, accountID: "a", linkedIssues: [])
}

final class CpxUsageTests: XCTestCase {
    // What `cpx --json usage` printed on this Mac, trimmed.
    let cli = """
    {"accounts":[
     {"profile":"work","provider":"claude","directory":"/h/.claude-work","command":"claude-work",
      "usage":{"provider":"claude","windows":[{"id":"session","title":"5-hour","usedPercent":85.0,"resetsAtEpoch":1793000000},
                {"id":"weekly","title":"Weekly","usedPercent":3.0}],"source":"oauth","fetchedAt":1792990000}},
     {"profile":"side","provider":"claude","directory":"/h/.claude-side","command":"claude-side",
      "usage":{"provider":"claude","windows":[{"id":"session","title":"5-hour","usedPercent":0.0},{"id":"weekly","title":"Weekly","usedPercent":5.0}],"source":"oauth","fetchedAt":1792990000}},
     {"profile":"spare","provider":"claude","directory":"/h/.claude-spare","command":"claude-spare","error":{"kind":"tokenExpired","command":"claude-spare"}},
     {"profile":null,"provider":"claude","directory":"/h/.claude","command":"claude",
      "usage":{"provider":"claude","windows":[{"id":"session","title":"5-hour","usedPercent":2.0},{"id":"weekly","title":"Weekly","usedPercent":44.0}],"source":"oauth","fetchedAt":1792990000}},
     {"profile":null,"provider":"codex","directory":"/h/.codex","command":"codex","error":{"kind":"cli","detail":"codex app-server exited before answering"}}
    ]}
    """

    func testReadsClaudeAccountsOnly() throws {
        let usage = try XCTUnwrap(CpxUsage.parse(Data(cli.utf8)))
        XCTAssertEqual(usage.accounts.count, 4)
        XCTAssertEqual(usage.account("work")?.session?.usedPercent, 85)
        XCTAssertEqual(usage.account(nil)?.weekly?.usedPercent, 44)
        XCTAssertTrue(usage.account("spare")?.isLoginProblem == true)
        XCTAssertEqual(usage.account("work")?.tightest?.id, "session")
        XCTAssertNil(usage.writtenAt)
    }

    func testReadsTheAppSnapshot() throws {
        let snapshot = "{\"writtenAt\":\"2026-11-02T06:30:00Z\"," + cli.dropFirst()
        let usage = try XCTUnwrap(CpxUsage.parse(Data(snapshot.utf8)))
        XCTAssertNotNil(usage.writtenAt)
        XCTAssertEqual(usage.accounts.count, 4)
    }

    func testSuggestsTheRoomiestSignedInProfile() throws {
        let usage = try XCTUnwrap(CpxUsage.parse(Data(cli.utf8)))
        XCTAssertTrue(CpxUsage.isNearLimit(usage.account("work")!))
        XCTAssertFalse(CpxUsage.isNearLimit(usage.account("side")!))
        XCTAssertEqual(usage.roomiest(among: ["work", "side", "spare", nil], excluding: "work")?.profile, "side")
    }
}

final class ReviewPersonaTests: XCTestCase {
    func testPromptUsesThePersonasLens() {
        let architect = ClaudeReview.prompt(for: .sample, files: [], hasCheckout: true, focus: nil, persona: .architect)
        XCTAssertTrue(architect.contains("Review as a software architect"))
        XCTAssertFalse(architect.contains("Review the diff for correctness bugs"))
        let general = ClaudeReview.prompt(for: .sample, files: [], hasCheckout: true, focus: nil)
        XCTAssertTrue(general.contains("Review the diff for correctness bugs"))
    }

    func testCodeReviewPromptAddsTheLensOnlyForAPersona() {
        XCTAssertFalse(ClaudeReview.codeReviewPrompt(for: .sample).contains("particular perspective"))
        let security = ClaudeReview.codeReviewPrompt(for: .sample, persona: .security)
        XCTAssertTrue(security.hasPrefix("/code-review:code-review "))
        XCTAssertTrue(security.contains("application security engineer"))
    }

    func testCustomPersonasSaveAndAMissingOneFallsBackToGeneral() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "persona-test-\(UUID().uuidString)"))
        let mine = ReviewPersona(name: "Platform", lens: "Check the platform contracts.")
        ReviewPersona.saveCustom([mine], defaults)
        XCTAssertEqual(ReviewPersona.all(defaults).last, mine)
        XCTAssertEqual(ReviewPersona.named(mine.id, defaults), mine)
        XCTAssertEqual(ReviewPersona.named("gone", defaults), .general)
        XCTAssertFalse(mine.isBuiltIn)
        XCTAssertTrue(ReviewPersona.architect.isBuiltIn)
    }
}

final class ThreadTests: XCTestCase {
    private func comment(_ author: String) -> ReviewComment {
        ReviewComment(id: UUID().uuidString, databaseID: 1, author: author, authorAvatar: nil, body: "x", createdAt: .now, url: nil)
    }
    private func thread(_ authors: [String], resolved: Bool = false) -> ReviewThread {
        ReviewThread(id: "t", path: "a.swift", line: 3, originalLine: 3, side: .right, isResolved: resolved, isOutdated: false,
                     comments: authors.map(comment))
    }

    func testItIsYourTurnWhenSomeoneElseAnsweredLast() {
        XCTAssertTrue(thread(["me", "author"]).waitsOn("Me"))
        XCTAssertFalse(thread(["me", "author", "me"]).waitsOn("me"))
        XCTAssertFalse(thread(["me"]).waitsOn("me"))
        XCTAssertFalse(thread(["other", "author"]).waitsOn("me"), "not your thread")
        XCTAssertFalse(thread(["me", "author"], resolved: true).waitsOn("me"))
    }

    func testThreadCheckReadsStructuredOutput() throws {
        let envelope = #"{"type":"result","result":"It is fixed.","structured_output":{"addressed":"partly","assessment":"Null case still open.","reply":"Thanks! One more: the nil case.","resolve":false}}"#
        let check = try XCTUnwrap(ThreadCheck.parse("noise\n" + envelope))
        XCTAssertEqual(check.addressed, "partly")
        XCTAssertFalse(check.resolve)
        XCTAssertNil(ThreadCheck.parse(#"{"type":"result","result":"no schema"}"#))
    }
}

final class ReviewInboxTests: XCTestCase {
    func testParse() throws {
        let item = try XCTUnwrap(ReviewInbox.parse("pr: PR_1\npath: ./src/a.ts\nline: 42\nside: LEFT\n---\nUse a map here.\n\n---\nSecond paragraph.\n"))
        XCTAssertEqual(item.pullRequestID, "PR_1")
        XCTAssertEqual(item.comment.path, "src/a.ts")
        XCTAssertEqual(item.comment.line, 42)
        XCTAssertEqual(item.comment.side, .left)
        XCTAssertEqual(item.comment.body, "Use a map here.\n\n---\nSecond paragraph.")
        XCTAssertTrue(item.comment.fromClaude)
    }

    func testRejectsBadInput() {
        XCTAssertNil(ReviewInbox.parse("pr: PR_1\npath: a.ts\nline: x\n---\nbody"))
        XCTAssertNil(ReviewInbox.parse("pr: PR_1\npath: /etc/a\nline: 1\n---\nbody"))
        XCTAssertNil(ReviewInbox.parse("pr: PR_1\npath: a.ts\nline: 1\n---\n  \n"))
        XCTAssertNil(ReviewInbox.parse("path: a.ts\nline: 1\n---\nbody"))
    }

    func testHelperWritesWhatParseReads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-\(UUID().uuidString)'s")
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("gh-hub-comment-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: script) }
        try ReviewInbox.helperScript(inbox: dir.path).write(to: script, atomically: true, encoding: .utf8)

        func run(_ args: [String], stdin: String, pr: String? = "PR_9") throws -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path] + args
            var env = ProcessInfo.processInfo.environment
            env["GH_HUB_PR"] = pr
            p.environment = env
            let pipe = Pipe()
            p.standardInput = pipe
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            pipe.fileHandleForWriting.write(Data(stdin.utf8))
            try pipe.fileHandleForWriting.close()
            p.waitUntilExit()
            return p.terminationStatus
        }

        XCTAssertEqual(try run(["src/it's.ts", "7", "--old"], stdin: "Don't drop this check.\n`$HOME` stays literal.\n"), 0)
        XCTAssertNotEqual(try run(["a.ts", "seven"], stdin: "x"), 0)
        XCTAssertNotEqual(try run(["a.ts", "1"], stdin: "  \n"), 0)
        XCTAssertNotEqual(try run(["a.ts", "1"], stdin: "x", pr: nil), 0)

        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == ReviewInbox.fileExtension }
        XCTAssertEqual(files.count, 1)
        let item = try XCTUnwrap(ReviewInbox.parse(String(contentsOf: files[0], encoding: .utf8)))
        XCTAssertEqual(item.pullRequestID, "PR_9")
        XCTAssertEqual(item.comment.path, "src/it's.ts")
        XCTAssertEqual(item.comment.line, 7)
        XCTAssertEqual(item.comment.side, .left)
        XCTAssertEqual(item.comment.body, "Don't drop this check.\n`$HOME` stays literal.")
    }
}

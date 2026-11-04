# GH Hub

A native macOS app for the GitHub work that otherwise lives in browser tabs:
reviewing and approving pull requests, merging, and watching, re-running,
approving and starting GitHub Actions runs, across every account you are signed
in to with `gh`.

## Install

```bash
brew tap menico/tap
brew trust menico/tap        # Homebrew requires this for any third-party tap
brew install --cask gh-hub
```

GH Hub needs macOS 14 or later and the [GitHub CLI](https://cli.github.com)
signed in (`gh auth login`, once per account). Claude features need
[Claude Code](https://claude.com/claude-code); profiles come from
[cpx](https://github.com/menico/cpx) if you use it.

Update with `brew update && brew upgrade --cask gh-hub`.

## How it works

GH Hub never stores a credential. On launch it asks `gh auth status` which
accounts are signed in, gets each one's token with `gh auth token --user`, and
talks to the GitHub API directly. Every pull request and run is tagged with the
account that sees it (the coloured stripe), and actions are taken as that
account.

- **Review requests / My pull requests**: one GraphQL query per account. Rows
  show checks, review state, conflicts and size. The detail has the
  description, the full diff (lock files collapsed), and Approve (⇧⌘↩),
  Comment, Request changes and Merge (squash, merge or rebase).
- **Reviewing**: the diff takes comments on any line (hover, click +):
  publish one at once, or keep them pending and send them with Approve,
  Comment or Request changes. Existing review threads sit on their lines
  with Reply and Resolve; the conversation (comments and reviews) has its
  own card. The ⋯ menu enables auto-merge, updates the branch from base,
  marks ready or draft, and requests reviewers.
- **Review with Claude** (⇧⌘R): runs `claude -p` read-only over the diff,
  from your clone when there is one, as the account's Claude profile. You get
  a verdict, a summary, the risky spots and line comments; add them to your
  review one by one or all at once. Nothing is posted until you submit.
  Reviews are kept per pull request and say when the PR has moved on.
- **Issues**: open issues assigned to you or opened by you, with labels,
  assignees and comments. Each issue lists the pull requests that close or
  mention it, each pull request lists the issues it closes; a linked item GH Hub
  has loaded opens in place. Comment, close as completed or not planned.
  Assigned issues always show, like review requests.
- **Claude**: pull requests, issues and failed runs have a Claude card. It
  starts Claude Code (inside GH Hub in a terminal styled from your Ghostty
  config, or in Ghostty, Terminal or iTerm: Settings › Claude), in a worktree next to your clone
  (`<repo>-worktrees/pr-123`; cloned first if needed), with gh signed in as
  the right account and a prompt filled in: address review comments, fix
  failing checks (with the failed log), implement an issue on a new branch,
  or fix a failed run. The profile is the one cpx bound to the clone, or one
  chosen per account in Settings › Claude. The card also lists local Claude
  sessions that ran on that branch, from any profile, with Resume; list rows
  that have one carry a ✦.
- **Claude pane**: terminals running in GH Hub, sessions working right now (a
  pulsing dot, also on list rows), recent sessions with Resume, and the
  worktrees GH Hub made with what became of their pull requests. Clean up
  removes the merged or closed ones with no local changes. Folders open in
  your editor (VS Code, Cursor, Zed, Xcode…).
- **Quick open** (⌘K, or ⌃⌥H from anywhere): jump to any pull request, issue,
  run, repository or Claude session, or paste a GitHub link to open it here.
- **Actions**: runs from each account's repositories (recently pushed, or its
  selection) and from repositories with your open pull requests. A failed run opens on the
  tail of its failed job's log. Re-run failed, re-run all, cancel.
  A running run updates its steps every five seconds; Notify when done.
- **Awaiting approval**: runs blocked on an environment reviewer, with Approve
  and Reject.
- **Run workflow** (⇧⌘N): pick a repository, see each `workflow_dispatch`
  workflow, and fill in its inputs in a form.
- **Account tabs**: All, or one account at a time (⌥⌘0, ⌥⌘1…). Right-click a
  tab to rename it, hide it, or choose its repositories.
- **Repositories per account**: each account follows either its recent
  activity or only the repositories you select (Settings › Accounts, or the
  tab's menu). A limited account shows your pull requests, runs and workflows from
  those repositories only; review requests always show.
- **Menu bar**: what needs you right now; notifications for new review
  requests, your failed runs and pending approvals.

## Build

```bash
make test      # HubKit unit tests
make app       # build/GH Hub.app, ad-hoc signed
make install   # copy to /Applications
make probe     # fetch once from the terminal and print a summary
```

`HUB_DEV_SELECT=pr|run|issue|linkedpr|focus|claude|claudepane|terminal|pr=owner/repo#n "build/GH Hub.app/Contents/MacOS/gh-hub"` opens straight
onto a detail screen. `swift scripts/make-icon.swift` re-renders the icon.

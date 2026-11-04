import Foundation
import HubKit

/// Makes a Claude review read-only for real, whatever permissions Claude
/// applies: `gh` and `git` wrappers go first on PATH and refuse anything
/// that writes to GitHub or changes the checkout.
enum ReviewGuard {
    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.menico.gh-hub/review-guard/bin", isDirectory: true)
    }

    /// The environment with the wrappers in front; nil if they couldn't be written.
    static func environment(_ base: [String: String]) -> [String: String] {
        let path = base["PATH"] ?? "/usr/bin:/bin"
        guard let gh = find("gh", in: path), let git = find("git", in: path) else { return base }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try write("gh", ghScript(real: gh))
            try write("git", gitScript(real: git))
        } catch { return base }
        var env = base
        env["PATH"] = folder.path + ":" + path
        return env
    }

    private static func find(_ tool: String, in path: String) -> String? {
        path.split(separator: ":").map { "\($0)/\(tool)" }
            .first { $0.hasPrefix(folder.path) == false && FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func write(_ name: String, _ script: String) throws {
        let file = folder.appendingPathComponent(name)
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    static func ghScript(real: String) -> String {
        """
        #!/bin/bash
        # Written by Hub: gh, read-only, for the length of a Claude review.
        deny() { echo "GH Hub blocked this during a read-only review: gh $*" >&2; exit 1; }
        case "$1 $2" in
          "pr comment"*|"pr review"*|"pr merge"*|"pr close"*|"pr edit"*|"pr create"*|"pr ready"*|"pr reopen"*|"pr lock"*|\\
          "issue comment"*|"issue create"*|"issue edit"*|"issue close"*|"issue reopen"*|"issue delete"*|"issue transfer"*|\\
          "repo "*|"release "*|"workflow run"*|"workflow enable"*|"workflow disable"*|"run rerun"*|"run cancel"*|"run delete"*|\\
          "secret "*|"variable "*|"label "*|"gist "*|"cache delete"*|"ruleset "*|"auth "*)
            deny "$@" ;;
        esac
        if [ "$1" = "api" ]; then
          method=""; fields=0; gql=0; all=""; prev=""
          for a in "$@"; do
            case "$prev" in -X|--method) method="$a" ;; esac
            case "$a" in
              -X?*) method="${a#-X}" ;;
              --method=*) method="${a#--method=}" ;;
              -f|-F|--field|--raw-field|--input|-f?*|-F?*|--field=*|--raw-field=*|--input=*) fields=1 ;;
              graphql) gql=1 ;;
            esac
            all="$all $a"; prev="$a"
          done
          m=$(printf %s "$method" | tr '[:lower:]' '[:upper:]')
          if [ "$gql" = 1 ]; then
            printf %s "$all" | grep -qi "mutation" && deny "$@"
          elif [ -n "$m" ] && [ "$m" != GET ] && [ "$m" != HEAD ]; then
            deny "$@"
          elif [ -z "$m" ] && [ "$fields" = 1 ]; then
            deny "$@"
          fi
        fi
        exec \(Shell.quote(real)) "$@"
        """
    }

    static func gitScript(real: String) -> String {
        """
        #!/bin/bash
        # Written by Hub: git without pushing or changing the checkout, for the length of a Claude review.
        # The subcommand is the first word that is neither an option nor an option's value (git -C dir commit).
        sub=""; skip=0
        for a in "$@"; do
          if [ "$skip" = 1 ]; then skip=0; continue; fi
          case "$a" in
            -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--config-env) skip=1 ;;
            -*) ;;
            *) sub="$a"; break ;;
          esac
        done
        case "$sub" in
          push|commit|merge|rebase|reset|clean|stash|checkout|switch|restore|am|apply|cherry-pick|revert|tag|rm|mv|worktree|submodule)
            echo "GH Hub blocked this during a read-only review: git $*" >&2; exit 1 ;;
        esac
        exec \(Shell.quote(real)) "$@"
        """
    }
}

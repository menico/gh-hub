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
              # A body read from a file (--input, field=@file) can't be checked: refuse it.
              --input|--input=*|*=@*) deny "$@" ;;
              -f|-F|--field|--raw-field|-f?*|-F?*|--field=*|--raw-field=*) fields=1 ;;
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
        deny() { echo "GH Hub blocked this during a read-only review: git $*" >&2; exit 1; }
        # Config from the command line can define aliases, pagers or ssh commands that run programs.
        for a in "$@"; do
          case "$a" in
            -c|-c?*|--config-env|--config-env=*|--exec-path|--exec-path=*) deny "$@" ;;
            --output|--output=*|--ext-diff|-O|-O?*|--open-files-in-pager|--open-files-in-pager=*) deny "$@" ;;
          esac
        done
        # The arguments after the subcommand, and how many are not options.
        rest=(); seen=0
        for a in "$@"; do
          if [ "$seen" = 1 ]; then rest+=("$a"); elif [ "$a" = "$sub" ]; then seen=1; fi
        done
        # Options such as --contains take the next word as their value; it isn't a name.
        words=0; prev=""
        for a in "${rest[@]}"; do
          case "$prev" in --contains|--no-contains|--merged|--no-merged|--points-at|--sort|--format) prev=""; continue ;; esac
          case "$a" in -*) ;; *) words=$((words+1)) ;; esac
          prev="$a"
        done
        # Read-only commands only; anything else is refused.
        case "$sub" in
          status|log|show|diff|grep|blame|annotate|ls-files|ls-tree|rev-parse|rev-list|cat-file|describe|shortlog|merge-base|name-rev|for-each-ref|show-ref|whatchanged|range-diff|cherry|count-objects|version|help|"") ;;
          # Listing only: no names (which would create, rename or move), unless it is --list with a pattern.
          branch|tag)
            list=0; for a in "${rest[@]}"; do case "$a" in -l|--list) list=1 ;; esac; done
            for a in "${rest[@]}"; do
              case "$a" in
                -a|--all|-r|--remotes|-v|-vv|--verbose|-l|--list|--show-current|--contains*|--no-contains*|--merged*|--no-merged*|--points-at*|--sort=*|--format=*|--column*|--no-column|--color*|--no-color|-n*) ;;
                -*) deny "$@" ;;
              esac
            done
            [ "$words" -gt 0 ] && [ "$list" = 0 ] && deny "$@" ;;
          remote)
            case "${rest[0]:-}" in ""|-v|--verbose|get-url|show) ;; *) deny "$@" ;; esac ;;
          # Reading a value: the first argument is the read action, and nothing that could be a value follows.
          config)
            # git runs one action at a time, so a read action first makes the whole call a read.
            case "${rest[0]:-}" in --get|--get-all|--get-regexp|get|--list|-l|list) ;; *) deny "$@" ;; esac
            for a in "${rest[@]:1}"; do
              case "$a" in --get*|--list|-l|--name-only|--null|-z|--show-origin|--show-scope|--global|--local|--system|--includes|--default=*|--type=*|--bool|--int|--path) ;; -*) deny "$@" ;; esac
            done ;;
          *) deny "$@" ;;
        esac
        exec \(Shell.quote(real)) "$@"
        """
    }
}

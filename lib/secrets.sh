#!/bin/bash
# The deny-list scanner (docs/DESIGN.md §6).
#
# It blocks the push. It does not warn. §6 is explicit about why: a leak is
# irreversible, and "it warns" is the exact failure mode of lesson #1 -- a
# warning nobody reads. That reasoning got stronger once push became an
# unattended hourly timer: there is nobody there at 03:00 to read anything.
#
# Scope is every commit reachable from every ref, not HEAD. The first version
# scanned `git grep HEAD` while the bundle ships `git bundle --all HEAD`, so a
# key committed once and deleted in the next commit reported clean and left the
# machine anyway. A secret is in the artifact from the moment it is committed;
# deleting the file does not take it back out.
#
# Patterns are deliberately high-signal -- shapes that are a credential or
# nothing. One that fires on ordinary config teaches you to reach for --force,
# which is the same failure one step later, so the false-positive specs matter
# as much as the detection ones.
#
# Everything here fails closed. A missing deny-list, unparseable JSON or a regex
# git rejects used to produce no output, which is indistinguishable from finding
# nothing, and the push went out. A gate that cannot run is not a gate.

KNOWN_DENY_FIELDS='["id","regex","reason","ignoreCase"]'
KNOWN_EXCEPTION_FIELDS='["id","match","reason"]'

# Same invariant as the group manifest: a rule declared and silently ignored is
# worse than no rule, because it reads as protection.
assert_deny_understood() {
    local file="$1" bad line
    [[ -f "$file" ]] \
        || die "no deny-list at $(_tilde "$file"): refusing to push without a secret scan (docs/DESIGN.md §6)"
    jq -e . "$file" >/dev/null 2>&1 \
        || die "the deny-list at $(_tilde "$file") is not valid JSON: refusing to push unscanned"
    bad="$(jq -r --argjson p "$KNOWN_DENY_FIELDS" --argjson e "$KNOWN_EXCEPTION_FIELDS" '
        [ ((.patterns // [])[] | . as $r | (keys[] | select(. as $f | $p | index($f) | not))
            | "unknown field \(.) in pattern \($r.id // "?")")
        , ((.patterns // [])[] | select((.id // "") == "" or (.regex // "") == "")
            | "a pattern needs both id and regex")
        , ((.patterns // [])[] | select((.reason // "") == "")
            | "pattern \(.id) has no reason: a rule nobody can justify is a rule somebody forces past")
        , ((.exceptions // [])[] | . as $r | (keys[] | select(. as $f | $e | index($f) | not))
            | "unknown field \(.) in exception \($r.id // "?")")
        , ((.exceptions // [])[] | select((.match // "") == "" or (.reason // "") == "")
            | "exception \(.id // "?") needs both match and reason")
        ] | .[]' "$file" 2>/dev/null)"
    [[ -z "$bad" ]] && return 0
    printf '%somabackup: the deny-list declares what the scanner cannot honor:%s\n' "$RED" "$NC" >&2
    while IFS= read -r line; do printf '  %s\n' "$line" >&2; done <<<"$bad"
    exit 1
}

# _still_matches <line> <regex> <ignore-case>
# An exception explains one phrase; it does not clear the line it sits on. The
# excepted substrings are cut out and the pattern is retried against what is
# left, so `hide_token_restore` beside an AWS key no longer swallows the key.
_still_matches() {
    local line="$1" re="$2" ci="$3" ex
    for ex in "${DENY_EXCEPTIONS[@]:-}"; do
        [[ -n "$ex" ]] || continue
        line="${line//"$ex"/ }"
    done
    if [[ "$ci" == true ]]; then
        printf '%s' "$line" | grep -qiE -e "$re"
    else
        printf '%s' "$line" | grep -qE -e "$re"
    fi
}

# scan_secrets <repo> <deny-file>
# Prints `<rule-id>\t<commit>:<file>:<line>:<text>` per hit, nothing when clean.
# Returns non-zero if the scan itself could not be carried out.
scan_secrets() {
    local repo="$1" file="$2" id re ci hit rc=0
    [[ -f "$file" ]] || return 1

    DENY_EXCEPTIONS=()
    mapfile -t DENY_EXCEPTIONS < <(jq -r '(.exceptions // [])[].match' "$file" 2>/dev/null)

    # Every reachable commit, because that is exactly what `git bundle --all`
    # packs.
    #
    # The exit status is the whole point here. rev-list exits 0 with no output
    # for a repository that has no commits and 128 for one git cannot read, and
    # reading it through `mapfile < <(...)` threw that away -- so a broken repo
    # became "nothing to scan", became "clean", became a push. Empty output with
    # a zero exit is genuinely an empty repo and scans clean; a non-zero exit
    # refuses.
    local revlist revrc
    revlist="$(git -C "$repo" rev-list --all 2>/dev/null)"; revrc=$?
    if (( revrc != 0 )); then
        printf '%somabackup: cannot list commits in %s -- refusing to call it clean%s\n' \
            "$RED" "$(_tilde "$repo")" "$NC" >&2
        return 1
    fi
    [[ -n "$revlist" ]] || return 0
    local -a revs=()
    mapfile -t revs <<<"$revlist"

    # Read with its status checked, and refused when it yields nothing. jq used to
    # run inside a process substitution, so an unreadable deny-list produced zero
    # patterns, the loop never ran, and the function returned success -- a clean
    # bill of health from a rule set it could not read. cmd_push validates first,
    # but a scanner must not depend on its caller having been careful.
    local patterns
    patterns="$(jq -r '(.patterns // [])[] | "\(.id)\t\(.regex)\t\(.ignoreCase // false)"' \
                "$file" 2>/dev/null)" || return 1
    if [[ -z "$patterns" ]]; then
        printf '%somabackup: the deny-list yielded no patterns -- refusing to call this clean%s\n' \
            "$RED" "$NC" >&2
        return 1
    fi

    while IFS=$'\t' read -r id re ci; do
        [[ -n "$id" && -n "$re" ]] || continue
        # Per pattern, not globally: `git grep -E` is POSIX ERE with no inline
        # (?i), and -i everywhere would make AKIA match "akia" in prose.
        local -a gflags=(-I -n -E)
        [[ "$ci" == true ]] && gflags+=(-i)
        local out grc
        out="$(git -C "$repo" grep "${gflags[@]}" -e "$re" "${revs[@]}" 2>&1)"; grc=$?
        # git grep: 0 found, 1 nothing found, anything else is a broken pattern
        # or a broken repo -- and must never read as "clean".
        if (( grc > 1 )); then
            printf '%somabackup: pattern %s could not be scanned: %s%s\n' \
                "$RED" "$id" "$(printf '%s' "$out" | head -1)" "$NC" >&2
            rc=1
            continue
        fi
        while IFS= read -r hit; do
            [[ -n "$hit" ]] || continue
            _still_matches "$hit" "$re" "$ci" || continue
            printf '%s\t%s\n' "$id" "$hit"
        done <<<"$out"

        # `git grep <rev>` reads the tree at that commit and nothing else, but
        # `git bundle --all` packs the commit objects and the annotated tag
        # objects too -- so a token pasted into a commit message shipped and
        # scanned clean. Messages and tag bodies are text that leaves the
        # machine; they get the same patterns.
        local msgs
        msgs="$(git -C "$repo" log --format='%H%n%B' --all 2>/dev/null
                git -C "$repo" for-each-ref --format='%(refname) %(contents)' refs/tags 2>/dev/null)"
        while IFS= read -r hit; do
            [[ -n "$hit" ]] || continue
            _still_matches "$hit" "$re" "$ci" || continue
            printf '%s\tcommit-message: %s\n' "$id" "$hit"
        done < <(if [[ "$ci" == true ]]; then printf '%s' "$msgs" | grep -iE -e "$re"
                 else printf '%s' "$msgs" | grep -E -e "$re"; fi)
    done <<<"$patterns"
    return $rc
}

# Prints the report and returns non-zero when anything was found OR when the
# scan could not run. Both are reasons not to send.
report_secrets() {  # report_secrets <repo> <deny-file>
    local hits id rest rc=0
    hits="$(scan_secrets "$1" "$2")" || rc=1
    if (( rc )); then
        printf '%somabackup: push blocked -- the secret scan could not complete%s\n' "$RED" "$NC" >&2
        printf '  A gate that cannot run is not a gate (docs/DESIGN.md §6).\n' >&2
        return 1
    fi
    [[ -n "$hits" ]] || return 0

    printf '%somabackup: push blocked -- the deny-list matched what is about to leave this machine%s\n' \
        "$RED" "$NC" >&2
    while IFS=$'\t' read -r id rest; do
        [[ -n "$id" ]] || continue
        printf '  %s%s%s  %s\n' "$YELLOW" "$id" "$NC" "$(printf '%s' "$rest" | head -c 160)" >&2
    done <<<"$hits"
    printf '\n  A leak is irreversible, so this blocks rather than warns (docs/DESIGN.md §6).\n' >&2
    printf '  This scans every reachable commit: deleting the file does not remove it\n' >&2
    printf '  from history. Rewrite the history, or add a justified entry to %s.\n' \
        "$(_tilde "$SECRETS_DENY_FILE")" >&2
    return 1
}

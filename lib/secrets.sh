#!/bin/bash
# The deny-list scanner (docs/DESIGN.md §6).
#
# It blocks the push. It does not warn. §6 is explicit about why: a leak is
# irreversible, and "it warns" is the exact failure mode of lesson #1 -- a
# warning nobody reads. That reasoning got stronger once push became an
# unattended hourly timer: there is nobody there at 03:00 to read anything.
#
# Scanned with `git grep` against HEAD rather than the working tree, because
# HEAD is precisely what both destinations send: `git push` sends the commit,
# and the bundle's readable half is `git archive HEAD`. Scanning the working
# tree would check content that is not leaving and miss content that is.
#
# Patterns are deliberately high-signal -- shapes that are a credential or
# nothing. One that fires on ordinary config teaches you to reach for --force,
# which is the same failure one step later, so the false-positive specs matter
# as much as the detection ones.

KNOWN_DENY_FIELDS='["id","regex","reason","ignoreCase"]'
KNOWN_EXCEPTION_FIELDS='["id","match","reason"]'

# Same invariant as the group manifest: a rule declared and silently ignored is
# worse than no rule, because it reads as protection.
assert_deny_understood() {
    local file="$1" bad line
    [[ -f "$file" ]] || return 0
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

# scan_secrets <repo> <deny-file>
# Prints one `<rule-id>\t<file>:<line>\t<text>` per hit, nothing when clean.
scan_secrets() {
    local repo="$1" file="$2" id re hit line
    [[ -f "$file" ]] || return 0

    local -a exceptions=()
    mapfile -t exceptions < <(jq -r '(.exceptions // [])[].match' "$file" 2>/dev/null)

    while IFS=$'\t' read -r id re ci; do
        [[ -n "$id" && -n "$re" ]] || continue
        # Per pattern, not globally: `git grep -E` is POSIX ERE and has no inline
        # (?i), and turning -i on for everything would make AKIA match "akia" in
        # prose. Declared in the rule, so the rule says what it means.
        local -a gflags=(-I -n -E)
        [[ "$ci" == true ]] && gflags+=(-i)
        # -I skips binary; -n gives the line; HEAD scopes it to what is committed.
        while IFS= read -r hit; do
            [[ -n "$hit" ]] || continue
            # `git grep HEAD` prefixes matches with `HEAD:`; drop it so the path
            # reads the way the user knows it.
            hit="${hit#HEAD:}"
            local excepted=0 ex
            for ex in "${exceptions[@]:-}"; do
                [[ -n "$ex" ]] || continue
                [[ "$hit" == *"$ex"* ]] && { excepted=1; break; }
            done
            (( excepted )) && continue
            printf '%s\t%s\n' "$id" "$hit"
        done < <(git -C "$repo" grep "${gflags[@]}" -e "$re" HEAD 2>/dev/null)
    done < <(jq -r '(.patterns // [])[] | "\(.id)\t\(.regex)\t\(.ignoreCase // false)"' "$file" 2>/dev/null)
}

# Prints the report and returns non-zero when anything was found.
report_secrets() {  # report_secrets <repo> <deny-file>
    local hits id rest
    hits="$(scan_secrets "$1" "$2")"
    [[ -n "$hits" ]] || return 0

    printf '%somabackup: push blocked -- the deny-list matched what is about to leave this machine%s\n' \
        "$RED" "$NC" >&2
    while IFS=$'\t' read -r id rest; do
        [[ -n "$id" ]] || continue
        printf '  %s%s%s  %s\n' "$YELLOW" "$id" "$NC" "$(printf '%s' "$rest" | head -c 160)" >&2
    done <<<"$hits"
    printf '\n  A leak is irreversible, so this blocks rather than warns (docs/DESIGN.md §6).\n' >&2
    printf '  Remove the credential, or add a justified entry to %s.\n' \
        "$(_tilde "$SECRETS_DENY_FILE")" >&2
    return 1
}

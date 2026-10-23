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
    # The second argument names what is being refused; it used to be "push"
    # everywhere, which read wrong once sync called this too.
    local file="$1" what="${2:-push}" bad line
    [[ -f "$file" ]] \
        || die "no deny-list at $(_tilde "$file"): refusing to $what without a secret scan (docs/DESIGN.md §6)"
    jq -e . "$file" >/dev/null 2>&1 \
        || die "the deny-list at $(_tilde "$file") is not valid JSON: refusing to $what unscanned"
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
        ] | .[]' "$file" 2>/dev/null)" \
        || die "the deny-list at $(_tilde "$file") could not be read: refusing to $what unscanned"
    # There is deliberately no rule against an exception that matches a pattern.
    # That guard existed for the old cut-and-retest semantics, where an
    # exception overlapping a secret erased it. With equality an exception
    # excuses only the identical string, which is the entire point -- and
    # keeping both rules made every exception impossible: unreachable ones are
    # refused below, and matching ones would have been refused here.

    # An exception no pattern can produce is not protection: it reads as "we
    # handle this false positive" while the false positive cannot occur. All
    # three shipped exceptions turned out to be exactly that -- the patterns
    # were precise enough never to fire on the lines they excused.
    #
    # Reachable means a pattern produces EXACTLY this text, which is what
    # _still_matches then requires. Asking it as containment -- does some
    # pattern match anywhere inside the exception -- accepted exceptions that
    # could never apply: "--password-store=gnome-libsecret" contains a match for
    # `password-store=[a-z-]+`, so validation passed it, while at scan time the
    # extracted match is the substring and equality fails. Two halves of one
    # rule meaning two different things, which is the shape of half the defects
    # in this file.
    # A regex that can match the empty string matches every line and hands
    # grep -o nothing to print -- and "nothing to print" read as "nothing
    # found". "^" is the short way to write it: live in the deny-list, matching
    # every line in the repository, reporting none of them. Asked of bash's own
    # ERE rather than of grep -o, whose handling of a zero-width match turned
    # out to vary between invocations on this machine; a detector must not rest
    # on that. An expression bash cannot compile is refused in the same breath.
    #
    # The probe is the empty string, which is the question being asked. Probing
    # with "a" answered a narrower one: "a?" matches "a" with content and so
    # looked healthy, while on any line without an "a" it matches nothing at
    # all -- zero-width for most of the repository.
    # Every jq query below, captured into a variable and checked before
    # looping over it via <<< -- not fed straight into `while read < <(jq
    # ...)`. A process substitution's own exit status has no `$?` a
    # caller can check directly, and this file's inner loops start their
    # OWN nested substitutions (mapfile < <(... | grep ...) a few lines
    # down), which would clobber `$!` before a `wait "$!"` after `done`
    # ever got to see the right PID. A PoC (jq stubbed to fail only on
    # this exact query) confirmed the gap this closes: a deny-list
    # pattern "^" -- matches every line, reports none, exactly the
    # zero-width case this loop exists to refuse -- passed
    # assert_deny_understood silently, rc=0, when the query meant to
    # catch it failed to run at all. This file's own header promises
    # "everything here fails closed"; this loop was the one place that
    # wasn't.
    local pid3 pre3 zwrc pats
    pats="$(jq -r '(.patterns // [])[] | "\(.id)\t\(.regex)"' "$file" 2>/dev/null)" \
        || die "the deny-list at $(_tilde "$file") could not be read: refusing to $what unscanned"
    while IFS=$'\t' read -r pid3 pre3; do
        [[ -n "$pid3" && -n "$pre3" ]] || continue
        ( [[ "" =~ $pre3 ]] ) 2>/dev/null; zwrc=$?
        if (( zwrc == 2 )); then
            bad="${bad:+$bad$'\n'}pattern $pid3 is not a regular expression this scanner can compile"
        elif (( zwrc == 0 )) \
          && [[ -z "$( [[ "" =~ $pre3 ]] 2>/dev/null; printf '%s' "${BASH_REMATCH[0]}" )" ]]; then
            bad="${bad:+$bad$'\n'}pattern $pid3 can match the empty string: it would match every line and report none"
        fi
    done <<<"$pats"

    local exid2 exm2 reach pats2 excs
    pats2="$(jq -r '(.patterns // [])[] | "\(.id)\t\(.regex)\t\(.ignoreCase // false)"' "$file" 2>/dev/null)" \
        || die "the deny-list at $(_tilde "$file") could not be read: refusing to $what unscanned"
    excs="$(jq -r '(.exceptions // [])[] | "\(.id)\t\(.match)"' "$file" 2>/dev/null)" \
        || die "the deny-list at $(_tilde "$file") could not be read: refusing to $what unscanned"
    while IFS=$'\t' read -r exid2 exm2; do
        [[ -n "$exm2" ]] || continue
        reach=0
        while IFS=$'\t' read -r pid pre pci; do
            [[ -n "$pid" && -n "$pre" ]] || continue
            local -a hits=(); local hit
            if [[ "$pci" == true ]]; then
                mapfile -t hits < <(printf '%s' "$exm2" | grep -oiE -e "$pre")
            else
                mapfile -t hits < <(printf '%s' "$exm2" | grep -oE -e "$pre")
            fi
            for hit in "${hits[@]:-}"; do
                [[ -n "$hit" ]] || continue
                if [[ "$pci" == true ]]; then [[ "${hit,,}" == "${exm2,,}" ]] && { reach=1; break; }
                else [[ "$hit" == "$exm2" ]] && { reach=1; break; }; fi
            done
            (( reach )) && break
        done <<<"$pats2"
        (( reach )) || bad="${bad:+$bad$'\n'}exception $exid2 is unreachable: no pattern produces exactly this text"
    done <<<"$excs"

    [[ -z "$bad" ]] && return 0
    printf '%somabackup: the deny-list declares what the scanner cannot honor:%s\n' "$RED" "$NC" >&2
    while IFS= read -r line; do printf '  %s\n' "$line" >&2; done <<<"$bad"
    exit 1
}

# _still_matches <line> <regex> <ignore-case>
# True when the line carries a match no exception explains.
#
# An exception EXCUSES a match; it does not edit the line. The first version cut
# excepted text out and retested what was left, and a four-character exception
# then bypassed the scanner completely: "AKIA" does not itself match
# `\bAKIA[0-9A-Z]{16}\b`, so validation accepted it, and removing "AKIA" from
# the line destroyed the key. One innocuous line in a JSON file turned a
# detector off. Two short exceptions could do it between them.
#
# So the test is equality: a match is excused only when some exception IS that
# exact matched text. Containment was the first answer and had the same hole one
# size up -- "exemploAKIA...fim" contains the key, so it excused the key
# everywhere. assert_deny_understood checks reachability the same way, so an
# exception that validates is an exception that can fire.
_still_matches() {
    local line="$1" re="$2" ci="$3" m ex excused
    # grep's status is read, not just its output. Through a process
    # substitution "no matches" and "I could not run" arrived as the same empty
    # array, and a grep that errored on both halves of this function answered
    # "clean" for a line carrying a key. A pattern this function cannot apply is
    # a question it cannot answer, and the answer it must not give is "clean".
    local raw orc
    local -a matches=()
    if [[ "$ci" == true ]]; then raw="$(printf '%s' "$line" | grep -oiE -e "$re")"
    else raw="$(printf '%s' "$line" | grep -oE -e "$re")"; fi
    orc=$?
    if (( orc > 1 )); then
        printf '%somabackup: could not apply a pattern to a line (grep exited %s) -- calling it a hit%s\n' \
            "$RED" "$orc" "$NC" >&2
        return 0
    fi
    mapfile -t matches <<<"$raw"
    # A match the extraction could not produce is not an absence of secrets.
    # With a zero-width pattern grep -o prints nothing, the array comes back
    # empty, and this returned "clean" for a line the pattern had matched.
    # assert_deny_understood refuses such patterns now; this is the second lock,
    # because the scanner must not depend on its caller having validated.
    local any=0 probe
    for probe in "${matches[@]:-}"; do [[ -n "$probe" ]] && { any=1; break; }; done
    if (( ! any )); then
        local qrc
        if [[ "$ci" == true ]]; then printf '%s' "$line" | grep -qiE -e "$re"
        else printf '%s' "$line" | grep -qE -e "$re"; fi
        qrc=$?
        (( qrc == 0 )) && return 0
        if (( qrc > 1 )); then
            printf '%somabackup: could not re-test a line (grep exited %s) -- calling it a hit%s\n' \
                "$RED" "$qrc" "$NC" >&2
            return 0
        fi
        return 1
    fi

    local mm
    for m in "${matches[@]}"; do
        [[ -n "$m" ]] || continue
        excused=0
        # Equality, not containment. Containment let an exception excuse a
        # secret it merely enclosed: "exemploAKIA...fim" contains the key, so
        # the key was excused wherever it appeared -- the same class as the
        # four-character bypass, needing only a longer string. An exception
        # must BE the thing it explains.
        #
        # Compared the way the rule reads: declaring ignoreCase and then
        # matching exceptions case-sensitively made a rule mean two different
        # things in its two halves.
        mm="$m"
        [[ "$ci" == true ]] && mm="${m,,}"
        for ex in "${DENY_EXCEPTIONS[@]:-}"; do
            [[ -n "$ex" ]] || continue
            if [[ "$ci" == true ]]; then
                [[ "${ex,,}" == "$mm" ]] && { excused=1; break; }
            else
                [[ "$ex" == "$m" ]] && { excused=1; break; }
            fi
        done
        (( excused )) || return 0
    done
    return 1
}

# scan_secrets <repo> <deny-file>
# Prints `<rule-id>\t<where>\t<commit>:<file>:<line>:<text>` per hit, nothing
# when clean. <where> is safe to print: it never holds the matched text, nor a
# name a rule matches. The third field is the evidence and is never printed.
# Returns non-zero if the scan itself could not be carried out.
scan_secrets() {
    local repo="$1" file="$2" id re ci hit rc=0
    [[ -f "$file" ]] || return 1

    # Bytes, not characters: under a UTF-8 locale an invalid byte right before
    # a token hid it from git grep and from bash's =~ alike, and this push
    # gate called a history holding a token clean. The systemd user manager
    # runs with LANG=en_US.UTF-8 (review omabackup-73, measured).
    local LC_ALL=C; export LC_ALL

    # Replacements off, for every git command below. `git replace` rewrites what
    # git SHOWS you: point refs/replace/<oid> at a clean commit and rev-list,
    # log, grep and cat-file all hand you the clean one. `git bundle` is a pack
    # transfer and hands over the original -- so the half that checks and the
    # half that packs were reading two different repositories, and a key behind
    # a replacement scanned clean and then came back out of a clone of the
    # bundle in plain text. The refs under refs/replace are themselves reachable
    # and get scanned like any others, so both objects are covered.
    local GIT_NO_REPLACE_OBJECTS=1
    export GIT_NO_REPLACE_OBJECTS

    # `local` here, not a bare global: bash scopes dynamically, so _still_matches
    # still sees it, and nothing survives the call to collide with a later one.
    local -a DENY_EXCEPTIONS=()
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

    # `git grep <rev>` reads the tree at that commit and nothing else, but
    # `git bundle --all` packs the commit objects and the annotated tag objects
    # too -- so a token pasted into a commit message shipped and scanned clean.
    #
    # Collected once, before the pattern loop, and with both statuses checked.
    # The first version read them through an unchecked pipeline inside the loop:
    # a git that failed produced an empty string, every pattern then found
    # nothing in that empty string, and the scan reported clean with status 0.
    # A history we could not read is not a history without secrets -- the same
    # fail-open already closed for rev-list and for the deny-list itself.
    #
    # Each line carries its own commit. The first version concatenated every
    # message into one blob with %H%n%B, which lost the attribution entirely
    # (a hit named no commit, and the fix for a message is rewriting history --
    # you cannot rewrite what you cannot locate) and let a match span the seam
    # between one message and the next.
    local revlist revrc
    revlist="$(git -C "$repo" rev-list --all 2>/dev/null)"; revrc=$?
    if (( revrc != 0 )); then
        printf '%somabackup: cannot list commits in %s -- refusing to call it clean%s\n' \
            "$RED" "$(_tilde "$repo")" "$NC" >&2
        return 1
    fi
    # No early return here. A repository with no commits used to leave at this
    # point, which skipped the deny-list check below and skipped the tags -- a
    # tag can name a blob, and a deny-list nobody could read was reported as a
    # clean scan. An empty commit list simply means there are no trees to grep.
    local -a revs=()
    [[ -n "$revlist" ]] && mapfile -t revs <<<"$revlist"

    local pairs prc trefs tref tbody tl pline msgs
    # The raw commit object, every line of it. Reading it through --format
    # meant naming in advance each field worth scanning -- %B, then %an and %ae
    # and %cn and %ce when those turned out to ship too -- and a commit header
    # holds more than the placeholders expose: mergetag carries an entire tag
    # object inside a merge commit, and it survives the tag being deleted.
    # Enumerating what to read is how a gate acquires blind spots; this reads
    # the object.
    #
    # Framed by cat-file's own header line rather than by a separator chosen
    # from the message's own alphabet. \x01 could appear in a message, and one
    # that held it split into a record with no sha in front, which the previous
    # version dropped outright -- a key after that byte was never scanned. A
    # content line that happens to look like a header would misattribute, which
    # is a wrong name on a finding rather than a finding that never appears.
    #
    # Not --pretty=raw, which indents the message by four spaces: that is the
    # same decoration defect as git grep's, and an anchored pattern would miss
    # a key sitting on its own line.
    # pipefail is asked for here rather than assumed. bin/omabackup sets it,
    # but this library is sourced directly by the specs and by anything else
    # that cares to, and without it the pipeline reported awk's status: a git
    # that could not read the log became "no messages", became clean.
    local _had_pipefail=0; [[ -o pipefail ]] && _had_pipefail=1
    set -o pipefail
    pairs="$(git -C "$repo" rev-list --all 2>/dev/null \
             | git -C "$repo" cat-file --batch 2>/dev/null \
             | awk '/^[0-9a-f]{40} commit [0-9]+$/ { last = "commit:" substr($1, 1, 12); next }
                    { if ($0 != "") print (last == "" ? "commit:?" : last) "\t" $0 }')"; prc=$?
    (( _had_pipefail )) || set +o pipefail
    if (( prc != 0 )); then
        printf '%somabackup: cannot read the commit objects of %s -- refusing to call it clean%s\n' \
            "$RED" "$(_tilde "$repo")" "$NC" >&2
        return 1
    fi

    # Command substitution strips the trailing newline, so appending the tags
    # straight onto this glued the first of them to the last message line.
    pairs="${pairs:+$pairs$'\n'}"

    # One pass over every ref, answered by kind.
    #
    # Tags were read from refs/tags alone, so an annotated tag anywhere else --
    # refs/releases/x is a real convention -- had its message scanned by
    # nobody. And "%(refname:short) %(contents)" put the tag name in front of
    # the body's first line, so an anchored pattern could not match a secret
    # that occupied it: git grep's decoration defect, in another stream.
    #
    # `git bundle --all` packs every ref and a ref is free to name a blob:
    # rev-list lists commits, git grep reads the trees of commits, and a blob
    # hanging off a tag belongs to neither. It shipped, and it scanned clean --
    # cloning the bundle handed the key straight back. A tag object is peeled,
    # so an annotated tag pointing at a blob is caught as well; a ref naming a
    # tree is handed to git grep, which takes a tree-ish of any kind.
    #
    # The refname itself is scanned too. It is text, it is packed, and it
    # leaves this machine -- which is the whole of what this gate is for.
    local reflist rtype robj rname bl bline
    local -A seenref=()
    reflist="$(git -C "$repo" for-each-ref \
        --format='%(objecttype) %(objectname) %(refname)%0a%(*objecttype) %(*objectname) %(refname)' \
        2>/dev/null)" \
        || { printf '%somabackup: cannot list the refs of %s -- refusing to call it clean%s\n' \
                 "$RED" "$(_tilde "$repo")" "$NC" >&2; return 1; }
    while read -r rtype robj rname; do
        [[ -n "$rtype" && -n "$robj" && -n "$rname" ]] || continue
        if [[ -z "${seenref[$rname]:-}" ]]; then
            seenref[$rname]=1
            pairs+="refname"$'\t'"$rname"$'\n'
        fi
        case "$rtype" in
            tree) revs+=("$robj") ;;
            tag)
                # The whole object, not a handful of fields. A tag object
                # carries its own name in a "tag <name>" header, which differs
                # from the refname and ships with it -- that name was reaching
                # the scanner only because rev-list --objects happens to print
                # it in the path column, which is a side effect and not a
                # reading. And a tag may name another tag: %(*objecttype) peels
                # all the way to the final commit or blob, so every tag object
                # in between had its message read by nobody.
                # Every way out of this loop other than "the chain ended" is
                # a refusal. The first version broke out on a cat-file that
                # failed, on an awk that failed and on a chain longer than the
                # bound -- so a repository this code could not follow ended the
                # walk quietly and the rest of the chain went unread, which is
                # the fail-open this whole round has been about.
                local tobj="$robj" ttype tdepth=0 tarc
                while [[ -n "$tobj" ]]; do
                    if (( tdepth >= 32 )); then
                        printf '%somabackup: the tag chain at %s is deeper than 32 -- refusing to call it clean%s\n' \
                            "$RED" "$rname" "$NC" >&2
                        return 1
                    fi
                    bl="$(git -C "$repo" cat-file tag "$tobj" 2>/dev/null)" \
                        || { printf '%somabackup: cannot read the tag object at %s -- refusing to call it clean%s\n' \
                                 "$RED" "$rname" "$NC" >&2; return 1; }
                    while IFS= read -r bline; do
                        [[ -n "$bline" ]] || continue
                        pairs+="tag:$rname"$'\t'"$bline"$'\n'
                    done <<<"$bl"
                    tobj="$(printf '%s' "$bl" | awk '/^object /{print $2; exit}')"; tarc=$?
                    if (( tarc != 0 )) || [[ -z "$tobj" ]]; then
                        printf '%somabackup: the tag object at %s names no target -- refusing to call it clean%s\n' \
                            "$RED" "$rname" "$NC" >&2
                        return 1
                    fi
                    ttype="$(git -C "$repo" cat-file -t "$tobj" 2>/dev/null)" \
                        || { printf '%somabackup: cannot identify what tag %s points at -- refusing to call it clean%s\n' \
                                 "$RED" "$rname" "$NC" >&2; return 1; }
                    [[ "$ttype" == tag ]] || break
                    tdepth=$((tdepth + 1))
                done ;;
            blob)
                bl="$(git -C "$repo" cat-file blob "$robj" 2>/dev/null)" \
                    || { printf '%somabackup: cannot read the blob at %s -- refusing to call it clean%s\n' \
                             "$RED" "$rname" "$NC" >&2; return 1; }
                while IFS= read -r bline; do
                    [[ -n "$bline" ]] || continue
                    pairs+="blob:$rname"$'\t'"$bline"$'\n'
                done <<<"$bl" ;;
        esac
    done <<<"$reflist"

    # Path names, which git grep never sees: it searches what a file holds, not
    # what it is called. A key used as a filename is packed like any other.
    #
    # Two sources, because rev-list --objects prints each OID once, with the
    # first path it was found at: two files with identical content share a blob
    # and only one of the names survives -- so a key used as a filename was
    # hidden by any harmless file that happened to hold the same bytes. git log
    # --name-only walks the diffs and names both.
    local objlist opath
    local -A seenpath=()
    # Each with its own status. Both inside one substitution reported only the
    # last one's, so a rev-list that failed left the paths half-collected and
    # the scan returned clean.
    local objrev objlog
    objrev="$(git -C "$repo" rev-list --objects --all 2>/dev/null)" \
        || { printf '%somabackup: cannot list the objects of %s -- refusing to call it clean%s\n' \
                 "$RED" "$(_tilde "$repo")" "$NC" >&2; return 1; }
    objlog="$(git -C "$repo" log --all -m --no-renames --name-only --format='' 2>/dev/null)" \
        || { printf '%somabackup: cannot list the paths of %s -- refusing to call it clean%s\n' \
                 "$RED" "$(_tilde "$repo")" "$NC" >&2; return 1; }
    objlist="$objrev"$'\n'"$objlog"
    while IFS= read -r bline; do
        [[ -n "$bline" ]] || continue
        # rev-list lines are "<oid> <path>"; log --name-only lines are the path
        # alone. A bare 40-hex line is an object with no path and is skipped.
        if [[ "$bline" =~ ^[0-9a-f]{40}( |$) ]]; then
            opath="${bline#* }"
            [[ -n "$opath" && "$opath" != "$bline" ]] || continue
        else
            opath="$bline"
        fi
        # The two sources overlap, and one finding per name is enough.
        [[ -n "${seenpath[$opath]:-}" ]] && continue
        seenpath[$opath]=1
        pairs+="path"$'\t'"$opath"$'\n'
    done <<<"$objlist"

    # Split in bash rather than through cut, whose status was thrown away: a cut
    # that failed emptied every message and the push carried on. What is left is
    # two parallel streams -- who said it, and what was said -- so the pattern
    # only ever meets the line itself.
    local -a MSGWHO=()
    msgs=""
    while IFS= read -r pline; do
        [[ -n "$pline" ]] || continue
        MSGWHO+=("${pline%%$'\t'*}")
        msgs+="${pline#*$'\t'}"$'\n'
    done <<<"$pairs"

    while IFS=$'\t' read -r id re ci; do
        [[ -n "$id" && -n "$re" ]] || continue
        if (( ${#revs[@]} )); then
        # Per pattern, not globally: `git grep -E` is POSIX ERE with no inline
        # (?i), and -i everywhere would make AKIA match "akia" in prose.
        # -a, not -I: `git grep -I` skips binary blobs and `git bundle` packs
        # them anyway, so a credential inside one shipped unscanned. These
        # patterns are high-signal ASCII shapes -- random bytes matching
        # `AKIA[0-9A-Z]{16}` is not a realistic false positive -- so reading
        # binary as text closes the hole at no practical cost.
        # --break --heading, so the decoration never reaches the regex. The
        # default format prefixes each hit with "<rev>:<path>:<lineno>:", and
        # _still_matches was then re-applying the pattern to THAT: an anchored
        # pattern -- ^AKIA[0-9A-Z]{16}$ on a key that occupies its own line --
        # matched inside git grep and failed here, and the disagreement between
        # the two resolved to "clean". The push went out with the key in it.
        #
        # In this format a heading is "<rev>:<path>" on its own line and every
        # following line is "<lineno>:<content>" until a blank line announces
        # the next heading. A blank matching line prints as "<lineno>:", never
        # as an empty line, so the two can never be confused -- which the plain
        # format could not promise, a path being free to contain colons and a
        # line free to begin with something shaped like a sha.
        # --no-color / --no-column: git grep honours color.ui=always even into
        # a pipe, and the escape it puts right before a match left the second
        # regex pass no word boundary before the token -- the push gate called
        # a history holding a GitHub token clean (review omabackup-69). What
        # the user likes on screen must not change what this gate reads.
        local -a gflags=(-a -n --break --heading -E --no-color --no-column)
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
        local head="" want_head=1 body line_out hpath where
        while IFS= read -r hit; do
            if [[ -z "$hit" ]]; then want_head=1; continue; fi
            if (( want_head )); then head="$hit"; want_head=0; continue; fi
            body="${hit#*:}"          # drop the line number; what is left is the line
            _still_matches "$body" "$re" "$ci" || continue
            # A hit inside a binary would otherwise dump the blob into the
            # report. Keep it printable and bounded.
            # Bounded in bash. The truncation used to run through cut, whose
            # failure would have emptied the one part of the finding that says
            # where the secret is.
            line_out="$(printf '%s:%s' "$head" "$hit" | tr -c '[:print:]\t' '.')"
            # The heading is "<rev>:<path>" and a rev holds no colon, so the
            # first one splits it whatever the path holds.
            hpath="${head#*:}"
            if _scan_name_hidden "$hpath" "$patterns"; then
                where="${head:0:12} (content of a file whose NAME is not shown), line ${hit%%:*}"
            else
                where="${head:0:12} $(_scan_safe "$hpath"), line ${hit%%:*}"
            fi
            printf '%s\t%s\t%s\n' "$id" "$where" "${line_out:0:200}"
        done <<<"$out"
        fi

        # Commit messages and tag bodies, collected once above. grep exits 1
        # for "nothing here" and above 1 for "I could not do it" -- read through
        # a process substitution those were the same answer, and the second one
        # meant a pattern silently stopped being applied to the history.
        local mout mrc
        if [[ "$ci" == true ]]; then mout="$(printf '%s' "$msgs" | grep -niE -e "$re")"
        else mout="$(printf '%s' "$msgs" | grep -nE -e "$re")"; fi
        mrc=$?
        if (( mrc > 1 )); then
            printf '%somabackup: pattern %s could not be applied to the commit messages%s\n' \
                "$RED" "$id" "$NC" >&2
            rc=1
            continue
        fi
        local ln who
        while IFS= read -r hit; do
            [[ -n "$hit" ]] || continue
            ln="${hit%%:*}"; body="${hit#*:}"
            _still_matches "$body" "$re" "$ci" || continue
            who="${MSGWHO[$((ln - 1))]:-?}"
            case "$who" in
                path)    where="a file NAME in the history (not shown)" ;;
                refname) where="a ref NAME (not shown)" ;;
                tag:*|blob:*)
                    if _scan_name_hidden "${who#*:}" "$patterns"; then
                        where="${who%%:*}:(a ref whose NAME is not shown)"
                    else
                        where="$(_scan_safe "$who")"
                    fi ;;
                *)       where="$(_scan_safe "$who"), message or header" ;;
            esac
            printf '%s\t%s\t%s: %s\n' "$id" "$where" "$who" "$body"
        done <<<"$mout"
    done <<<"$patterns"
    return $rc
}

# Prints the report and returns non-zero when anything was found OR when the
# scan could not run. Both are reasons not to send.
# scan_files <dir> <deny-file>
# The same patterns, over a directory. The repository scan runs before the
# artefact is assembled, and assembly then adds files the scan never saw: the
# tool, the manifest it was built from, the restore notes. Those ride to the
# same destinations as everything else -- and the manifest in particular is the
# user's own file, free to name whatever it names.
#
# repo.bundle is skipped: it is a packfile, its contents were scanned as objects
# a moment ago, and grepping compressed bytes finds nothing either way.
# _scan_safe <text> -- control bytes shown as "?", so a file name cannot drive
# the terminal or the journal it is printed to (review omabackup-75).
_scan_safe() { local x="$1"; printf '%s' "${x//[[:cntrl:]]/?}"; }

# _scan_name_hidden <name> <patterns> -- 0 when a rule matches the name or any
# "/"-separated part of it. A path or ref name is free to BE the token, and the
# push refusal printed it as the place to look (see report_secrets). Judged per
# part as well, so a rule anchored with ^ and $ still meets a directory name.
_scan_name_hidden() {
    local name="${1//$'\n'/ }" id re ci part
    local -a parts=()
    mapfile -d / -t parts < <(printf '%s' "$name")
    while IFS=$'\t' read -r id re ci; do
        [[ -n "$id" && -n "$re" ]] || continue
        for part in "$name" "${parts[@]}"; do
            _still_matches "$part" "$re" "$ci" && return 0
        done
    done <<<"$2"
    return 1
}

# _scan_dir_hint <rel-path> <patterns> -- " in <dir>/" for a hidden name, so the
# user knows where to look, unless the directory itself matches a pattern; then
# nothing. Only runs on hits, so its per-pattern cost does not matter.
#
# The path is cut before the first match of any pattern first, then at the last
# "/": a value free to hold a "/" otherwise printed its own first part as the
# directory (review omabackup-76). A grep that cannot answer gives no hint, and
# neither does a path with a newline: the name may have been hidden by a piece
# between newlines that this cut never looks at (review omabackup-79).
_scan_dir_hint() {
    local rel="$1" pats="$2" flat="${1//$'\n'/ }" pre d id re ci m s
    [[ "$rel" == *$'\n'* ]] && return 0
    pre="$rel"
    while IFS=$'\t' read -r id re ci; do
        [[ -n "$id" && -n "$re" ]] || continue
        local -a of=(-o -b -a -E --color=never)
        [[ "$ci" == true ]] && of+=(-i)
        m="$(printf '%s' "$flat" | grep "${of[@]}" -e "$re" 2>/dev/null)"; s=$?
        (( s > 1 )) && return 0
        m="${m%%$'\n'*}"; m="${m%%:*}"
        [[ -n "$m" ]] && (( m < ${#pre} )) && pre="${rel:0:m}"
    done <<<"$pats"
    [[ "$rel" == */* ]] || { printf ' at the top'; return 0; }
    [[ "$pre" == */* ]] || return 0
    d="${pre%/*}"
    while IFS=$'\t' read -r id re ci; do
        [[ -n "$id" && -n "$re" ]] || continue
        _still_matches "${d//$'\n'/ }" "$re" "$ci" && return 0
    done <<<"$pats"
    printf ' in %s/' "$(_scan_safe "$d")"
}

scan_files() {
    local dir="$1" file="$2" id re ci hit rc=0 patterns body
    [[ -d "$dir" && -f "$file" ]] || return 1
    shift 2
    # Basenames to skip, given by the caller and only by the caller. The
    # artefact build passes repo.bundle, its own packfile, whose objects were
    # already scanned; sync's staging scan passes nothing, so a user file of
    # that name is read like any other (review omabackup-73).
    local -a skip=("$@")

    # Bytes, not characters. Under a UTF-8 locale a byte that is not valid
    # UTF-8 right before a token takes the word boundary away from GNU grep
    # reading a file and from bash's =~ in _still_matches, and the token was
    # called clean. The systemd user manager runs with LANG=en_US.UTF-8, so
    # the timer was exposed (review omabackup-73, measured).
    local LC_ALL=C; export LC_ALL

    local -a DENY_EXCEPTIONS=()
    mapfile -t DENY_EXCEPTIONS < <(jq -r '(.exceptions // [])[].match' "$file" 2>/dev/null)

    patterns="$(jq -r '(.patterns // [])[] | "\(.id)\t\(.regex)\t\(.ignoreCase // false)"' \
                "$file" 2>/dev/null)" || return 1
    if [[ -z "$patterns" ]]; then
        printf '%somabackup: the deny-list yielded no patterns -- refusing to call this clean%s\n' \
            "$RED" "$NC" >&2
        return 1
    fi

    # File NAMES first, and symlink TARGETS. The push scan reads every path in
    # history, and git commits a symlink as its name plus its target text, so
    # all three are judged; a name or a target that hits is never printed, not
    # by its own hit and not by a hit on its content below.
    #
    # One grep per pattern over the whole NUL-separated list, never one per
    # file: _still_matches per file per pattern cost 12 s on a real 667-file
    # staging against 0.03 s before it (review omabackup-75). grep only selects
    # candidates; _still_matches still decides, exceptions included. grep reads
    # the list with newlines as spaces, the same text _still_matches is given,
    # or a name that only matches with the space never became a candidate.
    #
    # No temporary files. The lists hold every name, the hits hold the ones
    # that matched, token and all: on disk they were readable by others in a
    # shared /tmp (review omabackup-76), a failed redirect read as "no match",
    # and a signal mid-scan left them behind. Pipes and process substitutions
    # carry them instead, and each status is read with `wait` on the
    # substitution's own PID, as the content pass below does.
    local -a all_names=() link_path=() link_target=() link_raw=()
    local fs1 fs2
    mapfile -d '' -t all_names < <(find "$dir" \( -type f -o -type l \) -printf '%P\0' 2>/dev/null)
    wait "$!"; fs1=$?
    mapfile -d '' -t link_raw < <(find "$dir" -type l -printf '%P\0%l\0' 2>/dev/null)
    wait "$!"; fs2=$?
    if (( fs1 || fs2 )); then
        printf '%somabackup: cannot list the files of %s -- refusing to call it clean%s\n' \
            "$RED" "$(_tilde "$dir")" "$NC" >&2
        return 1
    fi
    local k
    for (( k = 0; k + 1 < ${#link_raw[@]}; k += 2 )); do
        link_path+=("${link_raw[k]}"); link_target+=("${link_raw[k + 1]}")
    done

    # What grep reads: each name with newlines as spaces, then each piece
    # between newlines of a name that has them, each view pointing back at its
    # entry. The push scan ends a name at its first newline (rev-list
    # --objects), so a rule anchored with $ matched there and not on the
    # joined name (review omabackup-78). Targets the same way.
    local -a name_view=() name_of=() tgt_view=() tgt_of=() seg
    _scan_views() {  # _scan_views <view-array> <of-array> <entries...>
        local -n _v="$1" _o="$2"; shift 2
        local _e _i=0 _s
        _v=("${@//$'\n'/ }"); _o=()
        for (( _i = 0; _i < $#; _i++ )); do _o+=("$_i"); done
        _i=0
        for _e in "$@"; do
            if [[ "$_e" == *$'\n'* ]]; then
                mapfile -t seg <<<"$_e"
                for _s in "${seg[@]}"; do _v+=("$_s"); _o+=("$_i"); done
            fi
            _i=$((_i + 1))
        done
    }
    _scan_views name_view name_of "${all_names[@]}"
    _scan_views tgt_view tgt_of "${link_target[@]}"

    local -A secret_name=() name_said=() target_said=()
    local rel nm rec n g lp lt
    if (( ${#all_names[@]} )); then
        while IFS=$'\t' read -r id re ci; do
            [[ -n "$id" && -n "$re" ]] || continue
            local -a zf=(-z -n -a -E --color=never)
            [[ "$ci" == true ]] && zf+=(-i)
            while IFS= read -r -d '' rec; do
                n="${rec%%:*}"; rel="${all_names[${name_of[$((n - 1))]}]}"
                nm="${name_view[$((n - 1))]}"
                _still_matches "$nm" "$re" "$ci" || continue
                secret_name["$rel"]=1
                if [[ -z "${name_said[$rel]:-}" ]]; then
                    name_said["$rel"]=1
                    printf '%s\t(a file NAME, not shown)%s\n' "$id" "$(_scan_dir_hint "$rel" "$patterns")"
                fi
            done < <(printf '%s\0' "${name_view[@]}" | grep "${zf[@]}" -e "$re" 2>/dev/null)
            wait "$!"; g=$?
            if (( g > 1 )); then
                printf '%somabackup: pattern %s could not be scanned over the file names%s\n' "$RED" "$id" "$NC" >&2
                return 1
            fi
        done <<<"$patterns"
    fi

    if (( ${#link_target[@]} )); then
        while IFS=$'\t' read -r id re ci; do
            [[ -n "$id" && -n "$re" ]] || continue
            local -a tf=(-z -n -a -E --color=never)
            [[ "$ci" == true ]] && tf+=(-i)
            while IFS= read -r -d '' rec; do
                n="${rec%%:*}"; k="${tgt_of[$((n - 1))]}"
                lt="${link_target[k]}"; lp="${link_path[k]}"
                _still_matches "${tgt_view[$((n - 1))]}" "$re" "$ci" || continue
                [[ -n "${target_said[$id:$k]:-}" ]] && continue
                target_said["$id:$k"]=1
                if [[ -n "${secret_name[$lp]:-}" ]]; then
                    printf '%s\t(a symlink target, not shown, of a link whose NAME is not shown)%s\n' \
                        "$id" "$(_scan_dir_hint "$lp" "$patterns")"
                else
                    printf '%s\t%s (symlink target, not shown)\n' "$id" "$(_scan_safe "$lp")"
                fi
            done < <(printf '%s\0' "${tgt_view[@]}" | grep "${tf[@]}" -e "$re" 2>/dev/null)
            wait "$!"; g=$?
            if (( g > 1 )); then
                printf '%somabackup: pattern %s could not be scanned over the symlink targets%s\n' "$RED" "$id" "$NC" >&2
                return 1
            fi
        done <<<"$patterns"
    fi

    while IFS=$'\t' read -r id re ci; do
        [[ -n "$id" && -n "$re" ]] || continue
        # -Z, not a manual walk. The first version walked file by file to keep
        # the path unambiguous -- `grep -r -H -n` prints "<path>:<lineno>:", and
        # a path free to contain a colon strips wrong. That walk re-ran per
        # pattern (9 patterns, 9 full walks) and shelled out to grep once per
        # file per pattern: 200 files became ~2.9s, a 144x cost over the bulk
        # form, in a project that rejected rsync over 44ms of process spawn.
        # And a find whose status was thrown away by a process substitution was
        # the very fail-open this file exists to refuse, back in its own scan.
        #
        # -Z ends the filename with a NUL instead of whatever character would
        # otherwise follow it, so the path/content boundary is unambiguous no
        # matter what either one holds -- no walk, no per-file spawn, and
        # grep's own exit status covers what find's used to.
        #
        # Read directly off the NUL, not through a variable. A command
        # substitution cannot hold a NUL byte any better than `read` can --
        # bash silently drops it either way -- so the first version of this fix
        # ran the NUL through `tr` into 0x01 first, a byte legal in a filename,
        # and claimed the boundary was unambiguous "no matter what either one
        # holds" when it had just traded one collision for a rarer one. Two
        # sequential reads against the SAME stream split it correctly instead:
        # -d '' stops at the real NUL for the path, and the plain read after it
        # stops at the newline that already ends every hit.
        #
        # grep's status does not cross the process-substitution boundary any
        # more directly than PIPESTATUS crossed the pipe in the version before
        # this one, so it is captured with `wait` on the substitution's own
        # PID instead of guessed at.
        local grc
        local -a gflags=(-r -a -n -Z -E --color=never)
        local sk
        for sk in "${skip[@]}"; do gflags+=("--exclude=$sk"); done
        [[ "$ci" == true ]] && gflags+=(-i)
        local f rest
        while IFS= read -r -d '' f && IFS= read -r rest; do
            [[ -n "$f" ]] || continue
            body="${rest#*:}"
            _still_matches "$body" "$re" "$ci" || continue
            # Where, never what: the rule, the file and the line number. The
            # line itself is not printed -- sync runs from a timer whose
            # output is the journal (review omabackup-73).
            rel="${f#$dir/}"
            if [[ -n "${secret_name[$rel]:-}" ]]; then
                printf '%s\t(content of a file whose NAME is not shown)%s, line %s\n' \
                    "$id" "$(_scan_dir_hint "$rel" "$patterns")" "${rest%%:*}"
            else
                printf '%s\t%s:%s\n' "$id" "$(_scan_safe "$rel")" "${rest%%:*}"
            fi
        # grep's own stderr is dropped: its diagnostics print the path, and the
        # name can be the token hidden above (review omabackup-75). Its status
        # is kept and reported below without a path.
        done < <(grep "${gflags[@]}" -e "$re" -- "$dir" 2>/dev/null)
        wait "$!"; grc=$?
        if (( grc > 1 )); then
            printf '%somabackup: pattern %s could not be scanned over %s%s\n' \
                "$RED" "$id" "$(_tilde "$dir")" "$NC" >&2
            rc=1
            continue
        fi
    done <<<"$patterns"
    return $rc
}

# _scan_load_patterns <deny-file>
# Fills the CALLER's ids/res/cis/pre_cs/pre_ci arrays and DENY_EXCEPTIONS
# (bash scopes dynamically). The prefilter is split by each rule's own case
# sensitivity: under -i a negated class such as [^A] also excludes `a`, so one
# case-insensitive pass is not a superset of the exact ones (review
# omabackup-70).
_scan_load_patterns() {
    local file="$1" patterns id re ci
    mapfile -t DENY_EXCEPTIONS < <(jq -r '(.exceptions // [])[].match' "$file" 2>/dev/null)
    patterns="$(jq -r '(.patterns // [])[] | "\(.id)\t\(.regex)\t\(.ignoreCase // false)"' \
                "$file" 2>/dev/null)" || return 1
    if [[ -z "$patterns" ]]; then
        printf '%somabackup: the deny-list yielded no patterns -- refusing to call this clean%s\n' \
            "$RED" "$NC" >&2
        return 1
    fi
    while IFS=$'\t' read -r id re ci; do
        [[ -n "$id" && -n "$re" ]] || continue
        ids+=("$id"); res+=("$re"); cis+=("$ci")
        if [[ "$ci" == true ]]; then pre_ci+=(-e "$re"); else pre_cs+=(-e "$re"); fi
    done <<<"$patterns"
}

# _scan_bytes <raw-file> <work> <label>
# Judges one byte stream against the caller's loaded patterns and prints
# `<rule-id>\t<label>, line <n>` per hit -- never the line. A stream holding
# NULs is judged twice, and a hit in either counts: with the NULs deleted it
# reads exactly as the push scan reads it (git grep matches the raw bytes, then
# bash drops the NULs before the second pass), so nothing the push gate would
# block can pass here; with each NUL as a line break, a token right after a NUL
# keeps its word boundary. Returns non-zero when the scan could not run.
_scan_bytes() {
    local raw="$1" work="$2" label="$3" view i g hit_any line ln body rc=0
    tr -d '\0' <"$raw" >"$work/blob" || return 1
    local -a views=("$work/blob")
    if [[ "$(wc -c <"$raw")" != "$(wc -c <"$work/blob")" ]]; then
        tr '\0' '\n' <"$raw" >"$work/blobn" || return 1
        views+=("$work/blobn")
    fi
    for view in "${views[@]}"; do
        hit_any=0
        if (( ${#pre_cs[@]} )); then
            grep -a -q -E --color=never "${pre_cs[@]}" -- "$view"; g=$?
            (( g > 1 )) && return 1
            (( g == 0 )) && hit_any=1
        fi
        if (( ! hit_any && ${#pre_ci[@]} )); then
            grep -a -q -i -E --color=never "${pre_ci[@]}" -- "$view"; g=$?
            (( g > 1 )) && return 1
            (( g == 0 )) && hit_any=1
        fi
        (( hit_any )) || continue
        for i in "${!ids[@]}"; do
            local -a gflags=(-a -n -E --color=never)
            [[ "${cis[$i]}" == true ]] && gflags+=(-i)
            grep "${gflags[@]}" -e "${res[$i]}" -- "$view" >"$work/hits"; g=$?
            (( g == 1 )) && continue
            (( g > 1 )) && { rc=1; continue; }
            while IFS= read -r line; do
                ln="${line%%:*}"; body="${line#*:}"
                _still_matches "$body" "${res[$i]}" "${cis[$i]}" || continue
                printf '%s\t%s, line %s\n' "${ids[$i]}" "$label" "$ln"
            done <"$work/hits"
        done
    done
    return $rc
}

# scan_tree <repo> <deny-file> <tree-oid> <workdir> <path>...
# The deny-list over what a commit of <tree-oid> adds at <path>...: each blob
# READ by its object id, the file names, and the name of every directory above
# them. sync runs it on the tree it has already written, before committing that
# same tree -- an object, so nothing running afterwards (a hook, an fsmonitor,
# a concurrent writer) can change what was judged (review omabackup-71).
#
# Reading the blob by id, rather than asking `git grep --cached` or grepping the
# worktree, is what keeps the bytes judged equal to the bytes committed: git
# grep follows color.ui/grep.column into its output, skips symlink entries
# (whose link TEXT is stored) and reads through `git replace`; the worktree
# follows symlinks git stores as text, ignores clean filters, and can change
# before the commit (review rounds omabackup-68/69).
#
# Names are judged first -- files and directories, because the push scan reads
# every path and every tree name in history. A path whose name or any of whose
# directories hits is never printed: not by that hit, not by a hit on its
# content, not by an error reading it. It is reported by its position in the
# list instead (scout omabackup-25, review omabackup-71). Every byte read lands
# in <workdir>, which the caller owns and removes on any exit, signals
# included. Returns non-zero when the scan could not run.
scan_tree() {
    local repo="$1" file="$2" tree="$3" work="$4"; shift 4
    local rc=0 i g line ln body label
    [[ -f "$file" && -n "$tree" && -d "$work" ]] || return 1
    (( $# )) || return 0

    # Bytes, not characters: under a UTF-8 locale an invalid byte right before
    # a token hid it from GNU grep and from bash's =~ (review omabackup-73).
    local LC_ALL=C; export LC_ALL
    local GIT_NO_REPLACE_OBJECTS=1; export GIT_NO_REPLACE_OBJECTS
    local -a DENY_EXCEPTIONS=() ids=() res=() cis=() pre_cs=() pre_ci=()
    _scan_load_patterns "$file" || return 1

    # One line per path, then one per distinct directory above them, so a hit's
    # line number names exactly one entry. A newline inside a name becomes a
    # space, and each piece between newlines gets a line of its own after
    # those, pointing back at its entry: the push scan reads names from
    # rev-list --objects, which ends a name at its first newline, so a rule
    # anchored with $ matched there and not here (review omabackup-78).
    local -A pos=() secret_pos=() dir_line=()
    local -a dirs=()
    local p d k=0 n="$#"
    for p in "$@"; do k=$((k + 1)); pos["$p"]=$k; done
    for p in "$@"; do
        d="$p"
        while [[ "$d" == */* ]]; do
            d="${d%/*}"
            [[ -n "${dir_line[$d]:-}" ]] && continue
            dirs+=("$d"); dir_line["$d"]=$(( n + ${#dirs[@]} ))
        done
    done
    # `if`, not `&&`: with no directory at all the && form returned 1 and
    # made every root-level-only commit look like a scan that could not run.
    local -a pieces=() piece_of=() seg
    local e=0
    for p in "$@" "${dirs[@]}"; do
        e=$((e + 1))
        [[ "$p" == *$'\n'* ]] || continue
        mapfile -t seg <<<"$p"
        for d in "${seg[@]}"; do pieces+=("$d"); piece_of+=("$e"); done
    done
    local nd=${#dirs[@]}
    local -A said=()
    {
        printf '%s\n' "${@//$'\n'/ }"
        if (( nd )); then printf '%s\n' "${dirs[@]//$'\n'/ }"; fi
        if (( ${#pieces[@]} )); then printf '%s\n' "${pieces[@]}"; fi
    } >"$work/names" || return 1
    for i in "${!ids[@]}"; do
        local -a nflags=(-a -n -E --color=never)
        [[ "${cis[$i]}" == true ]] && nflags+=(-i)
        grep "${nflags[@]}" -e "${res[$i]}" -- "$work/names" >"$work/hits"; g=$?
        (( g == 1 )) && continue
        if (( g > 1 )); then
            printf '%somabackup: pattern %s could not be scanned over the file names%s\n' \
                "$RED" "${ids[$i]}" "$NC" >&2
            rc=1; continue
        fi
        while IFS= read -r line; do
            ln="${line%%:*}"; body="${line#*:}"
            _still_matches "$body" "${res[$i]}" "${cis[$i]}" || continue
            (( ln > n + nd )) && ln="${piece_of[$(( ln - n - nd - 1 ))]}"
            [[ -n "${said[$i:$ln]:-}" ]] && continue
            said["$i:$ln"]=1
            if (( ln <= n )); then
                printf '%s\t(a file NAME, not shown: changed path #%s)\n' "${ids[$i]}" "$ln"
                secret_pos["$ln"]=1
            else
                printf '%s\t(a directory NAME, not shown)\n' "${ids[$i]}"
                d="${dirs[$(( ln - n - 1 ))]}"
                k=0
                for p in "$@"; do
                    k=$((k + 1))
                    [[ "$p" == "$d"/* ]] && secret_pos["$k"]=1
                done
            fi
        done <"$work/hits"
    done

    # The tree's own entries, not an index: ls-tree on the written object.
    if ! git -C "$repo" ls-tree -r -z --full-tree "$tree" >"$work/entries" 2>/dev/null; then
        printf '%somabackup: cannot list the tree it built -- refusing to call it clean%s\n' \
            "$RED" "$NC" >&2
        return 1
    fi
    local rec meta mode type oid path
    while IFS= read -r -d '' rec; do
        meta="${rec%%$'\t'*}"; path="${rec#*$'\t'}"
        [[ -n "${pos[$path]:-}" ]] || continue
        read -r mode type oid <<<"$meta"
        # Regular files and symlinks are blobs; a gitlink names a commit in
        # another repository and has no content here.
        [[ "$type" == blob ]] || continue
        k="${pos[$path]}"
        if [[ -n "${secret_pos[$k]:-}" || "$path" == *$'\n'* ]]; then
            label="changed path #$k"
        else
            label="$path"
        fi
        if ! git -C "$repo" cat-file blob "$oid" >"$work/raw" 2>/dev/null; then
            printf '%somabackup: cannot read %s from the tree it built%s\n' "$RED" "$label" "$NC" >&2
            rc=1; continue
        fi
        _scan_bytes "$work/raw" "$work" "$label" || {
            printf '%somabackup: cannot scan %s%s\n' "$RED" "$label" "$NC" >&2
            rc=1
        }
    done <"$work/entries"
    return $rc
}

# scan_commit_object <repo> <deny-file> <workdir> <commit-oid>
# The deny-list over a commit object as git stores it -- author, committer,
# every header and the message -- read with replacements off. The push scan
# reads raw commit objects, so a token in user.name or GIT_AUTHOR_NAME passed
# every blob check and was written by commit-tree (scout omabackup-25). sync
# runs this on the commit it has built, BEFORE moving any ref. Hits name only
# the line of the object; the header itself is never printed.
scan_commit_object() {
    local repo="$1" file="$2" work="$3" oid="$4"
    [[ -f "$file" && -d "$work" && -n "$oid" ]] || return 1
    # Bytes, not characters: under a UTF-8 locale an invalid byte right before
    # a token hid it from GNU grep and from bash's =~ (review omabackup-73).
    local LC_ALL=C; export LC_ALL
    local GIT_NO_REPLACE_OBJECTS=1; export GIT_NO_REPLACE_OBJECTS
    local -a DENY_EXCEPTIONS=() ids=() res=() cis=() pre_cs=() pre_ci=()
    _scan_load_patterns "$file" || return 1
    git -C "$repo" cat-file commit "$oid" >"$work/raw" 2>/dev/null || {
        printf '%somabackup: cannot read the commit it built -- refusing to call it clean%s\n' \
            "$RED" "$NC" >&2
        return 1
    }
    _scan_bytes "$work/raw" "$work" "the commit's own header or message"
}

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
    # Where, never what. This printed the matched line, cut to 160 bytes, and
    # push runs from an hourly timer whose stderr is the journal: every run
    # until the history was rewritten copied the token there again. The staging
    # scan stopped printing it in review omabackup-73 and sync --commit never
    # did; this was the last gate that still did (docs/PLAN.md, 2026-09-30).
    local where
    while IFS=$'\t' read -r id where rest; do
        [[ -n "$id" ]] || continue
        printf '  %s%s%s  %s\n' "$YELLOW" "$id" "$NC" "$where" >&2
    done <<<"$hits"
    printf '\n  The matched text is not printed here on purpose.\n' >&2
    printf '\n  A leak is irreversible, so this blocks rather than warns (docs/DESIGN.md §6).\n' >&2
    printf '  This scans every reachable commit, every commit message and tag body,\n' >&2
    printf '  and every object a ref names outright: deleting the file does not remove\n' >&2
    printf '  it from history. Rewrite the history, or add a justified entry to %s.\n' \
        "$(_tilde "$SECRETS_DENY_FILE")" >&2
    return 1
}

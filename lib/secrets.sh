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
        ] | .[]' "$file" 2>/dev/null)" \
        || die "the deny-list at $(_tilde "$file") could not be read: refusing to push unscanned"
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
    local pid3 pre3 zwrc
    while IFS=$'\t' read -r pid3 pre3; do
        [[ -n "$pid3" && -n "$pre3" ]] || continue
        ( [[ "" =~ $pre3 ]] ) 2>/dev/null; zwrc=$?
        if (( zwrc == 2 )); then
            bad="${bad:+$bad$'\n'}pattern $pid3 is not a regular expression this scanner can compile"
        elif (( zwrc == 0 )) \
          && [[ -z "$( [[ "" =~ $pre3 ]] 2>/dev/null; printf '%s' "${BASH_REMATCH[0]}" )" ]]; then
            bad="${bad:+$bad$'\n'}pattern $pid3 can match the empty string: it would match every line and report none"
        fi
    done < <(jq -r '(.patterns // [])[] | "\(.id)\t\(.regex)"' "$file" 2>/dev/null)

    local exid2 exm2 reach
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
        done < <(jq -r '(.patterns // [])[] | "\(.id)\t\(.regex)\t\(.ignoreCase // false)"' "$file" 2>/dev/null)
        (( reach )) || bad="${bad:+$bad$'\n'}exception $exid2 is unreachable: no pattern produces exactly this text"
    done < <(jq -r '(.exceptions // [])[] | "\(.id)\t\(.match)"' "$file" 2>/dev/null)

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
# Prints `<rule-id>\t<commit>:<file>:<line>:<text>` per hit, nothing when clean.
# Returns non-zero if the scan itself could not be carried out.
scan_secrets() {
    local repo="$1" file="$2" id re ci hit rc=0
    [[ -f "$file" ]] || return 1

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
        local -a gflags=(-a -n --break --heading -E)
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
        local head="" want_head=1 body line_out
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
            printf '%s\t%s\n' "$id" "${line_out:0:200}"
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
            printf '%s\t%s: %s\n' "$id" "$who" "$body"
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
scan_files() {
    local dir="$1" file="$2" id re ci hit rc=0 patterns body
    [[ -d "$dir" && -f "$file" ]] || return 1

    local -a DENY_EXCEPTIONS=()
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
        local out grc
        local -a gflags=(-r -a -n -Z -E --exclude=repo.bundle)
        [[ "$ci" == true ]] && gflags+=(-i)
        # pipefail asked for explicitly, and restored after. The pipe runs
        # inside the command substitution's own subshell; PIPESTATUS there
        # never crosses back out to this shell, so checking it here reads tr's
        # exit status, always 0, not grep's. That was the first version of this
        # fix, and it looked closed until the fail-closed spec was run: a grep
        # denied a subdirectory reported success.
        local _had_pf=0; [[ -o pipefail ]] && _had_pf=1
        set -o pipefail
        out="$(grep "${gflags[@]}" -e "$re" -- "$dir" 2>&1 | tr '\0' '\001')"; grc=$?
        (( _had_pf )) || set +o pipefail
        if (( grc > 1 )); then
            printf '%somabackup: pattern %s could not be scanned over %s%s\n' \
                "$RED" "$id" "$(_tilde "$dir")" "$NC" >&2
            rc=1
            continue
        fi
        local f rest
        while IFS= read -r hit; do
            [[ -n "$hit" ]] || continue
            f="${hit%%$'\001'*}"; rest="${hit#*$'\001'}"
            body="${rest#*:}"
            _still_matches "$body" "$re" "$ci" || continue
            printf '%s\t%s\n' "$id" "${f#$dir/}:${rest:0:200}"
        done <<<"$out"
    done <<<"$patterns"
    return $rc
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
    while IFS=$'\t' read -r id rest; do
        [[ -n "$id" ]] || continue
        printf '  %s%s%s  %s\n' "$YELLOW" "$id" "$NC" "$(printf '%s' "$rest" | head -c 160)" >&2
    done <<<"$hits"
    printf '\n  A leak is irreversible, so this blocks rather than warns (docs/DESIGN.md §6).\n' >&2
    printf '  This scans every reachable commit, every commit message and tag body,\n' >&2
    printf '  and every object a ref names outright: deleting the file does not remove\n' >&2
    printf '  it from history. Rewrite the history, or add a justified entry to %s.\n' \
        "$(_tilde "$SECRETS_DENY_FILE")" >&2
    return 1
}

#!/bin/bash
# Destinations: where the bundle goes (docs/DESIGN.md §3).
#
# Config is deliberately NOT in groups.default.json. That manifest answers
# "what is saved", is public on GitHub and meant to be shared; a NAS path, a
# drive UUID and an rclone remote name answer "where does it go" and are
# machine identity, the same class as OMABACKUP_REPO -- which is already an
# environment variable for exactly this reason. Nobody forking this repo should
# inherit somebody else's NAS.
#
# `enabled` lives in the config because it is the user's intent. Last success,
# last error and backoff live in the state directory because they are
# observation. Mixing them means the tool rewrites the user's config on every
# tick, which is how a hand-made edit gets lost.
#
# One destination failing never invalidates another, and never touches the git
# commit: `push` is its own verb precisely so a NAS being down cannot change
# whether the source of truth was written.

DEST_BACKOFF_CAP=21600   # 6h. Long enough to stop nagging, short enough to recover unattended.

# ── config ───────────────────────────────────────────────────────────────────
_dest_json() { [[ -f "$DESTINATIONS_FILE" ]] && cat "$DESTINATIONS_FILE" || printf '{"destinations":[]}'; }

KNOWN_DEST_FIELDS='["id","type","path","keep","enabled","note"]'
KNOWN_DEST_TYPES='["dir"]'
DEST_KEEP_MAX=9223372036854775807

# Keep is a user-controlled decimal that eventually participates in Bash
# arithmetic while pruning. Normalize it and bound it to the largest signed
# integer Bash can compare safely before it reaches any arithmetic context.
_dest_keep_normalize() {
    local value="$1" normalized
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    normalized="$value"
    while [[ ${#normalized} -gt 1 && ${normalized:0:1} == 0 ]]; do
        normalized="${normalized:1}"
    done
    (( ${#normalized} <= ${#DEST_KEEP_MAX} )) || return 1
    if (( ${#normalized} == ${#DEST_KEEP_MAX} )) && [[ "$normalized" > "$DEST_KEEP_MAX" ]]; then
        return 1
    fi
    (( 10#$normalized >= 1 )) || return 1
    printf '%s' "$normalized"
}

_dest_keep_valid() {
    _dest_keep_normalize "$1" >/dev/null
}

_dest_id_valid() {
    [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

_destinations_schema_valid() {
    jq -e '
      (. | type == "object")
      and (.schemaVersion == 1)
      and ((.destinations | type) == "array")
      and ((if type == "object" then (keys - ["schemaVersion","destinations"] | length == 0) else false end))
      and all(.destinations[];
        if type != "object" then false else
          ((.id? // null) | if type == "string" then test("^[A-Za-z0-9_-]+$") and . != "github" else false end)
          and ((.type? // null) | . == "dir")
          and ((.path? // null) | if type == "string" then length > 0 and startswith("/") else false end)
          and ((.keep? // null) | if type == "number" then floor == . and . >= 1 else false end)
          and (if has("enabled") then (.enabled | type == "boolean") else true end)
        end
      )
      and (([.destinations[]?.id] | unique | length) == (.destinations | length))
    ' "$DESTINATIONS_FILE" >/dev/null 2>&1
}

# Same invariant the group manifest has: a field declared and silently ignored
# is how staging once went from 1.3MB to 84MB. `github` is not listed here --
# it is implicit, derived from OMABACKUP_REPO's own remote.
assert_destinations_understood() {
    [[ -f "$DESTINATIONS_FILE" ]] || return 0
    local bad line keep_values keep
    # jq's own status, checked -- a destinations.json this cannot even
    # PARSE (invalid JSON, not just an unknown field) produced the same
    # empty $bad a genuinely clean file does, and `[[ -z "$bad" ]] && return
    # 0` read "could not check" as "checked fine, nothing wrong". A PoC
    # ({not-json) confirmed the result: assert_destinations_understood
    # returned 0 silently, and push went on to treat a destinations file it
    # never actually validated as though it had -- a directory destination
    # this file declares can then be skipped by whatever reads it next
    # while a configured GitHub remote (which needs no entry here at all)
    # still gets pushed to, the operator never told the file was unreadable.
    bad="$(jq -r --argjson k "$KNOWN_DEST_FIELDS" --argjson t "$KNOWN_DEST_TYPES" '
        [ (if type == "object" then
              ((keys - ["schemaVersion","destinations"])[]
                | "unknown field \(.) in destinations document")
            else empty end)
        , ((.destinations // [])[] | . as $d | (keys[] | select(. as $f | $k | index($f) | not))
            | "unknown field \(.) in destination \($d.id)")
        , ((.destinations // [])[] | select(.type as $x | $t | index($x) | not)
            | "unknown type \(.type) in destination \(.id)")
        , ((.destinations // [])[] | select((.keep // 0) | type != "number" or floor != . or . < 1)
            | "destination \(.id) needs a positive integer keep value")
        , ((.destinations // [])[] | select((.id // "") == "github")
            | "destination github is implicit; configure the repository origin remote instead")
        , ((.destinations // [])[] | select((.id // "") == "" or (.path // "") == "")
            | "destination missing id or path")
        ] | .[]' "$DESTINATIONS_FILE" 2>/dev/null)" || {
        printf '%somabackup: destinations.json could not be read as JSON at all%s\n' "$RED" "$NC" >&2
        exit 1
    }
    keep_values="$(jq -r '.destinations[]? | (.keep // 0)' "$DESTINATIONS_FILE" 2>/dev/null)" || {
        printf '%somabackup: destinations.json could not be read as JSON at all%s\n' "$RED" "$NC" >&2
        exit 1
    }
    if [[ -n "$keep_values" ]]; then
        while IFS= read -r keep; do
            _dest_keep_valid "$keep" || {
                [[ -n "$bad" ]] && bad+=$'\n'
                bad+="destination has a keep value outside the supported integer range"
            }
        done <<<"$keep_values"
    fi
    if ! _destinations_schema_valid; then
        [[ -n "$bad" ]] && bad+=$'\n'
        bad+="destination document fails its id, path, schema, or enabled-value invariants"
    fi
    [[ -z "$bad" ]] && return 0
    printf '%somabackup: destinations.json declares what push cannot honor:%s\n' "$RED" "$NC" >&2
    while IFS= read -r line; do printf '  %s\n' "$line" >&2; done <<<"$bad"
    exit 1
}

dest_ids() { _dest_json | jq -r '(.destinations // [])[] | select(.enabled != false) | .id'; }
dest_field() { _dest_json | jq -r --arg i "$1" --arg f "$2" \
    '(.destinations // [])[] | select(.id==$i) | .[$f] // empty'; }

# github needs no entry: the repo already knows its own remote.
dest_has_github() { git -C "${OMABACKUP_REPO:-/nonexistent}" remote get-url origin >/dev/null 2>&1; }

# Git may repeat a credential-bearing remote URL in a transport error. Keep
# that detail safe at the boundary shared by the terminal, destination state,
# and status JSON. This deliberately redacts URL userinfo only; it does not
# pretend to be a general secret scanner for arbitrary command output.
dest_redact_output() {
    sed -E 's#([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@[:space:]]+@#\1#g'
}

# Return the first effective origin push URL for user-facing status, with
# credentials removed before it can reach JSON, the panel, or a terminal. Git
# permits several push URLs and `git push origin HEAD` sends to all of them;
# the stable scalar `github.url`/`locator` contract intentionally exposes the
# first one only. The push command itself still receives the real remote from
# Git; this helper is presentation data only. The ordinary repository contract
# deliberately matches the command gates elsewhere, which still require
# `.git` to be a directory.
dest_github_push_url() {
    local repo="${OMABACKUP_REPO:-}" url
    [[ -n "$repo" ]] || return 1
    [[ -d "$repo/.git" ]] || return 1
    url="$(git -C "$repo" remote get-url --push origin 2>/dev/null)" || return 1
    [[ -n "$url" ]] || return 1
    printf '%s' "$url" | sed -E 's#^([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@]*@#\1#'
}

# ── state ────────────────────────────────────────────────────────────────────
# One file per destination, not one document: a mount-triggered push and a
# timer-triggered push can run at once and must not overwrite each other, and a
# corrupted document would take every destination's history with it.
dest_state_file() {
    _dest_id_valid "$1" || return 1
    printf '%s/destinations/%s.json' "$OMABACKUP_STATE" "$1"
}
dest_state() { jq -r "${2}" "$(dest_state_file "$1")" 2>/dev/null || printf ''; }

dest_state_write() {
    local id="$1" doc="$2" p
    p="$(dest_state_file "$id")" || return 1
    mkdir -p "$(dirname "$p")" || return 1
    # rm -f first: `>` follows a symlink already sitting at "$p.tmp" instead
    # of replacing it -- the exact defect `_publish_file` (lib/publish.sh)
    # was already fixed against, spotted here by a review round of the
    # restore journal's own copy of this idiom (restore_record in
    # lib/restore.sh). A pre-planted "$p.tmp" -> somewhere-else would have
    # this write land through the link, and the mv right after would move
    # the LINK itself over the real state file -- every future write for
    # this destination silently redirected from then on.
    rm -f "$p.tmp" 2>/dev/null
    printf '%s\n' "$doc" >"$p.tmp" && mv "$p.tmp" "$p"
}

_dest_record_success() {
    local id="$1" removed="${2:-0}"
    dest_state_write "$id" "$(jq -n --arg id "$id" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --argjson removed "$removed" \
        '{schemaVersion:1, id:$id, lastSuccess:$at, lastError:null, failures:0,
          nextAttemptAt:0, lastPrune:{at:$at, removed:$removed}}')"
}

# Backoff is stored as an absolute epoch, never as a multiplier: the process is
# ephemeral and restarts every tick, so a multiplier with no timestamp cannot be
# evaluated after a reboot.
_dest_record_failure() {
    local id="$1" msg="$2" fails delay
    msg="$(printf '%s' "$msg" | dest_redact_output)"
    fails="$(dest_state "$id" '.failures // 0')"; [[ "$fails" =~ ^[0-9]+$ ]] || fails=0
    fails=$((fails + 1))
    delay=$((60 * (1 << (fails > 8 ? 8 : fails - 1))))
    (( delay > DEST_BACKOFF_CAP )) && delay=$DEST_BACKOFF_CAP
    dest_state_write "$id" "$(jq -n --arg id "$id" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg msg "$msg" --argjson f "$fails" --argjson next "$(( $(date +%s) + delay ))" \
        --arg prev "$(dest_state "$id" '.lastSuccess // ""')" \
        '{schemaVersion:1, id:$id, lastSuccess:(if $prev=="" then null else $prev end),
          lastError:{at:$at, message:$msg}, failures:$f, nextAttemptAt:$next}')"
}

# Old state files may have been written before error details were redacted.
# Sanitize the message while projecting state to status JSON, so a previously
# persisted credential cannot escape merely because the panel polls status.
dest_state_public_json() {
    local file="$1" doc message
    doc="$(cat "$file" 2>/dev/null || printf '{}')"
    message="$(jq -r '.lastError.message // empty' <<<"$doc" 2>/dev/null | dest_redact_output)"
    jq --arg message "$message" '
        if (.lastError? | type) == "object" then
            .lastError.message = $message
        else . end' <<<"$doc" 2>/dev/null || printf '{}'
}

dest_in_backoff() {
    local next; next="$(dest_state "$1" '.nextAttemptAt // 0')"
    [[ "$next" =~ ^[0-9]+$ ]] || return 1
    (( next > $(date +%s) ))
}

# ── retention ────────────────────────────────────────────────────────────────
# The only primitive in this tool that can destroy a backup. Five rules, each
# with a spec:
#   1. never before the new copy is confirmed present (the caller's job)
#   2. never rm -rf, never a directory -- regular files only, one level deep
#   3. an anchored, host-scoped pattern, so a shared folder loses nothing
#   4. only inside a directory this tool stamped as its own
#   5. ordered by the timestamp in the name, because cp and rclone rewrite mtime
#
# Rule 4 is the one that matters: it turns a wrong path in a config file from a
# data-loss event into a no-op with an error.
DEST_STAMP='.omabackup-destination'

# One definition of what this tool's own filenames look like, because two
# drifted apart: adding the short sha to the published name updated the pattern
# retention deletes by and left the one deciding ownership behind, so a folder
# holding our own bundles read as foreign and was never stamped -- and so never
# pruned. The sha group is optional so bundles written before it existed are
# still recognised as ours.
DEST_NAME_TAIL='[0-9]{8}-[0-9]{6}(-[0-9a-f]{12})?\.tar\.zst'

prune_bundles() {  # prune_bundles <dir> <host> <keep> -> prints how many it removed
    local dir="$1" host="$2" keep="$3" f n=0 removed=0 normalized_keep
    normalized_keep="$(_dest_keep_normalize "$keep")" || {
        printf 'refusing to prune with keep=%s\n' "$keep" >&2
        return 1
    }
    keep="$normalized_keep"
    [[ -d "$dir" ]] || return 1
    if [[ ! -f "$dir/$DEST_STAMP" ]]; then
        printf 'omabackup: refusing to prune a directory with no %s stamp: %s\n' "$DEST_STAMP" "$dir" >&2
        return 1
    fi
    # The hostname goes into a regular expression, so it has to be escaped: a
    # dot is ordinary in a hostname and matches any character in an ERE, which
    # widened retention to other machines' bundles.
    local hre; hre="$(printf '%s' "$host" | sed 's/[][\\.^$*+?(){}|\/]/\\&/g')"
    # Sorted on a built key, not the raw filename. Sorting names put a legacy
    # name (written before bundles carried a short sha) AFTER the sha'd one
    # within the same second, so `sort -r` kept the older format and pruned the
    # newer. The key is <timestamp> <1 if sha'd> <name>, so a tie is decided by
    # format age rather than by punctuation.
    # The timestamp is read at a known offset, not searched for. awk's match()
    # finds the FIRST -YYYYMMDD-HHMMSS in the name, and a hostname that looks
    # like a timestamp ("box-20200101-000000") owns it: every bundle then sorted
    # under the same key, the tie fell to the sha column, and a legacy bundle
    # newer by a day was pruned in favour of a sha'd one older by a day. The
    # prefix is exactly "omabackup-<host>-", so the 15 characters after it are
    # the timestamp, whatever the host is called. Its LENGTH is what crosses
    # into awk: a number needs no quoting and no escape handling.
    local off=$(( ${#host} + 11 ))
    # The walk's status is read. mapfile through a process substitution threw it
    # away, so a find that stopped partway -- an unreadable subdirectory, a
    # vanishing mount -- produced a partial list, and retention then decided
    # which files were "oldest" from a fraction of what was there. Deleting on a
    # partial reading of a backup directory is the one thing this function must
    # never do.
    local listing
    listing="$(find "$dir" -maxdepth 1 -type f -regextype posix-extended \
        -regex ".*/omabackup-${hre}-${DEST_NAME_TAIL}" \
        -printf '%f\n' 2>/dev/null)" \
        || { printf 'omabackup: could not list %s -- refusing to prune it\n' "$dir" >&2
             printf '%s' 0; return 1; }
    local -a found=()
    if [[ -n "$listing" ]]; then
        # find's status is checked above; the pipe that turns its output into a
        # sort key was not -- awk, sort or cut failing partway left `found`
        # with whatever had made it through by then, and retention deleted on
        # that partial ordering same as it would have on a partial listing.
        local sorted _had_pf=0
        [[ -o pipefail ]] && _had_pf=1
        set -o pipefail
        sorted="$(printf '%s' "$listing" \
            | awk -v off="$off" '{ stamp = substr($0, off + 1, 15)
                     sha = ($0 ~ /-[0-9a-f]{12}\.tar\.zst$/) ? 1 : 0
                     print stamp "\t" sha "\t" $0 }' \
            | sort -r | cut -f3)"
        local sortrc=$?
        (( _had_pf )) || set +o pipefail
        if (( sortrc != 0 )); then
            printf 'omabackup: could not order the bundles in %s -- refusing to prune it\n' "$dir" >&2
            printf '%s' 0; return 1
        fi
        mapfile -t found <<<"$sorted"
    fi
    # rm's own status, checked -- `removed` only ever counted a SUCCESSFUL
    # removal, and this function's own return status (falling through to
    # `printf '%s' "$removed"`, always 0) never reflected a failed one at
    # all. A PoC (rm stubbed to fail for the one bundle past retention)
    # confirmed the result: prune_bundles printed removed=0 and returned
    # 0, indistinguishable from "nothing needed removing" -- a caller
    # logging this push as clean retention had no way to tell that
    # something SHOULD have been removed and was not.
    local prune_failed=0
    for f in "${found[@]:-}"; do
        [[ -n "$f" ]] || continue
        n=$((n + 1))
        (( n > keep )) || continue
        [[ -f "$dir/$f" && ! -L "$dir/$f" ]] || continue
        if rm -f -- "$dir/$f"; then
            removed=$((removed + 1))
        else
            prune_failed=1
        fi
    done
    printf '%s' "$removed"
    (( prune_failed == 0 ))
}

# ── drivers ──────────────────────────────────────────────────────────────────
# _dir_is_ours <dir> <name-just-written>
# True when the directory holds nothing this tool did not put there. Anything
# else -- a thesis, another tool's exports, a home directory -- is a sign the
# path is wrong or shared, and neither is a place to be deleting from.
_dir_is_ours() {
    local dir="$1" just="$2" f base
    while IFS= read -r -d '' f; do
        base="${f##*/}"
        [[ "$base" == "$just" ]] && continue
        # Our own bundles, and our own half-written ones. _push_dir writes
        # "<name>.tmp" before renaming, so an interrupted push leaves one behind
        # -- and counting it as foreign locked the tool out of its own
        # destination permanently, silently ending retention there.
        [[ "$base" =~ ^omabackup-.+-${DEST_NAME_TAIL}(\.tmp)?$ ]] && continue
        # Hidden entries are filesystem machinery, not somebody's work:
        # .snapshots on btrfs/ZFS, .Trash-1000, .stfolder from syncthing. A NAS
        # share is exactly the destination this feature exists for, and treating
        # its own plumbing as foreign content meant retention never ran there.
        [[ "$base" == .* ]] && continue
        return 1
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    # find's own status, checked -- a walk that stopped partway (a
    # subdirectory this process cannot read, say) enumerated fewer entries
    # than the directory actually holds, and everything seen up to that
    # point being "ours" read as the whole directory being ours. This gates
    # the retention stamp -- "the rule that matters most," two functions
    # away -- so a false "yes" here is not a smaller mistake than a false
    # "no": it is the one that lets pruning run somewhere it was never
    # actually confirmed safe to.
    wait "$!" || return 1
    return 0
}

_push_dir() {  # _push_dir <id> <bundle> <publish-name>
    local id="$1" bundle="$2" name="$3" dir removed
    dir="$(dest_field "$id" path)"
    [[ -n "$dir" ]] || { printf 'no path configured'; return 1; }
    mkdir -p "$dir" 2>/dev/null || { printf 'cannot create %s' "$dir"; return 1; }

    # --remove-destination: cp, given an existing symlink at the destination,
    # follows it and writes through to whatever it points at -- confirmed
    # directly. A `dir` destination is exactly the kind of path another
    # process could plant something at first: a NAS mount, a removable drive,
    # anything shared. A symlink pre-planted at this exact "$name.tmp" path,
    # pointing anywhere this process can write, would otherwise have that
    # target silently overwritten with bundle content instead of the
    # destination gaining a bundle. --remove-destination unlinks whatever is
    # there first, so the write always lands on a fresh file at this path,
    # never through it.
    cp --remove-destination "$bundle" "$dir/$name.tmp" 2>/dev/null && mv "$dir/$name.tmp" "$dir/$name" 2>/dev/null \
        || { rm -f "$dir/$name.tmp" 2>/dev/null; printf 'cannot write into %s' "$dir"; return 1; }
    # The stamp is what lets retention delete here, so it can only be granted to
    # a directory this tool actually owns: empty, or holding nothing but its own
    # bundles. The first version stamped whatever path the config named and then
    # pruned it, which meant the protection documented as "the rule that matters
    # most" wrote its own permission on the way in. Point this at ~/Documents now
    # and bundles still arrive -- nothing is ever deleted there.
    if [[ ! -f "$dir/$DEST_STAMP" ]] && _dir_is_ours "$dir" "$name"; then
        printf '%s\n%s\n' "$id" "$(_hostname)" >"$dir/$DEST_STAMP" 2>/dev/null
    fi
    # Only now, with the new copy confirmed on disk. "Delete the old, upload the
    # new" is how you arrive at zero copies.
    [[ -f "$dir/$name" ]] || { printf 'copy vanished after write'; return 1; }
    # Only now, and only our own: this used to run right after mkdir, before
    # anything had established the directory was ours -- so pointing the config
    # at somebody's folder deleted their half-written archives on the way in.
    # That is the failure the stamp exists to prevent, one line above the stamp.
    if [[ -f "$dir/$DEST_STAMP" ]]; then
        find "$dir" -maxdepth 1 -type f -regextype posix-extended \
            -regex ".*/omabackup-.+-${DEST_NAME_TAIL%\\.tar\\.zst}\.tar\.zst\.tmp" \
            -delete 2>/dev/null
    fi
    # A prune failure does not fail the push -- the new copy already landed,
    # and refusing to report that over a retention hiccup would turn a cleanup
    # problem into a backup outage. But it must not vanish either: `|| removed=0`
    # swallowed it into the same shape as "nothing needed pruning," through a
    # stderr this line threw away with 2>/dev/null. Left to reach the real
    # stderr now, so a full destination that cannot prune says so.
    removed="$(prune_bundles "$dir" "$(_hostname)" "$(dest_field "$id" keep)")" || removed=0
    printf '%s' "${removed:-0}"
}

# §3 defines github as "commit + push". sync only ever did the commit half --
# there was not a single `git push` in this tool, so an unattended timer would
# have committed locally forever while the panel stayed green.
_push_github() {
    local out
    out="$(git -C "$OMABACKUP_REPO" push origin HEAD 2>&1)" || {
        printf '%s' "${out:-push failed}" | dest_redact_output
        return 1
    }
    printf '0'
}

push_destination() {  # push_destination <id> <bundle> <name> -> prints detail, returns status
    local id="$1" bundle="$2" name="$3" type
    if [[ "$id" == github ]]; then _push_github; return $?; fi
    type="$(dest_field "$id" type)"
    case "$type" in
        dir) _push_dir "$id" "$bundle" "$name" ;;
        *)   printf 'no driver for type %s' "$type"; return 1 ;;
    esac
}

dest_target_understood() {
    local id="$1" type
    _dest_id_valid "$id" || {
        printf 'destination id must contain only letters, numbers, _ or -: %s' "$id"
        return 1
    }
    [[ "$id" == github ]] && return 0
    type="$(dest_field "$id" type)"
    [[ -n "$type" ]] || {
        printf 'unknown destination: %s' "$id"
        return 1
    }
}

# ── the destinations block status --json publishes ───────────────────────────
# Never verify --json: cmd_sync refuses to commit when verify fails, so a
# destination folded into verify would let a disconnected NAS block the source
# of truth -- the exact inverse of "one destination failing does not invalidate
# the others" (§3).
destinations_json() {
    local id github_url
    { for id in $(dest_ids); do
        jq -n --arg id "$id" --arg type "$(dest_field "$id" type)" \
              --arg path "$(dest_field "$id" path)" \
              --argjson keep "$(dest_field "$id" keep || true)" \
              --argjson st "$(dest_state_public_json "$(dest_state_file "$id")")" \
              '{id:$id, type:$type, locator:$path, keep:$keep, enabled:true,
                lastSuccess:($st.lastSuccess // null), lastError:($st.lastError // null),
                failures:($st.failures // 0), nextAttemptAt:($st.nextAttemptAt // 0)}' 2>/dev/null
      done
      if github_url="$(dest_github_push_url)"; then
        jq -n --argjson st "$(dest_state_public_json "$(dest_state_file github)")" \
              --arg url "$github_url" \
              '{id:"github", type:"github", locator:$url, keep:null, enabled:true,
                lastSuccess:($st.lastSuccess // null), lastError:($st.lastError // null),
                failures:($st.failures // 0), nextAttemptAt:($st.nextAttemptAt // 0)}' 2>/dev/null
      fi
    } | jq -s '.'
}

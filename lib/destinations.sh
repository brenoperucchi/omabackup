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

# _push_github's own timeout and output cap -- flagged by marketplace security
# review (2026-09-06, https://github.com/omacom/omarchy-plugin-marketplace/issues/3968):
# `git push` ran with no timeout of its own, and omabackup-push.service has no
# `TimeoutStartSec` either, so an unavailable or hostile configured remote
# could hold the scheduled push timer indefinitely -- worse than the timer
# just failing, since a hung `push` never reaches the backoff/last-error
# bookkeeping that would otherwise tell a user something is wrong. 120s
# matches OMABACKUP_RESTORE_TIMEOUT_SEC's own default (lib/bundle.sh): a
# push has to reach a real remote over the network, same order of magnitude
# of "legitimately slow" as an extraction from slow media, not the ~10s a
# purely local read gets. Same canonical-positive-decimal validation as the
# other two timeout/byte-cap overrides in this project, for the same reason:
# an unvalidated override must never widen into "unlimited."
if [[ "${OMABACKUP_PUSH_TIMEOUT_SEC:-}" =~ ^[1-9][0-9]*$ ]]; then
    DEST_PUSH_TIMEOUT_SEC="$OMABACKUP_PUSH_TIMEOUT_SEC"
else
    DEST_PUSH_TIMEOUT_SEC=120
fi

# 8 KiB of the TAIL of git's own combined stdout+stderr, not the head: the
# useful diagnostic line in a failed push (an auth rejection, a non-fast-
# -forward, a remote hook's own error) is what git prints LAST, and this
# tool has no use for capturing an unbounded, possibly verbose sideband
# stream (progress percentages, a large receive-pack's own chatter). This
# cap is now read from a completed temp FILE (see _push_github's own
# comment for why), never from git's own live stdout -- see the length-
# then-range validation below, same reasoning as ARTIFACT_MANIFEST_MAX_BYTES
# (lib/artifacts.sh): found by review (round omabackup-43, `omabackup-rev`)
# that the bare `^[1-9][0-9]*$` shape check let an override large enough to
# overflow bash's signed 64-bit arithmetic wrap negative once this file's
# own `$(( ... + 1 ))` runs on it -- the exact GNU `head -c` negative-count
# footgun already closed once for OMABACKUP_RESTORE_MAX_BYTES.
DEST_PUSH_OUTPUT_MAX_BYTES_CEILING=1073741824
if [[ "${OMABACKUP_PUSH_OUTPUT_MAX_BYTES:-}" =~ ^[1-9][0-9]*$ ]] \
    && (( ${#OMABACKUP_PUSH_OUTPUT_MAX_BYTES} <= ${#DEST_PUSH_OUTPUT_MAX_BYTES_CEILING} )) \
    && (( 10#$OMABACKUP_PUSH_OUTPUT_MAX_BYTES <= DEST_PUSH_OUTPUT_MAX_BYTES_CEILING )); then
    DEST_PUSH_OUTPUT_MAX_BYTES="$OMABACKUP_PUSH_OUTPUT_MAX_BYTES"
else
    DEST_PUSH_OUTPUT_MAX_BYTES=8192
fi

# The visibility probe's own bound (docs/PLAN.md Phase 1, T89). Same lesson as
# the push timeout above, from the same marketplace review: a subprocess that
# talks to the network and has no timeout of its own can hold the hourly timer
# for as long as the far end likes. 10s rather than the push's 120s because
# this is one anonymous GET with the body thrown away, not a transfer -- the
# same order of magnitude as a purely local read. Same canonical-positive-
# -decimal validation as every other override here: an unvalidated value must
# never widen into "unlimited." The probe's OUTPUT needs no byte cap of its
# own: curl is told to discard the body and print only `%{http_code}`, so three
# characters is all it can ever hand back, by construction.
if [[ "${OMABACKUP_REMOTE_PROBE_TIMEOUT_SEC:-}" =~ ^[1-9][0-9]*$ ]]; then
    DEST_PROBE_TIMEOUT_SEC="$OMABACKUP_REMOTE_PROBE_TIMEOUT_SEC"
else
    DEST_PROBE_TIMEOUT_SEC=10
fi

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

# Reduce a remote URL to the GitHub repository it names. Prints OWNER/REPO.
#   0  a GitHub remote, and exactly one owner/repo
#   1  positively not a GitHub remote (the caller leaves it alone)
#   2  cannot be cleared: a GitHub host whose path does NOT reduce to exactly
#      owner/repo, or an address whose host cannot be read plainly at all
#
# One normaliser for every spelling, because the first version of this idea
# (in huey-holdings-llc/omabackup, where it was ported from) matched four
# literal prefixes instead: `http://github.com/o/r`, `https://GitHub.com/o/r`,
# `https://user@github.com/o/r` and `ssh://git@github.com:22/o/r` all read as
# "not GitHub", so no probe ever ran and a possibly public repository was
# pushed to with the gate believing it had nothing to say. Scheme, userinfo,
# port, case and the FQDN root dot are all stripped before the host is compared.
#
# The port of that normaliser then repeated the same mistake one level up, and
# review of PR #1 found it: it still listed the SCHEMES it knew, and everything
# else fell through to status 1. Git knows more than it did. A transport-helper
# prefix (`https::https://github.com/o/r`), the `git+ssh://` and `ssh+git://`
# aliases, and any `<name>://` git would hand to a `git-remote-<name>` helper
# all reach github.com, and all read as "not GitHub". So the scheme is no
# longer consulted at all: whatever comes before `://`, the HOST decides.
#
# The host must be EXACTLY github.com (or ssh.github.com, GitHub's own port-443
# SSH endpoint). No suffix matching: `github.com.attacker.net` is somebody
# else's machine, and asking api.github.com about the path on it would be
# asking about a repository that has nothing to do with where the data goes.
#
# Status 2 exists because "cannot tell" must never collapse into "not GitHub":
#   - `https://github.com/o/r/..` once produced the slug `o/r/..`; curl
#     normalised the dot-segment before sending, the probe asked about a
#     DIFFERENT repository, and that repository's 404 was read as "private".
#     The slug is about to be interpolated into a URL, which is the other
#     reason the character set is anchored and `.`/`..` segments are rejected.
#   - a percent sign in the host. Git and curl both decode it, so
#     `%67ithub.com` IS github.com on the wire while comparing unequal to it
#     here (review, PR #1). It is refused rather than decoded: a second decoder
#     that has to agree with git's byte for byte is a second place to be wrong,
#     and nobody spells a hostname this way by accident.
#   - a transport helper whose address is not a URL (`ext::ssh git@github.com
#     ...`). A helper can reach anywhere, and only a URL says where.
# The caller refuses all three.
#
# Never prints its input: a remote URL may carry a token in its userinfo.
dest_github_slug() {
    local u="$1" rest auth path="" host helper=0
    if [[ "$u" =~ ^[A-Za-z0-9][A-Za-z0-9+.-]*::(.*)$ ]]; then
        u="${BASH_REMATCH[1]}"
        helper=1
    fi
    if [[ "$u" =~ ^[A-Za-z][A-Za-z0-9+.-]*://(.*)$ ]]; then
        rest="${BASH_REMATCH[1]}"
        auth="${rest%%/*}"
        [[ "$rest" == */* ]] && path="${rest#*/}"
    elif (( helper )); then
        return 2
    elif [[ "$u" == *:* ]]; then
        # scp-like `[user@]host:path`. Git's own rule: a colon that comes
        # after a slash belongs to a local path, not to a host.
        auth="${u%%:*}"; path="${u#*:}"
        [[ "$auth" == */* ]] && return 1
    else
        return 1
    fi
    auth="${auth##*@}"
    host="${auth%%:*}"
    [[ "$host" == *%* ]] && return 2
    host="${host,,}"
    host="${host%.}"
    case "$host" in
        github.com|ssh.github.com) ;;
        *) return 1 ;;
    esac
    path="${path%/}"
    path="${path%.git}"
    [[ "$path" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 2
    case "/$path/" in */./*|*/../*) return 2 ;; esac
    printf '%s' "$path"
}

# Ask GitHub, anonymously, whether OWNER/REPO is publicly readable. Prints the
# HTTP status it got (000 when it got none).
#   0  public           (200)
#   1  not publicly readable (404) -- private, or not there at all
#   2  inconclusive     (anything else: rate limit, outage, redirect, no network)
# The tri-state return is probe_hypr_entry's idiom (lib/probes.sh), for the same
# reason: "could not tell" is its own answer and must not be folded into either
# of the other two.
#
# A 404 is NOT proof the repository is private, and nothing here says it is: it
# means "not publicly readable at this exact URL". A repository that does not
# exist yet answers the same way, and a push to it fails on its own.
#
# Every flag is load-bearing:
#   -q                first, so no ~/.curlrc can add a header, a proxy or a
#                     redirect policy behind this function's back
#   no Authorization, --no-netrc
#                     an AUTHENTICATED request returns 200 for the owner's own
#                     private repository, which would invert the gate. This is
#                     also why it is not `gh api`
#   --proto '=https', --max-redirs 0
#                     a rename or transfer answers 301; following it would be
#                     asking about a different repository than the one git is
#                     about to push to, so a redirect is inconclusive
#   --noproxy '*'     an http(s)_proxy variable in a unit's environment must
#                     not get to answer "is this public?" on GitHub's behalf
#   --output /dev/null --write-out '%{http_code}'
#                     bounds the output by construction (see DEST_PROBE_TIMEOUT_SEC)
#   timeout AND --max-time
#                     curl's own limit is the polite one; `timeout --kill-after`
#                     is for a curl that has stopped listening
#
# The status code and curl's exit status are BOTH consulted, and kept apart:
#   - curl prints `000` AND exits non-zero when it cannot connect. The obvious
#     `code=$(curl ...) || code=000` concatenates the two into "000000", which
#     matches none of the arms below for the wrong reason. So the captured text
#     is validated on its own (anything that is not three digits, including the
#     empty output of a killed curl, is 000) and the exit status is read from
#     `$?`, never folded into the string.
#   - the first version stopped there and never looked at the exit status at
#     all, and review of PR #1 found what that cost: curl can print `404` and
#     STILL exit non-zero -- a connection cut after the status line, a timeout
#     once the headers are in -- and an incomplete 404 was read as permission
#     to push. A status code is only an answer if the transfer that carried it
#     finished. Any non-zero exit is inconclusive whatever was printed, and the
#     detail says so (`404, curl exit 18`) so that a 404 in the log is not
#     misread later. `timeout` killing curl lands here too (124 or 137).
dest_remote_visibility() {
    local slug="$1" code crc
    code="$(timeout --kill-after=5s "${DEST_PROBE_TIMEOUT_SEC}s" \
        curl -q --silent --proto '=https' --max-redirs 0 --no-netrc --noproxy '*' \
            --max-time "$DEST_PROBE_TIMEOUT_SEC" --output /dev/null --write-out '%{http_code}' \
            "https://api.github.com/repos/$slug" 2>/dev/null)"
    crc=$?
    [[ "$code" =~ ^[0-9]{3}$ ]] || code=000
    if (( crc != 0 )); then
        printf '%s, curl exit %s' "$code" "$crc"
        return 2
    fi
    printf '%s' "$code"
    case "$code" in
        200) return 0 ;;
        404) return 1 ;;
        *)   return 2 ;;
    esac
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
    if ! rm -f -- "$p.tmp" 2>/dev/null || [[ -e "$p.tmp" || -L "$p.tmp" ]]; then
        return 1
    fi
    printf '%s\n' "$doc" >"$p.tmp" && mv -T -- "$p.tmp" "$p"
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
    if [[ ! -f "$dir/$DEST_STAMP" || -L "$dir/$DEST_STAMP" ]]; then
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
    # -T is as important here as --remove-destination above: it makes the
    # final name one filesystem entry. Without it, a final name changed into
    # a directory (or a symlink to one) between copy and rename receives the
    # temp file inside it instead of being replaced.
    cp --remove-destination "$bundle" "$dir/$name.tmp" 2>/dev/null && mv -T -- "$dir/$name.tmp" "$dir/$name" 2>/dev/null \
        || { rm -f "$dir/$name.tmp" 2>/dev/null; printf 'cannot write into %s' "$dir"; return 1; }
    # The stamp is what lets retention delete here, so it can only be granted to
    # a directory this tool actually owns: empty, or holding nothing but its own
    # bundles. The first version stamped whatever path the config named and then
    # pruned it, which meant the protection documented as "the rule that matters
    # most" wrote its own permission on the way in. Point this at ~/Documents now
    # and bundles still arrive -- nothing is ever deleted there.
    if [[ ! -e "$dir/$DEST_STAMP" && ! -L "$dir/$DEST_STAMP" ]] && _dir_is_ours "$dir" "$name"; then
        # A dangling final stamp is not `-f`, but a redirect would still follow
        # it. Write a fresh temporary entry, then rename one directory entry
        # over the final name; do not grant retention ownership through a link.
        if ! rm -f -- "$dir/$DEST_STAMP.tmp" 2>/dev/null \
            || [[ -e "$dir/$DEST_STAMP.tmp" || -L "$dir/$DEST_STAMP.tmp" ]] \
            || ! printf '%s\n%s\n' "$id" "$(_hostname)" >"$dir/$DEST_STAMP.tmp" 2>/dev/null \
            || ! mv -T -- "$dir/$DEST_STAMP.tmp" "$dir/$DEST_STAMP" 2>/dev/null; then
            rm -f -- "$dir/$DEST_STAMP.tmp" 2>/dev/null
            printf 'could not mark %s for retention\n' "$dir" >&2
        fi
    fi
    # Only now, with the new copy confirmed on disk. "Delete the old, upload the
    # new" is how you arrive at zero copies.
    [[ -f "$dir/$name" ]] || { printf 'copy vanished after write'; return 1; }
    # Only now, and only our own: this used to run right after mkdir, before
    # anything had established the directory was ours -- so pointing the config
    # at somebody's folder deleted their half-written archives on the way in.
    # That is the failure the stamp exists to prevent, one line above the stamp.
    if [[ -f "$dir/$DEST_STAMP" && ! -L "$dir/$DEST_STAMP" ]]; then
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
#
# Wrapped in `timeout --kill-after`, not `timeout` alone -- the same idiom
# _zstd_extract (lib/bundle.sh) and bin/omabackup-tui already use, for the
# same reason: `timeout` by itself sends TERM at the deadline and then WAITS
# for the child, so a `git` stuck in a slow TLS handshake or ignoring TERM
# would make the ceiling not actually hold. `--foreground` is deliberately
# NOT passed: without it, `timeout` runs `git` in its own new process group
# and signals that whole group on expiry, reaping any credential-helper or
# ssh child `git` itself spawned, not just the direct `git` process.
#
# Three rounds (omabackup-41/42/43) tried to make ONE pipe simultaneously
# memory-bounded, never split a credential, AND still surface git's own
# tail as a live diagnostic -- each fix closed one of those three
# properties and reopened a different one, confirmed by review every time:
#
# - truncate-then-redact (the original form) cut a credentialed URL's
#   `scheme://user:` prefix away while leaving `TOKEN@host/path` intact --
#   `dest_redact_output`'s regex needs that prefix to recognize a
#   credential at all, so the fragment sailed through unredacted.
# - redact-then-truncate (round 41's fix) closed that leak but reopened a
#   memory bound: `dest_redact_output` is `sed`, which must buffer a
#   complete LINE before it can emit or redact any of it -- a single
#   pathological line with no newline was no longer bounded by the cap at
#   all. Confirmed live under `ulimit -v 20000`: a real OOM.
# - bound-raw-bytes-then-discard-the-first-line (round 42's fix) closed
#   the memory bound correctly, but discarding the FIRST line only
#   protects a `tail`-shaped capture. This function captures with
#   `head -c`, which keeps the STREAM'S START and cuts its END -- so the
#   line actually at risk of being split is the LAST one, and discarding
#   the first left a truncated later line, credential included, to reach
#   `dest_redact_output` without the trailing `@` its regex needs.
#   Confirmed live (round 43, both reviewers independently): real windows
#   where a complete credential token reaches the terminal/state in the
#   clear. `omabackup-rev-2` tested the obvious next swap (`head`→`tail`)
#   before suggesting it and found IT independently broken by a fourth
#   bug: command substitution strips a trailing newline, so the
#   truncation-detection guard itself under-counts by exactly one byte at
#   a line boundary and never fires.
#
# The user's own call, once all three properties turned out not to be
# simultaneously satisfiable by adjusting one pipe's ordering: drop the
# third property instead of continuing to trade the other two back and
# forth. `git`'s own output is no longer surfaced as a live diagnostic at
# all -- on failure this returns a fixed, generic message, and the real
# (redacted, complete-lines-only) output goes to this project's own
# persistent log (`lib/log.sh`) instead, where a user who wants the detail
# can read it with `omabackup log-tail` / the Settings TUI's own "View
# log" item.
#
# This also sidesteps a SEPARATE bug the same three rounds surfaced but
# never actually fixed (`omabackup-rev`, round 43): piping `git`'s own
# live stdout into `head -c` risks cutting `git` ITSELF off via SIGPIPE if
# it is still writing (progress output, a hook's own chatter) when the
# cap is reached -- unlike `_artifact_manifest_file` reading an already-
# decompressed, static archive, `git push` is a live operation with a
# real side effect, and a `head -c` that closes early could interrupt it
# before it finishes, or before its own exit code can be trusted.
# Redirecting to a plain FILE instead of a pipe never has this problem:
# `git` writes to disk for as long as it needs (bounded only by
# `timeout`, the same wall-clock ceiling as before), and nothing reads
# from it -- let alone stops reading -- until `git` has already exited.
#
# This also eliminates the `pipefail`/`PIPESTATUS` question three rounds
# spent getting right (round 41, `omabackup-rev-2`): there is no pipe
# left at all in the command that actually runs `git`, so its own `$?` is
# the whole story, unconditionally, regardless of any shell's `pipefail`
# setting.
# The privacy gate (docs/PLAN.md Phase 1, T89): nothing is pushed to a GitHub
# repository that is publicly readable, or to one this tool could not ask about.
# Prints a refusal detail and returns 1, or prints nothing and returns 0.
#
# It lives HERE, as the first thing the github driver does, and not in cmd_push:
# a public GitHub remote must not stop a healthy NAS from receiving its bundle
# (docs/DESIGN.md §3, "One destination failing does not invalidate the others"),
# and returning a detail string with a non-zero status is already this driver's
# whole contract -- cmd_push records lastError, applies the backoff and carries
# on to the next destination without learning anything new. That backoff is
# also what keeps an hourly timer from asking GitHub the same question about a
# repository only the user can fix: anonymous requests are limited to 60 an
# hour per address.
#
# EVERY push URL is asked about, not the fetch URL: `git push origin HEAD`
# sends to all of them (see dest_github_push_url), so a private first URL says
# nothing about a public second one. Asked fresh on every push, and the answer
# is kept nowhere: a verdict persisted from an earlier run never authorizes a
# later one.
#
# Scope, deliberately: a push URL that is not GitHub is left alone here. This
# gate can only ask GitHub about GitHub, and blocking every other host by
# default needs an explicit trust record to go with it -- a separate change.
#
# curl is looked for HERE, at the moment there is a question to ask, and not in
# cmd_push's require_tools line. The first version put it there, and review of
# PR #1 found what that did: a machine with only a NAS or a pendrive
# destination, which never asks GitHub anything, was refused its backup over a
# tool it had no use for. Same rule as `verify` on a recovery tty
# (bin/omabackup, "What this tool needs..."): the check belongs to the path
# that needs the tool. With no curl the github destination fails on its own,
# says what to install, and every other destination still gets its bundle.
# "Could not ask" still never reads as "the answer was no".
#
# The detail names the repository. The slug is safe to print where the URL is
# not: dest_github_slug only ever returns [A-Za-z0-9._-]+/[A-Za-z0-9._-]+.
_push_github_gate() {
    local urls url slug code rc seen=" "
    urls="$(git -C "$OMABACKUP_REPO" remote get-url --push --all origin 2>/dev/null)" \
        || { printf 'push skipped: could not read the push URLs of origin'; return 1; }
    while IFS= read -r url; do
        [[ -n "$url" ]] || continue
        slug="$(dest_github_slug "$url")"; rc=$?
        case $rc in
            0) ;;
            1) continue ;;
            *) printf 'push skipped: a push URL of origin cannot be read as exactly one plain owner/repo address, so nobody can check whether it is public'
               return 1 ;;
        esac
        [[ "$seen" == *" ${slug,,} "* ]] && continue
        seen+="${slug,,} "
        type -P curl >/dev/null 2>&1 || {
            printf 'push skipped: curl is needed to ask whether github.com/%s is public -- install with: pacman -S curl' "$slug"
            return 1
        }
        code="$(dest_remote_visibility "$slug")"; rc=$?
        case $rc in
            0) printf 'refusing to push: github.com/%s is publicly readable (HTTP %s)' "$slug" "$code"
               return 1 ;;
            1) ;;
            *) printf 'push skipped: could not confirm that github.com/%s is not public (HTTP %s)' "$slug" "$code"
               return 1 ;;
        esac
    done <<<"$urls"
    return 0
}

_push_github() {
    local tmpfile rc sz raw line gate
    gate="$(_push_github_gate)" || { printf '%s' "$gate"; return 1; }
    tmpfile="$(mktemp)" || { printf 'push failed'; return 1; }
    timeout --kill-after=5s "${DEST_PUSH_TIMEOUT_SEC}s" \
        git -C "$OMABACKUP_REPO" push origin HEAD >"$tmpfile" 2>&1
    rc=$?
    if (( rc == 0 )); then
        rm -f -- "$tmpfile"
        printf '0'
        return 0
    fi
    # Read from the now-complete, on-disk file -- `tail -c` here has none
    # of the live-process risk described above, since `git` has already
    # exited and nothing is left to interrupt. Truncation is detected off
    # the FILE'S OWN byte size (`stat`), not off `${#raw}`'s length: round
    # omabackup-44 (both reviewers, independently) found that command
    # substitution strips `raw`'s trailing newline, and since `git`'s own
    # output always ends in one, `${#raw}` under-counted by exactly one
    # byte on every normal truncation -- the discard-the-first-line guard
    # below never fired, and the leftover leading fragment of a split
    # credential rode on whatever `https://` survived the cut. Same fix,
    # same idiom, as _artifact_manifest_file's own post-pipe size check
    # (lib/artifacts.sh, round omabackup-42): trust `stat`, not a shell
    # string's length. `tail -c`'s own cut lands at the START of what it
    # keeps -- the FIRST line of that chunk is the one that may be split,
    # so it (not the last) is what gets discarded here.
    sz="$(stat -c %s -- "$tmpfile" 2>/dev/null)" || sz=0
    raw="$(tail -c "$(( DEST_PUSH_OUTPUT_MAX_BYTES + 1 ))" -- "$tmpfile" 2>/dev/null)"
    rm -f -- "$tmpfile"
    if (( sz > DEST_PUSH_OUTPUT_MAX_BYTES )); then
        if [[ "$raw" == *$'\n'* ]]; then
            raw="${raw#*$'\n'}"
        else
            raw=""
        fi
    fi
    if [[ -n "$raw" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -n "$line" ]] || continue
            _log_write push output "$(printf '%s' "$line" | dest_redact_output)"
        done <<<"$raw"
    fi
    printf 'push failed (see log for details)'
    return 1
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

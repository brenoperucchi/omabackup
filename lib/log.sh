#!/bin/bash
# A persistent record of what OmaBackup does outside the systemd journal
# (DESIGN.md's `sync`/`push` timers already have a real log --
# `journalctl --user -u omabackup-sync.service -u omabackup-push.service`
# -- and this file deliberately does not duplicate it; both units set
# OMABACKUP_LOG_SKIP=1 so a timer-triggered run writes only to the
# journal). What has no log anywhere today is everything else: an
# interactive Config/Restore TUI session, and any command run by hand.
#
# Config/state split mirrors lib/destinations.sh's own stated principle:
# the user's intent (how many days to keep) lives in config; the events
# themselves are observation, so they live in the state directory.

LOG_DIR="${OMABACKUP_LOG_DIR:-$OMABACKUP_STATE/log}"
LOG_CONFIG_FILE="${OMABACKUP_LOG_CONFIG:-$HOME/.config/omabackup/log.json}"
LOG_RETENTION_DEFAULT_DAYS=30
LOG_RETENTION_MAX_DAYS=3650

# A user-typed decimal that eventually reaches a bash arithmetic context
# (the `find`-by-filename-date cutoff and this file's own bound check).
# Length-bounded before any arithmetic, same reasoning as
# _dest_keep_normalize (lib/destinations.sh): the value must never reach
# `(( ))` as an unbounded-length string.
_log_retention_normalize() {
    local value="$1" normalized
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    normalized="$value"
    while [[ ${#normalized} -gt 1 && ${normalized:0:1} == 0 ]]; do
        normalized="${normalized:1}"
    done
    (( ${#normalized} <= ${#LOG_RETENTION_MAX_DAYS} )) || return 1
    (( 10#$normalized >= 1 && 10#$normalized <= LOG_RETENTION_MAX_DAYS )) || return 1
    printf '%s' "$normalized"
}

_log_retention_valid() {
    _log_retention_normalize "$1" >/dev/null
}

_log_retention_valid_file() {
    [[ -f "$LOG_CONFIG_FILE" ]] || return 1
    local doc; doc="$(cat -- "$LOG_CONFIG_FILE" 2>/dev/null)" || return 1
    [[ -n "$doc" ]] || return 1
    jq -e --argjson max "$LOG_RETENTION_MAX_DAYS" '
      (. | type == "object") and (.schemaVersion == 1)
      and ((.retentionDays | type) == "number")
      and (.retentionDays | floor == .) and (.retentionDays >= 1) and (.retentionDays <= $max)
    ' <<<"$doc" >/dev/null 2>&1
}

# Falls back to the default whenever the file is missing OR present-but-
# invalid -- config show/validate are what tell the user which case they
# are in (_log_retention_valid_file), so this function never has to.
#
# The value that reaches the caller is re-normalized through
# _log_retention_normalize, not just the raw `jq -r`: _log_retention_valid_file
# only checked >= 1, so a hand-edited log.json with an absurd number (or one
# jq prints in exponential notation) used to pass as "valid" and reach the
# cutoff-date arithmetic downstream unbounded -- found by review. Falling
# through to the default on a normalize failure keeps the "invalid file"
# case behaving exactly like "missing file" instead of a third, undefined
# outcome.
_log_retention_days() {
    local raw normalized
    if _log_retention_valid_file; then
        raw="$(jq -r '.retentionDays' -- "$LOG_CONFIG_FILE" 2>/dev/null)"
        if normalized="$(_log_retention_normalize "$raw" 2>/dev/null)"; then
            printf '%s' "$normalized"
            return 0
        fi
    fi
    printf '%s' "$LOG_RETENTION_DEFAULT_DAYS"
}

_log_config_write() {
    local days="$1"
    _config_atomic_write "$LOG_CONFIG_FILE" \
        "$(jq -n --argjson d "$days" '{schemaVersion:1,retentionDays:$d}')"
}

# The append primitive. Best-effort by design: a full disk or a briefly
# held lock must never turn a successful backup into a reported failure,
# so every internal command's stderr is contained and this always returns
# 0 regardless of what happened inside -- explicit shared premise from
# both reviewers in the design consultation (omabackup-10).
#
# One file per calendar day, named directly by its date -- no "current"
# file, no rename step. A rename-on-rollover design (the first draft of
# this plan) needs the exact same exclusive lock pruning already needs,
# and would add its own race window for zero benefit: nothing here needs
# a stable tail-able path.
#
# Pruning compares each file's DATE, taken from its own name, against a
# cutoff -- not `find -mtime`, whose "+N" semantics are "+N*24h" with
# truncation (`-mtime +30` keeps 31 days) and which a touch/restore can
# silently perturb. ISO dates sort correctly as strings, so this is a
# plain string comparison, giving exact "N calendar days" -- what was
# actually asked for. Appends do not need the lock (a short line under
# O_APPEND is already atomic below PIPE_BUF); only deletion needs to be
# exclusive between concurrent writers, so only pruning runs inside it.
_log_write() {
    local action outcome detail today line lock_fd cutoff f fdate
    action="$(tui_sanitize_field "${1:-}")"
    outcome="$(tui_sanitize_field "${2:-}")"
    detail="$(tui_sanitize_field "${3:-}")"
    {
        mkdir -p -- "$LOG_DIR" 2>/dev/null
        chmod 700 -- "$LOG_DIR" 2>/dev/null

        # One captured instant for both the filename's date and the line's
        # timestamp, not two separate `date` calls -- narrows (does not
        # close; see the flock note below) the window a writer that
        # straddles midnight could otherwise land in.
        _log_now_epoch="$EPOCHSECONDS"
        today="$(date -d "@$_log_now_epoch" +%F 2>/dev/null || date +%F)"
        local logfile="$LOG_DIR/omabackup-$today.log" first_of_day=1
        [[ -f "$logfile" ]] && first_of_day=0
        line="$(date -d "@$_log_now_epoch" -Iseconds 2>/dev/null || date -Iseconds 2>/dev/null)  ${action}  ${outcome}"
        [[ -n "$detail" ]] && line+="  ${detail}"
        printf '%s\n' "$line" >>"$logfile"
        chmod 600 -- "$logfile" 2>/dev/null

        # Pruning only ever removes files strictly older than today, so
        # running it more than once on the same calendar day can only ever
        # repeat the same, already-done work -- gated on this being the
        # first write to actually CREATE today's file, not every single
        # call, which is what a busy machine (or this project's own test
        # suite, driving hundreds of invocations in the same second) would
        # otherwise pay a flock + directory scan for on every write.
        #
        # Consequence, noted by review: retention only actually runs when
        # something writes. Both systemd units set OMABACKUP_LOG_SKIP=1
        # (they never write here at all), so on a machine where nobody
        # opens Settings/Restore or runs a command by hand, "keep N days"
        # is closer to "keep N days of write activity" -- nothing grows
        # either, so the practical impact is small, but it is worth
        # knowing if a mostly-idle machine still shows old files past N.
        #
        # `-w 5`, not a blocking `flock -x`: this runs inside an EXIT trap,
        # after the wrapped command has already finished -- best-effort
        # pruning blocking that exit path indefinitely (found by review: a
        # logger suspended while holding the lock would do exactly that)
        # is worse than skipping one day's prune and catching up on the
        # next write.
        if (( first_of_day )); then
            lock_fd=""
            exec {lock_fd}>"$LOG_DIR/.prune.lock"
            if [[ -n "$lock_fd" ]] && flock -x -w 5 "$lock_fd"; then
                cutoff="$(date -d "-$(( $(_log_retention_days) - 1 )) days" +%F 2>/dev/null)"
                if [[ -n "$cutoff" ]]; then
                    for f in "$LOG_DIR"/omabackup-*.log; do
                        [[ -f "$f" ]] || continue
                        fdate="$(basename -- "$f")"
                        fdate="${fdate#omabackup-}"; fdate="${fdate%.log}"
                        [[ "$fdate" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
                        [[ "$fdate" < "$cutoff" ]] && rm -f -- "$f"
                    done
                fi
                flock -u "$lock_fd"
            fi
            [[ -n "$lock_fd" ]] && eval "exec ${lock_fd}>&-"
        fi
    } 2>/dev/null
    return 0
}

# always-policy: every invocation gets one line, success or failure. A
# non-empty `signal` overrides the exit-code-derived text -- a dispatch-
# level signal trap sets rc to the 128+n convention (130 for INT, etc.)
# purely so the process exits with the right code; the human-readable
# outcome should say which signal actually happened, not "exit 130".
_log_run_always() {
    local action="$1" rc="$2" duration="$3" signal="${4:-}" outcome
    if [[ -n "$signal" ]]; then
        outcome="failed (signal $signal)"
    elif (( rc == 0 )); then
        outcome="ok"
    else
        outcome="failed (exit $rc)"
    fi
    _log_write "$action" "$outcome" "${duration}s"
}

# failure-policy: coalesced. A command like `verify`/`status` is polled by
# the panel every refreshIntervalSec (default 900s, floor 60s) -- logging
# every clean poll is already skipped by the caller only invoking this on
# a non-zero exit, but a PERSISTENT failure would still write one
# identical line per poll forever, burying the one event that matters (the
# transition into failure) under repetitions of itself. So this writes
# only on a state CHANGE (ok->failed or failed->ok), tracked in a small
# per-action marker file, plus one heartbeat line per calendar day while
# still failing -- an ongoing failure stays visible in every day's file,
# not only the day it started.
#
# The whole read-last-state / decide / write / update-state sequence runs
# under a per-action lock (`-w 5`, same "never hang the exit path indefinitely"
# reasoning as the pruning lock above): two concurrent first observations
# of the same action, or a recovery racing a fresh failure, used to be able
# to interleave and leave `.last-*` inconsistent with what was actually
# logged -- found by review. Per-action, not one global lock, so `verify`
# and `status` never wait on each other.
_log_run_on_failure() {
    local action="$1" rc="$2" signal="${3:-}" state_file lock_fd outcome last today last_day
    mkdir -p -- "$LOG_DIR" 2>/dev/null
    state_file="$LOG_DIR/.last-$(printf '%s' "$action" | LC_ALL=C tr -c 'A-Za-z0-9_-' '_')"
    (( rc == 0 )) && outcome="ok" || outcome="failed"
    today="$(date +%F)"
    {
        lock_fd=""
        exec {lock_fd}>"$state_file.lock"
        if [[ -n "$lock_fd" ]] && flock -x -w 5 "$lock_fd"; then
            last="$(cat -- "$state_file" 2>/dev/null)"
            if [[ "$last" != "$outcome" ]]; then
                if (( rc == 0 )); then
                    _log_write "$action" "ok" ""
                elif [[ -n "$signal" ]]; then
                    _log_write "$action" "failed (signal $signal)" ""
                else
                    _log_write "$action" "failed (exit $rc)" ""
                fi
                printf '%s' "$outcome" >"$state_file" 2>/dev/null
                printf '%s' "$today" >"$state_file.day" 2>/dev/null
            elif [[ "$outcome" == "failed" ]]; then
                last_day="$(cat -- "$state_file.day" 2>/dev/null)"
                if [[ "$last_day" != "$today" ]]; then
                    _log_write "$action" "still failing (exit $rc)" ""
                    printf '%s' "$today" >"$state_file.day" 2>/dev/null
                fi
            fi
            flock -u "$lock_fd"
        fi
        [[ -n "$lock_fd" ]] && eval "exec ${lock_fd}>&-"
    } 2>/dev/null
    return 0
}

# The read side this file never had until now -- everything above only
# ever writes. Walks day-files NEWEST first (same glob shape the pruning
# loop above already uses), pulling only as many lines as still needed
# from each via `tail`, until `n` is satisfied or files run out -- so a
# request for the last 5 lines never reads an entire month of history
# just to throw most of it away. Each file's own chunk is prepended to the
# accumulator (not appended), since files are visited newest-first but the
# final output must read oldest-to-newest, the same direction the log
# itself is written in.
#
# No locking: an append under O_APPEND is already atomic below PIPE_BUF
# (this file's own header comment on `_log_write` already establishes
# this), so a read racing a write can only ever see a complete line or
# none of it -- never a torn one. Lines are already sanitized at write
# time (`tui_sanitize_field`, inside `_log_write`), so nothing further is
# needed before they reach a terminal or become a JSON array element.
LOG_TAIL_MAX_LINES=100000

_log_tail() {  # _log_tail <n> -> up to <n> most recent log lines, oldest first
    local n="$1" f chunk lines_in_chunk out=""
    # A separate `local` statement, not `local n="$1" remaining="$n"` on one
    # line -- confirmed live that bash does NOT see a variable just assigned
    # earlier in the SAME `local` statement when expanding a later one on
    # that same line (`local a=1 b=$a` in one statement leaves `b` empty;
    # splitting into two statements works). A real, easy-to-miss pitfall,
    # not a stylistic choice -- found by review (round omabackup-33,
    # `omabackup-rev-2`) to ALSO be the reason `_into_cleanup`
    # (bin/omabackup) had silently never removed anything, in already-
    # shipped code discovered by a repo-wide scan for the same shape.
    #
    # Length-bounded against LOG_TAIL_MAX_LINES before ANY arithmetic
    # context, same reasoning and shape as _log_retention_normalize just
    # above (and _dest_keep_normalize, lib/destinations.sh) -- found by
    # review (round omabackup-33, `omabackup-rev`, reproduced live):
    # `^[1-9][0-9]*$` alone accepts a decimal so large it overflows bash's
    # signed 64-bit `(( ))` (e.g. 9223372036854775808 wraps to a large
    # NEGATIVE number), making `remaining <= 0` true immediately and
    # returning success with zero lines -- silently wrong, not just
    # rejected.
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || return 1
    (( ${#n} <= ${#LOG_TAIL_MAX_LINES} )) || return 1
    (( 10#$n <= LOG_TAIL_MAX_LINES )) || return 1
    local remaining="$n"
    # Bash's own glob into an array, not `for f in $(command ls ... | sort
    # -r)` -- found by review (round omabackup-33, `omabackup-rev`): piping
    # through an unquoted command substitution word-splits the result,
    # which breaks on a LOG_DIR containing a space (a real, if unusual,
    # possible value -- OMABACKUP_LOG_DIR/OMABACKUP_STATE are user-
    # settable). `nullglob` avoids a literal, unmatched glob pattern
    # becoming its own single "file" when no logs exist yet.
    #
    # nullglob's prior state is saved and restored via `shopt -p`/`eval`,
    # the exact idiom lib/tui.sh already uses for trap save/restore
    # (`trap -p` / `_tui_restore_saved_traps`) -- NOT `local -`, which a
    # round-34 review suggestion proposed and this project verified live
    # does NOT do what it sounds like it should: `local -` only scopes
    # `set -o` options (the ones in `$-`), never `shopt`-managed ones like
    # `nullglob` -- confirmed directly (`local -; shopt -s nullglob`
    # inside a function still leaks nullglob=on to the caller after
    # return). Nothing in this project currently enables nullglob before
    # calling this function, so the leak was latent, not live -- still
    # worth closing properly rather than with a fix that only looks right.
    local nullglob_was
    nullglob_was="$(shopt -p nullglob)"
    shopt -s nullglob
    local -a files=()
    files=( "$LOG_DIR"/omabackup-*.log )
    eval "$nullglob_was"
    local -a sorted=()
    if (( ${#files[@]} > 0 )); then
        # NUL-delimited, not newline-delimited -- found by review (round
        # omabackup-34, `omabackup-rev`; independently confirmed by
        # `omabackup-rev-2` as a pre-existing limitation the `ls`-based
        # version already had, not a regression this round introduced): a
        # LOG_DIR containing an embedded newline would otherwise split
        # ONE path into two lines here, and `mapfile` would reconstruct
        # two broken fragments instead of one real path. `sort -z` and
        # `mapfile -d ''` handle the NUL-separated form directly.
        #
        # `sort`'s own exit status, actually checked -- not just an
        # array-length comparison after the fact. Found by review (round
        # omabackup-36, `omabackup-rev`): this function's own PREVIOUS
        # round-35 fix compared `${#sorted[@]}` against `${#files[@]}`
        # after reading through a process substitution, reasoning that
        # "sort can only reorder, never add or drop an element" -- true,
        # but incomplete: a `sort` that emits all N records and THEN
        # exits non-zero (or one that emits N records with content
        # corrupted -- e.g. one path duplicated, another dropped, still N
        # total) satisfies the count check while still being a real
        # failure, and the array-length approach cannot detect either.
        # Fixed by not using a process substitution at all: `sort`'s
        # output is written to a real temp file, whose write DIRECTLY
        # checks `sort`'s own exit status (as the last stage of a real
        # pipe redirected to a file, its status is `$?` regardless of
        # `pipefail`), and `mapfile` then reads that already-verified file
        # via plain redirection -- no subshell involved, so the earlier
        # concern (`mapfile` as the last stage of a literal pipe loses its
        # own variable) does not apply here either.
        local sort_tmp
        sort_tmp="$(mktemp)" || return 1
        if ! printf '%s\0' "${files[@]}" | LC_ALL=C sort -z -r >"$sort_tmp"; then
            rm -f "$sort_tmp"
            return 1
        fi
        mapfile -d '' -t sorted <"$sort_tmp"
        rm -f "$sort_tmp"
    fi
    for f in "${sorted[@]}"; do
        (( remaining <= 0 )) && break
        [[ -f "$f" ]] || continue
        # tail's own exit status is now checked -- found by review (round
        # omabackup-34, `omabackup-rev`): the previous `[[ -z "$chunk" ]]
        # && continue` treated an unreadable-but-existing file (wrong
        # permissions, or any other real read failure) identically to a
        # legitimately empty one, so `log-tail`/`recentLog` reported
        # "nothing logged" for a log that genuinely could not be read --
        # the same "failure silently read as absence" shape this
        # project's own PLAN.md already treats as a real class of bug
        # elsewhere. A read failure now aborts the whole call, EXCEPT the
        # one case that must stay benign: the file raced away between the
        # `[[ -f ]]` check above and this `tail` call (this project's own
        # pruning, under its own lock, could remove a day-file exactly
        # this old between the two) -- re-checked with a second `[[ -f ]]`
        # so that specific, narrow race keeps behaving like "this file had
        # nothing," not a hard error.
        if ! chunk="$(tail -n "$remaining" -- "$f" 2>/dev/null)"; then
            [[ -f "$f" ]] || continue
            return 1
        fi
        [[ -z "$chunk" ]] && continue
        # `wc`'s own exit status checked too -- found by review (round
        # omabackup-35, `omabackup-rev`): if `wc` failed, the previous code
        # let `lines_in_chunk` become an empty string, which bash
        # arithmetic silently treats as 0 -- `remaining` would then never
        # decrease, and one day-file could contribute far more than its
        # fair share of the N-line budget instead of this call failing
        # outright the way a genuine tool failure should.
        lines_in_chunk="$(printf '%s\n' "$chunk" | wc -l)" || return 1
        [[ "$lines_in_chunk" =~ ^[0-9]+$ ]] || return 1
        if [[ -n "$out" ]]; then out="$chunk"$'\n'"$out"; else out="$chunk"; fi
        remaining=$(( remaining - lines_in_chunk ))
    done
    [[ -n "$out" ]] && printf '%s\n' "$out"
    return 0
}

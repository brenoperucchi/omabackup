# Regressions for lib/log.sh -- the persistent record of what OmaBackup does
# outside the systemd journal. `sync`/`push`'s timer-triggered runs already
# have a real log (`journalctl --user -u omabackup-sync.service -u
# omabackup-push.service`); this file covers what has none at all: an
# interactive Config/Restore TUI session, and any command run by hand.
#
# This module went through a design consultation (herdr-ask round
# omabackup-10) before any code was written; two findings from that round
# are the reason the architecture looks the way it does, not a post-call
# wrapper or a plain rename-on-rollover file: `die()` bypasses a post-call
# wrapper entirely (an EXIT trap is required), and Panel.qml's own CLI
# resolution prefers PATH over the plugin directory (so the TUI wrapper
# calls the CLI it already trusts instead of deriving OMABACKUP_ROOT).

OB="$(realpath "$PWD/bin/omabackup")"

_log_home() {
    local h; h="$(mktemp -d)"
    mkdir -p "$h/repo" "$h/stub"
    cat >"$h/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/app"]}]}
JSON
    mkdir -p "$h/.config/app"
    printf 'x\n' >"$h/.config/app/f.txt"
    printf '{"schemaVersion":1,"destinations":[]}\n' >"$h/dest.json"
    printf '#!/bin/bash\nexit 0\n' >"$h/stub/systemctl"
    chmod +x "$h/stub/systemctl"
    git init -q "$h/repo"
    git -C "$h/repo" config user.email t@t; git -C "$h/repo" config user.name t
    printf '%s' "$h"
}

_log_env() {  # _log_env <home> <args...>
    local h="$1"; shift
    HOME="$h" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$h/g.json" \
        OMABACKUP_STATE="$h/.state" OMABACKUP_REPO="$h/repo" \
        OMABACKUP_DESTINATIONS="$h/dest.json" OMABACKUP_SYSTEMCTL="$h/stub/systemctl" \
        XDG_RUNTIME_DIR=/nonexistent "$OB" "$@" 2>&1
}

_log_dir() { printf '%s/.state/log' "$1"; }
_log_today_file() { printf '%s/omabackup-%s.log' "$(_log_dir "$1")" "$(date +%F)"; }

# The regression that actually proves the fix for the original design's
# most severe bug: die() (bin/omabackup:98) calls `exit 1` directly, so a
# wrapper of the shape "call the function, then log after it returns"
# never runs for anything that fails via die -- which is most real
# failures in this codebase. This drives a REAL die() path (an
# OMABACKUP_REPO that is not a git repository), not a stub that merely
# `return`s non-zero.
DIE_HOME="$(_log_home)"
HOME="$DIE_HOME" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$DIE_HOME/g.json" \
    OMABACKUP_STATE="$DIE_HOME/.state" OMABACKUP_REPO="$DIE_HOME/does-not-exist" \
    OMABACKUP_DESTINATIONS="$DIE_HOME/dest.json" OMABACKUP_SYSTEMCTL="$DIE_HOME/stub/systemctl" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" sync >/dev/null 2>&1
DIE_LOG="$(_log_today_file "$DIE_HOME")"

it "a command that fails via die() is still logged, not just one that returns non-zero"
[[ -f "$DIE_LOG" ]] && ok || fail "no log file was written for a die()-triggered failure"
assert_contains "$(cat "$DIE_LOG" 2>/dev/null)" "sync  failed (exit 1)"

# Per-day filename, no rename step: a real write lands in a file named
# directly after today's date.
FILENAME_HOME="$(_log_home)"
_log_env "$FILENAME_HOME" sync >/dev/null 2>&1
it "a logged action lands in a file named directly after today's date"
[[ -f "$(_log_today_file "$FILENAME_HOME")" ]] \
    && ok || fail "expected $(_log_today_file "$FILENAME_HOME") to exist"
[[ ! -f "$(_log_dir "$FILENAME_HOME")/omabackup.log" ]] \
    && ok || fail "a stale 'current' filename exists -- rename-on-rollover was supposed to be gone"

# Pruning at the exact boundary, not only a file "far" on either side: a
# file dated exactly `today - retentionDays` is pruned; one dated
# `today - (retentionDays - 1)` is kept. retentionDays=5 here.
PRUNE_HOME="$(_log_home)"
mkdir -p "$(_log_dir "$PRUNE_HOME")"
PRUNE_KEEP_DATE="$(date -d '-4 days' +%F)"
PRUNE_DROP_DATE="$(date -d '-5 days' +%F)"
printf 'old but kept\n' >"$(_log_dir "$PRUNE_HOME")/omabackup-$PRUNE_KEEP_DATE.log"
printf 'old and pruned\n' >"$(_log_dir "$PRUNE_HOME")/omabackup-$PRUNE_DROP_DATE.log"
_log_env "$PRUNE_HOME" config set log-retention-days 5 >/dev/null 2>&1
_log_env "$PRUNE_HOME" sync >/dev/null 2>&1

it "pruning keeps a file exactly (retentionDays - 1) days old and drops one exactly retentionDays old"
[[ -f "$(_log_dir "$PRUNE_HOME")/omabackup-$PRUNE_KEEP_DATE.log" ]] \
    && ok || fail "a file within the retention window was pruned"
[[ ! -f "$(_log_dir "$PRUNE_HOME")/omabackup-$PRUNE_DROP_DATE.log" ]] \
    && ok || fail "a file exactly at the retention boundary was not pruned"

# config set log-retention-days: persists, validates, and config show
# reports an invalid log.json explicitly rather than silently presenting
# the fallback default as the user's real setting.
RETENTION_HOME="$(_log_home)"
_log_env "$RETENTION_HOME" config set log-retention-days 10 >/dev/null 2>&1
RETENTION_SHOW="$(_log_env "$RETENTION_HOME" config show --json)"

it "config set log-retention-days persists and config show reflects it"
assert_eq "$(jq -r '.log.retentionDays' <<<"$RETENTION_SHOW")" "10"
assert_eq "$(jq -r '.log.configValid' <<<"$RETENTION_SHOW")" "true"
assert_eq "$(jq -r '.retentionDays' "$RETENTION_HOME/.config/omabackup/log.json")" "10"

RETENTION_BAD_RC=0
_log_env "$RETENTION_HOME" config set log-retention-days 0 >/dev/null 2>&1 || RETENTION_BAD_RC=$?
RETENTION_BAD_RC2=0
_log_env "$RETENTION_HOME" config set log-retention-days notanumber >/dev/null 2>&1 || RETENTION_BAD_RC2=$?

it "log-retention-days rejects zero and non-numeric input, without changing the persisted value"
[[ $RETENTION_BAD_RC -ne 0 && $RETENTION_BAD_RC2 -ne 0 ]] \
    && ok || fail "invalid retention input was accepted"
assert_eq "$(jq -r '.retentionDays' "$RETENTION_HOME/.config/omabackup/log.json")" "10"

INVALID_CFG_HOME="$(_log_home)"
mkdir -p "$INVALID_CFG_HOME/.config/omabackup"
printf 'not json\n' >"$INVALID_CFG_HOME/.config/omabackup/log.json"
INVALID_CFG_SHOW="$(_log_env "$INVALID_CFG_HOME" config show --json)"

it "config show reports an invalid log.json explicitly instead of silently presenting the default as fact"
assert_eq "$(jq -r '.log.configValid' <<<"$INVALID_CFG_SHOW")" "false"
assert_eq "$(jq -r '.log.retentionDays' <<<"$INVALID_CFG_SHOW")" "30"

# Coalescing: verify/status polled while persistently failing writes one
# transition line, then one heartbeat per day -- not one line per poll.
# Exercised directly against the primitive (matching this codebase's own
# established style for pinning a race/throttle condition -- see
# test/config.test.sh's _config_repo_init_eligible race regression) since
# driving three real, slightly-apart `verify` failures through the full
# panel-polling interval is not practical in a test.
COALESCE_HOME="$(_log_home)"
COALESCE_OUT="$(HOME="$COALESCE_HOME" OMABACKUP_STATE="$COALESCE_HOME/.state" bash -c '
    source lib/tui.sh; source lib/log.sh
    _log_run_on_failure verify 1
    _log_run_on_failure verify 1
    _log_run_on_failure verify 1
    _log_run_on_failure verify 0
')"
COALESCE_LOG="$(_log_today_file "$COALESCE_HOME")"
COALESCE_LINES="$(grep -c '  verify  ' "$COALESCE_LOG" 2>/dev/null || printf 0)"

it "three consecutive same-day failures coalesce into one transition line, not three"
assert_eq "$COALESCE_LINES" "2"
assert_contains "$(cat "$COALESCE_LOG" 2>/dev/null)" "verify  failed (exit 1)"
assert_contains "$(cat "$COALESCE_LOG" 2>/dev/null)" "verify  ok"

# status/verify: the first-ever observation writes one "ok" baseline (there
# is no prior state to compare against, so `_log_run_on_failure` treats
# "nothing recorded yet" -> "ok" as a real transition too) -- but repeating
# the same clean result afterwards writes nothing more. A declared path
# merely being missing is only ever a `warn` finding (report()'s exit
# status is `ok:($fail==0)`), so a real `fail`-level run needs the group's
# own probe field to be unreadable -- the exact fixture test/verify.test.sh
# already established for this: a jq stub that fails only the specific
# `.probe` query `group_field` makes.
CLEAN_HOME="$(_log_home)"
_log_env "$CLEAN_HOME" status >/dev/null 2>&1
_log_env "$CLEAN_HOME" verify >/dev/null 2>&1
CLEAN_FIRST_COUNT="$(grep -c '  status  ok\|  verify  ok' "$(_log_today_file "$CLEAN_HOME")" 2>/dev/null || printf 0)"
_log_env "$CLEAN_HOME" status >/dev/null 2>&1
_log_env "$CLEAN_HOME" verify >/dev/null 2>&1
CLEAN_SECOND_COUNT="$(grep -c '  status  ok\|  verify  ok' "$(_log_today_file "$CLEAN_HOME")" 2>/dev/null || printf 0)"

it "status/verify log a one-time ok baseline on first observation, then nothing more while still clean"
assert_eq "$CLEAN_FIRST_COUNT" "2"
assert_eq "$CLEAN_SECOND_COUNT" "2"

FAIL_HOME="$(_log_home)"
cat >"$FAIL_HOME/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,
  "paths":["~/.config/app"],"probe":"shell-json"}]}
JSON
{ printf '#!/bin/bash\n'
  printf 'for a in "$@"; do [[ "$a" == *".[\$f] // empty"* ]] && exit 9; done\n'
  printf 'exec %s "$@"\n' "$(command -v jq)"
} >"$FAIL_HOME/stub/jq"; chmod +x "$FAIL_HOME/stub/jq"
FAIL_VERIFY_RC=0
HOME="$FAIL_HOME" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$FAIL_HOME/g.json" \
    OMABACKUP_STATE="$FAIL_HOME/.state" OMABACKUP_REPO="$FAIL_HOME/repo" \
    OMABACKUP_DESTINATIONS="$FAIL_HOME/dest.json" \
    PATH="$FAIL_HOME/stub:$PATH" XDG_RUNTIME_DIR=/nonexistent \
    "$OB" verify >/dev/null 2>&1 || FAIL_VERIFY_RC=$?

it "a failing verify (fail-level, not just warn) writes exactly one entry"
(( FAIL_VERIFY_RC != 0 )) && ok || fail "verify unexpectedly succeeded despite the unreadable probe field"
assert_contains "$(cat "$(_log_today_file "$FAIL_HOME")" 2>/dev/null)" "verify  failed"

# restore without --apply: the original design's scope table said "never"
# for a preview call, silently dropping a refused restore -- e.g. "this
# artifact does not verify -- refusing to restore from it", one of the
# most useful lines this tool produces. A preview against a nonexistent
# artifact file exercises the same failure class without needing a real
# bundle.
RESTORE_HOME="$(_log_home)"
RESTORE_RC=0
_log_env "$RESTORE_HOME" restore "$RESTORE_HOME/no-such-artifact.tar.zst" >/dev/null 2>&1 || RESTORE_RC=$?

it "a failed restore preview (no --apply) is logged, closing the original scope gap"
(( RESTORE_RC != 0 )) && ok || fail "restore preview against a nonexistent artifact unexpectedly succeeded"
assert_contains "$(cat "$(_log_today_file "$RESTORE_HOME")" 2>/dev/null)" "restore  failed"

# OMABACKUP_LOG_SKIP: what the systemd units set, so a timer-triggered
# sync/push does not duplicate what journalctl already has.
SKIP_HOME="$(_log_home)"
HOME="$SKIP_HOME" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$SKIP_HOME/g.json" \
    OMABACKUP_STATE="$SKIP_HOME/.state" OMABACKUP_REPO="$SKIP_HOME/repo" \
    OMABACKUP_DESTINATIONS="$SKIP_HOME/dest.json" OMABACKUP_SYSTEMCTL="$SKIP_HOME/stub/systemctl" \
    OMABACKUP_LOG_SKIP=1 XDG_RUNTIME_DIR=/nonexistent "$OB" sync >/dev/null 2>&1

it "OMABACKUP_LOG_SKIP (set by the systemd units) writes nothing, so the journal is not duplicated"
[[ ! -d "$(_log_dir "$SKIP_HOME")" ]] \
    && ok || fail "a timer-shaped invocation wrote to the file log despite OMABACKUP_LOG_SKIP"

# Both systemd units actually set it -- not just documented as intended.
it "both systemd units set OMABACKUP_LOG_SKIP, so a real timer run does not duplicate the journal"
assert_contains "$(cat systemd/omabackup-sync.service)" "Environment=OMABACKUP_LOG_SKIP=1"
assert_contains "$(cat systemd/omabackup-push.service)" "Environment=OMABACKUP_LOG_SKIP=1"

# stderr containment: an internal _log_write failure must not leak into the
# wrapped command's own stderr, and must not change its exit code. A plain
# FILE occupying the log directory's own path, not a permission bit, is
# what actually reproduces this: _log_write's first act is `chmod 700 --
# "$LOG_DIR"`, which -- as the owner -- succeeds regardless of the
# directory's current mode, silently undoing a chmod-000 sabotage before
# the write it was meant to block. `mkdir -p` failing because something
# already occupies that exact path is not something a chmod can fix.
STDERR_HOME="$(_log_home)"
mkdir -p "$STDERR_HOME/.state"
printf 'not a directory\n' >"$STDERR_HOME/.state/log"
STDERR_OUT="$(_log_env "$STDERR_HOME" sync 2>&1)"; STDERR_RC=$?

it "an unwritable log directory does not leak into the wrapped command's stderr or change its exit code"
assert_not_contains "$STDERR_OUT" "Permission denied"
assert_not_contains "$STDERR_OUT" "mkdir:"
assert_not_contains "$STDERR_OUT" "flock:"
(( STDERR_RC == 0 )) && ok || fail "an unwritable log directory changed sync's own exit code"

# The actual fix for the motivating case: bin/omabackup-tui calls the CLI
# it already trusts on SIGINT, and the resulting log-event distinguishes a
# signal from a plain exit code. Driven through a real PTY (script -qec),
# with the real CLI (not a stub) as $cli, so `log-event` genuinely runs
# through bin/omabackup's own dispatch -- not a fixture pretending to.
TUI_SIG_HOME="$(_log_home)"
TUI_SIG_TOKEN="sigtest-$$"
mkdir -p "$TUI_SIG_HOME/.config/systemd/user"
TUI_SIG_READY="$TUI_SIG_HOME/ready"
mkfifo "$TUI_SIG_HOME/input"
# `env --default-signal=INT,QUIT` immediately before the wrapper, inside
# the script -qec string, not outside it: bash cannot `trap` its way out of
# a SIGINT it inherited as SIG_IGN at its own startup (POSIX; see this
# file's own comment on the CLI child for the same rule) -- bin/omabackup-
# tui is itself a bash script launched as an async job here, so without
# this reset ITS OWN top-level `trap ... INT` (bin/omabackup-tui) can never
# fire, regardless of how the signal is later delivered. Matches
# test/panel.test.sh's already-proven "Ctrl-C reaches the supervised CLI"
# regression exactly, one layer up (that one resets it for the CLI child;
# this one needs it reset for the wrapper itself).
env HOME="$TUI_SIG_HOME" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$TUI_SIG_HOME/g.json" \
    OMABACKUP_STATE="$TUI_SIG_HOME/.state" OMABACKUP_REPO="$TUI_SIG_HOME/repo" \
    OMABACKUP_DESTINATIONS="$TUI_SIG_HOME/dest.json" OMABACKUP_SYSTEMCTL="$TUI_SIG_HOME/stub/systemctl" \
    XDG_RUNTIME_DIR=/nonexistent \
    script -qec "env --default-signal=INT,QUIT '$PWD/bin/omabackup-tui' '$OB' config $TUI_SIG_TOKEN" /dev/null \
    <"$TUI_SIG_HOME/input" >"$TUI_SIG_HOME/script.log" 2>&1 &
TUI_SIG_SCRIPT_PID=$!
exec 9>"$TUI_SIG_HOME/input"
TUI_SIG_READY_OK=0
for _ in {1..100}; do
    grep -q 'Choose an option' "$TUI_SIG_HOME/script.log" 2>/dev/null && { TUI_SIG_READY_OK=1; break; }
    /usr/bin/sleep 0.05
done
# The literal Ctrl-C byte into the PTY, not `kill -INT <wrapper-pid>`:
# found live that a direct kill is silently swallowed here. Bash sets
# SIGINT to SIG_IGN for an asynchronous (`&`) job, and that disposition is
# inherited at process-start time down through `script` to the wrapper --
# a `trap` cannot override a SIG_IGN a bash process inherited when it
# started (POSIX). `\003` sidesteps this entirely: the kernel's own tty
# line discipline generates SIGINT from the special character and delivers
# it to the pty's foreground process group directly, which is exactly the
# mechanism test/panel.test.sh's own "Ctrl-C reaches the supervised CLI"
# regression already relies on -- this mirrors it rather than reinventing
# a second way to deliver the same signal.
printf '\003' >&9
# Generous budget: _on_exit's own log-event call is itself bounded by
# `timeout --kill-after=2s 5s` (bin/omabackup-tui), so the wrapper's worst-
# case exit path alone can take close to 7s before it even reaches
# _notify. A short wait here raced that and force-killed the wrapper
# mid-write, before the log line landed -- not a real bug, but a test
# budget shorter than the thing it waits on.
for _ in {1..300}; do
    kill -0 "$TUI_SIG_SCRIPT_PID" >/dev/null 2>&1 || break
    /usr/bin/sleep 0.05
done
kill -KILL "$TUI_SIG_SCRIPT_PID" >/dev/null 2>&1 || true
wait "$TUI_SIG_SCRIPT_PID" >/dev/null 2>&1 || true
exec 9>&-

it "bin/omabackup-tui logs signal=INT on Ctrl-C, closing the originating gap (panel showed status 130 with no way to know why)"
[[ $TUI_SIG_READY_OK -eq 1 ]] && ok || fail "the config TUI never reached its prompt -- test setup is broken, not the fix"
assert_contains "$(cat "$(_log_today_file "$TUI_SIG_HOME")" 2>/dev/null)" "config (interactive)  signal=INT"

# Settings TUI option 7: accepts a number, rejects invalid input, persists
# through to config show.
OPT7_HOME="$(_log_home)"
OPT7_TUI="$(timeout --kill-after=5s 15s bash -c \
    'printf "%b" "$1" | script -qec "$2" /dev/null 2>&1' _ $'7\n14\nq\n' \
    "env HOME='$OPT7_HOME' OMABACKUP_ROOT='$PWD' OMABACKUP_GROUPS='$OPT7_HOME/g.json' \
     OMABACKUP_STATE='$OPT7_HOME/.state' OMABACKUP_REPO='$OPT7_HOME/repo' \
     OMABACKUP_DESTINATIONS='$OPT7_HOME/dest.json' OMABACKUP_SYSTEMCTL='$OPT7_HOME/stub/systemctl' \
     XDG_RUNTIME_DIR=/nonexistent '$OB' config")"

it "the Settings TUI's Log retention option accepts a number and persists it"
assert_contains "$OPT7_TUI" "Keep logs for how many days?"
assert_contains "$OPT7_TUI" "Log retention saved."
assert_eq "$(jq -r '.retentionDays' "$OPT7_HOME/.config/omabackup/log.json" 2>/dev/null)" "14"

OPT7_BAD_TUI="$(timeout --kill-after=5s 15s bash -c \
    'printf "%b" "$1" | script -qec "$2" /dev/null 2>&1' _ $'7\nnotanumber\nq\n' \
    "env HOME='$OPT7_HOME' OMABACKUP_ROOT='$PWD' OMABACKUP_GROUPS='$OPT7_HOME/g.json' \
     OMABACKUP_STATE='$OPT7_HOME/.state' OMABACKUP_REPO='$OPT7_HOME/repo' \
     OMABACKUP_DESTINATIONS='$OPT7_HOME/dest.json' OMABACKUP_SYSTEMCTL='$OPT7_HOME/stub/systemctl' \
     XDG_RUNTIME_DIR=/nonexistent '$OB' config")"

it "the Settings TUI's Log retention option rejects non-numeric input without changing the persisted value"
assert_not_contains "$OPT7_BAD_TUI" "Log retention saved."
assert_eq "$(jq -r '.retentionDays' "$OPT7_HOME/.config/omabackup/log.json" 2>/dev/null)" "14"

# Round omabackup-22 review: a die() reached before the EXIT trap used to
# exist -- `--groups` with no value dies inside the argument-parsing loop,
# which ran before the trap was installed at all.
PARSEDIE_HOME="$(_log_home)"
_log_env "$PARSEDIE_HOME" sync --groups >/dev/null 2>&1

it "a die() during argument parsing, before the trap used to be installed, is still logged"
assert_contains "$(cat "$(_log_today_file "$PARSEDIE_HOME")" 2>/dev/null)" "sync  failed (exit 1)"

# log-event must not depend on the manifest checks every other command
# does -- it is the wrapper's own post-exit notification, called exactly
# when something (a missing manifest included) already went wrong.
LOGEVENT_NOMANIFEST_HOME="$(mktemp -d)"
HOME="$LOGEVENT_NOMANIFEST_HOME" OMABACKUP_ROOT="$PWD" \
    OMABACKUP_GROUPS="$LOGEVENT_NOMANIFEST_HOME/does-not-exist.json" \
    OMABACKUP_STATE="$LOGEVENT_NOMANIFEST_HOME/.state" \
    "$OB" log-event "config (interactive)" "signal=INT" "after 3s" >/dev/null 2>&1
LOGEVENT_NOMANIFEST_RC=$?

it "log-event still writes even when the group manifest is missing entirely"
assert_eq "$LOGEVENT_NOMANIFEST_RC" "0"
assert_contains "$(cat "$(_log_today_file "$LOGEVENT_NOMANIFEST_HOME")" 2>/dev/null)" "config (interactive)  signal=INT"

# A command run by hand, killed by a real signal, must never be logged as
# "ok" -- the worst possible false report a backup tool's log can make.
# Before the dispatch-level INT/TERM/HUP traps, bash's default signal
# handling left $? at whatever it was BEFORE the signal (0, here) by the
# time the EXIT trap ran, so an interrupted `sync` logged a false success.
#
# A minimal fixture's `sync` finishes in well under a second -- too fast to
# reliably race a signal against. A `git` on PATH that pauses before
# delegating to the real binary gives a wide, deterministic window instead
# of a timing guess; by the time `sync` is inside a `git` call, the
# dispatch-level traps are already long installed (they are the second
# thing this script does, before any library work), so the signal cannot
# land in the brief pre-trap startup window either.
SIGNAL_MANUAL_HOME="$(_log_home)"
mkdir -p "$SIGNAL_MANUAL_HOME/slowbin"
{ printf '#!/bin/bash\n'
  printf 'sleep 2\n'
  printf 'exec %q "$@"\n' "$(command -v git)"
} >"$SIGNAL_MANUAL_HOME/slowbin/git"
chmod +x "$SIGNAL_MANUAL_HOME/slowbin/git"
# `env --default-signal=INT,QUIT` right before the CLI, not a plain
# background subshell around it -- found live: bash sets SIGINT to SIG_IGN
# for an asynchronous (`&`) job, inherited at process-start time, and a
# `trap` cannot override a SIG_IGN a bash process inherited when it
# started (POSIX; the same rule bin/omabackup-tui's own CLI-launch line
# already documents and relies on). Without this reset, `kill -INT` here
# was silently swallowed and `sync` ran to completion untouched. No extra
# `( ... )` subshell wrapper either: `env` execs directly into `$OB`
# (same PID in practice), which a subshell layer is not guaranteed to
# preserve identically.
HOME="$SIGNAL_MANUAL_HOME" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$SIGNAL_MANUAL_HOME/g.json" \
    OMABACKUP_STATE="$SIGNAL_MANUAL_HOME/.state" OMABACKUP_REPO="$SIGNAL_MANUAL_HOME/repo" \
    OMABACKUP_DESTINATIONS="$SIGNAL_MANUAL_HOME/dest.json" \
    OMABACKUP_SYSTEMCTL="$SIGNAL_MANUAL_HOME/stub/systemctl" \
    PATH="$SIGNAL_MANUAL_HOME/slowbin:$PATH" XDG_RUNTIME_DIR=/nonexistent \
    env --default-signal=INT,QUIT "$OB" sync &
SIGNAL_MANUAL_PID=$!
sleep 0.3
kill -INT "$SIGNAL_MANUAL_PID" 2>/dev/null
wait "$SIGNAL_MANUAL_PID" 2>/dev/null
SIGNAL_MANUAL_RC=$?

it "a manually-run command killed by SIGINT logs the signal, never a false ok"
assert_eq "$SIGNAL_MANUAL_RC" "130"
assert_not_contains "$(cat "$(_log_today_file "$SIGNAL_MANUAL_HOME")" 2>/dev/null)" "sync  ok"
assert_contains "$(cat "$(_log_today_file "$SIGNAL_MANUAL_HOME")" 2>/dev/null)" "sync  failed (signal INT)"

# Bare `config` (run directly, not through the panel's bin/omabackup-tui
# wrapper) is now in scope too -- previously LOG_POLICY stayed `never` for
# it, so it left no trace at all, unlike every other manually-run command.
# Without a terminal, cmd_config (lib/config.sh:1042) gracefully degrades
# to `config show` and succeeds rather than dying -- this test's point is
# that it is now COVERED (something is written where nothing was before),
# not that it fails; a real Ctrl-C mid-session is what the dispatch-level
# signal traps above are for.
BARECONFIG_HOME="$(_log_home)"
HOME="$BARECONFIG_HOME" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$BARECONFIG_HOME/g.json" \
    OMABACKUP_STATE="$BARECONFIG_HOME/.state" OMABACKUP_REPO="$BARECONFIG_HOME/repo" \
    OMABACKUP_DESTINATIONS="$BARECONFIG_HOME/dest.json" XDG_RUNTIME_DIR=/nonexistent \
    "$OB" config </dev/null >/dev/null 2>&1

it "bare config run without a terminal (no panel wrapper involved) is now logged at all"
assert_contains "$(cat "$(_log_today_file "$BARECONFIG_HOME")" 2>/dev/null)" "config (interactive)  ok"

# log.json's own retentionDays must not exceed LOG_RETENTION_MAX_DAYS even
# when hand-edited directly -- _log_retention_valid_file used to only check
# ">= 1", so an absurd value passed as "valid" and reached the cutoff-date
# arithmetic unbounded.
MAXVAL_HOME="$(_log_home)"
mkdir -p "$MAXVAL_HOME/.config/omabackup"
printf '{"schemaVersion":1,"retentionDays":99999999}\n' >"$MAXVAL_HOME/.config/omabackup/log.json"
MAXVAL_SHOW="$(_log_env "$MAXVAL_HOME" config show --json)"

it "a retentionDays value over LOG_RETENTION_MAX_DAYS is treated as invalid, not accepted"
assert_eq "$(jq -r '.log.configValid' <<<"$MAXVAL_SHOW")" "false"
assert_eq "$(jq -r '.log.retentionDays' <<<"$MAXVAL_SHOW")" "30"

# Timers installed here -- not because this test is about them, but
# because config validate's own pre-existing "timers not installed" path
# (_config_file_schedule reading a timer file that does not exist) leaks a
# raw bash redirection error to stderr, unrelated to the log.json check
# this test actually targets; without this, `_log_env`'s merged
# stdout+stderr capture (used elsewhere in this file so assertions can see
# a command's error text) would corrupt the JSON this test parses.
mkdir -p "$MAXVAL_HOME/.config/systemd/user"
printf '[Timer]\nOnCalendar=*:0/15\nPersistent=true\n' >"$MAXVAL_HOME/.config/systemd/user/omabackup-sync.timer"
printf '[Timer]\nOnCalendar=hourly\nPersistent=true\n' >"$MAXVAL_HOME/.config/systemd/user/omabackup-push.timer"
MAXVAL_VALIDATE="$(_log_env "$MAXVAL_HOME" config validate --json)"

it "config validate reports an invalid log.json, not just config show"
assert_eq "$(jq -r '.valid' <<<"$MAXVAL_VALIDATE")" "false"
assert_contains "$(jq -r '.errors[]' <<<"$MAXVAL_VALIDATE")" "log.json"

# Coalescing under real concurrency: N processes racing the same action's
# first observation must produce exactly one baseline line, not one per
# process -- the read-decide-write-update sequence now runs under a
# per-action lock for exactly this reason.
CONCURRENT_HOME="$(mktemp -d)"
mkdir -p "$(_log_dir "$CONCURRENT_HOME")"
CONCURRENT_PIDS=()
for _ in 1 2 3 4 5 6 7 8; do
    ( HOME="$CONCURRENT_HOME" OMABACKUP_STATE="$CONCURRENT_HOME/.state" bash -c '
        source lib/tui.sh; source lib/log.sh
        _log_run_on_failure verify 0
    ' ) &
    CONCURRENT_PIDS+=("$!")
done
for pid in "${CONCURRENT_PIDS[@]}"; do wait "$pid" 2>/dev/null; done
CONCURRENT_COUNT="$(grep -c '  verify  ' "$(_log_today_file "$CONCURRENT_HOME")" 2>/dev/null || printf 0)"

it "concurrent first observations of the same action produce exactly one baseline line"
assert_eq "$CONCURRENT_COUNT" "1"

# reload retrofits OMABACKUP_LOG_SKIP=1 (and any other .service change)
# into an ALREADY-installed instance -- install is the only thing that
# ever wrote these units, so an instance updated the documented way
# (reload, or `omarchy plugin update`, which calls it) used to keep
# running stale units indefinitely. .timer is deliberately untouched: a
# configured OnCalendar schedule must survive a reload.
RELOAD_HOME="$(mktemp -d)"
mkdir -p "$RELOAD_HOME/plugin" "$RELOAD_HOME/stub" "$RELOAD_HOME/.config/systemd/user"
git init -q "$RELOAD_HOME/plugin"
git -C "$RELOAD_HOME/plugin" config user.email t@t; git -C "$RELOAD_HOME/plugin" config user.name t
printf 'x\n' >"$RELOAD_HOME/plugin/Panel.qml"
git -C "$RELOAD_HOME/plugin" add -A && git -C "$RELOAD_HOME/plugin" commit -qm one
# A pre-existing install: real templates minus the OMABACKUP_LOG_SKIP line,
# as every install before this round produced.
sed '/OMABACKUP_LOG_SKIP/d' systemd/omabackup-sync.service \
    >"$RELOAD_HOME/.config/systemd/user/omabackup-sync.service"
sed '/OMABACKUP_LOG_SKIP/d' systemd/omabackup-push.service \
    >"$RELOAD_HOME/.config/systemd/user/omabackup-push.service"
cp systemd/omabackup-sync.timer "$RELOAD_HOME/.config/systemd/user/omabackup-sync.timer"
sed -i 's/OnCalendar=.*/OnCalendar=*:0\/42/' "$RELOAD_HOME/.config/systemd/user/omabackup-sync.timer"
printf '#!/bin/bash\nprintf restart >>%q\n' "$RELOAD_HOME/calls.log" >"$RELOAD_HOME/stub/restart"
chmod +x "$RELOAD_HOME/stub/restart"
{ printf '#!/bin/bash\n'
  printf 'if [[ -s %q ]]; then printf %%s %q; else printf 1; fi\n' \
      "$RELOAD_HOME/calls.log" "$(( $(date +%s) + 30 ))"
} >"$RELOAD_HOME/stub/probe"
chmod +x "$RELOAD_HOME/stub/probe"
{ printf '#!/bin/bash\n'
  printf 'if [[ -s %q ]]; then printf 2222; else printf 1111; fi\n' "$RELOAD_HOME/calls.log"
} >"$RELOAD_HOME/stub/identity"
chmod +x "$RELOAD_HOME/stub/identity"
printf '#!/bin/bash\nexit 0\n' >"$RELOAD_HOME/stub/systemctl"
chmod +x "$RELOAD_HOME/stub/systemctl"
HOME="$RELOAD_HOME" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$PWD/groups.default.json" \
    OMABACKUP_STATE="$RELOAD_HOME/.state" OMABACKUP_PLUGIN_DIR="$RELOAD_HOME/plugin" \
    OMABACKUP_RESTART_SHELL="$RELOAD_HOME/stub/restart" OMABACKUP_SHELL_PROBE="$RELOAD_HOME/stub/probe" \
    OMABACKUP_SHELL_IDENTITY="$RELOAD_HOME/stub/identity" OMABACKUP_SYSTEMCTL="$RELOAD_HOME/stub/systemctl" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" reload >/dev/null 2>&1

it "reload refreshes an already-installed .service file to pick up OMABACKUP_LOG_SKIP"
assert_contains "$(cat "$RELOAD_HOME/.config/systemd/user/omabackup-sync.service")" "OMABACKUP_LOG_SKIP=1"
assert_contains "$(cat "$RELOAD_HOME/.config/systemd/user/omabackup-push.service")" "OMABACKUP_LOG_SKIP=1"

it "reload never touches the .timer file -- a configured schedule must survive it"
assert_contains "$(cat "$RELOAD_HOME/.config/systemd/user/omabackup-sync.timer")" "OnCalendar=*:0/42"

# Round omabackup-23 review: a generation/write failure during reload's own
# service-file refresh used to leave the target TRUNCATED, since a plain
# `>` redirect opens (and empties) the file before the command producing
# its content even runs -- `|| true` then swallowed the failure and reload
# still reported success. A units directory with no write permission makes
# the temp-file creation itself fail cleanly, without ever touching the
# real, working unit file (only the temp file's own open can fail).
RELOADFAIL_HOME="$(mktemp -d)"
mkdir -p "$RELOADFAIL_HOME/plugin" "$RELOADFAIL_HOME/stub" "$RELOADFAIL_HOME/.config/systemd/user"
git init -q "$RELOADFAIL_HOME/plugin"
git -C "$RELOADFAIL_HOME/plugin" config user.email t@t; git -C "$RELOADFAIL_HOME/plugin" config user.name t
printf 'x\n' >"$RELOADFAIL_HOME/plugin/Panel.qml"
git -C "$RELOADFAIL_HOME/plugin" add -A && git -C "$RELOADFAIL_HOME/plugin" commit -qm one
cp systemd/omabackup-sync.service "$RELOADFAIL_HOME/.config/systemd/user/omabackup-sync.service"
RELOADFAIL_BEFORE="$(cat "$RELOADFAIL_HOME/.config/systemd/user/omabackup-sync.service")"
cp systemd/omabackup-push.service "$RELOADFAIL_HOME/.config/systemd/user/omabackup-push.service"
cp systemd/omabackup-sync.timer "$RELOADFAIL_HOME/.config/systemd/user/omabackup-sync.timer"
printf '#!/bin/bash\nprintf restart >>%q\n' "$RELOADFAIL_HOME/calls.log" >"$RELOADFAIL_HOME/stub/restart"
chmod +x "$RELOADFAIL_HOME/stub/restart"
{ printf '#!/bin/bash\n'
  printf 'if [[ -s %q ]]; then printf %%s %q; else printf 1; fi\n' \
      "$RELOADFAIL_HOME/calls.log" "$(( $(date +%s) + 30 ))"
} >"$RELOADFAIL_HOME/stub/probe"
chmod +x "$RELOADFAIL_HOME/stub/probe"
{ printf '#!/bin/bash\n'
  printf 'if [[ -s %q ]]; then printf 2222; else printf 1111; fi\n' "$RELOADFAIL_HOME/calls.log"
} >"$RELOADFAIL_HOME/stub/identity"
chmod +x "$RELOADFAIL_HOME/stub/identity"
printf '#!/bin/bash\nexit 0\n' >"$RELOADFAIL_HOME/stub/systemctl"
chmod +x "$RELOADFAIL_HOME/stub/systemctl"
chmod 500 "$RELOADFAIL_HOME/.config/systemd/user"
RELOADFAIL_OUT="$(HOME="$RELOADFAIL_HOME" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$PWD/groups.default.json" \
    OMABACKUP_STATE="$RELOADFAIL_HOME/.state" OMABACKUP_PLUGIN_DIR="$RELOADFAIL_HOME/plugin" \
    OMABACKUP_RESTART_SHELL="$RELOADFAIL_HOME/stub/restart" OMABACKUP_SHELL_PROBE="$RELOADFAIL_HOME/stub/probe" \
    OMABACKUP_SHELL_IDENTITY="$RELOADFAIL_HOME/stub/identity" OMABACKUP_SYSTEMCTL="$RELOADFAIL_HOME/stub/systemctl" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" reload 2>&1)"
chmod 700 "$RELOADFAIL_HOME/.config/systemd/user"

it "a reload service-refresh failure leaves the working unit untouched, not truncated"
assert_eq "$(cat "$RELOADFAIL_HOME/.config/systemd/user/omabackup-sync.service")" "$RELOADFAIL_BEFORE"
assert_contains "$RELOADFAIL_OUT" "could not refresh"

# Round omabackup-24 review: _rewrite_execstart calls die() (a real exit)
# for a source template whose ExecStart it does not understand, and reload
# used to call it directly in the main shell -- a single malformed
# template would have killed `reload` outright: no warning, no temp
# cleanup, and none of reload's own real job (verifying the shell
# restart), for either unit, not just the malformed one. OMABACKUP_ROOT
# has to stay a real, sourceable tree (bin/omabackup sources every
# lib/*.sh from it unconditionally), so this points it at a fresh
# directory built from symlinks to the real lib/bin/manifest/groups
# files, with only systemd/omabackup-sync.service replaced by a
# deliberately malformed template.
REWRITEFAIL_HOME="$(mktemp -d)"
mkdir -p "$REWRITEFAIL_HOME/plugin" "$REWRITEFAIL_HOME/stub" "$REWRITEFAIL_HOME/.config/systemd/user" "$REWRITEFAIL_HOME/root/systemd"
ln -s "$PWD/lib" "$REWRITEFAIL_HOME/root/lib"
ln -s "$PWD/bin" "$REWRITEFAIL_HOME/root/bin"
ln -s "$PWD/manifest.json" "$REWRITEFAIL_HOME/root/manifest.json"
ln -s "$PWD/secrets.deny.json" "$REWRITEFAIL_HOME/root/secrets.deny.json"
ln -s "$PWD/groups.default.json" "$REWRITEFAIL_HOME/root/groups.default.json"
printf 'ExecStart=/usr/bin/false\n' >"$REWRITEFAIL_HOME/root/systemd/omabackup-sync.service"
cp systemd/omabackup-push.service "$REWRITEFAIL_HOME/root/systemd/omabackup-push.service"
git init -q "$REWRITEFAIL_HOME/plugin"
git -C "$REWRITEFAIL_HOME/plugin" config user.email t@t; git -C "$REWRITEFAIL_HOME/plugin" config user.name t
printf 'x\n' >"$REWRITEFAIL_HOME/plugin/Panel.qml"
git -C "$REWRITEFAIL_HOME/plugin" add -A && git -C "$REWRITEFAIL_HOME/plugin" commit -qm one
cp systemd/omabackup-sync.service "$REWRITEFAIL_HOME/.config/systemd/user/omabackup-sync.service"
REWRITEFAIL_SYNC_BEFORE="$(cat "$REWRITEFAIL_HOME/.config/systemd/user/omabackup-sync.service")"
cp systemd/omabackup-push.service "$REWRITEFAIL_HOME/.config/systemd/user/omabackup-push.service"
cp systemd/omabackup-sync.timer "$REWRITEFAIL_HOME/.config/systemd/user/omabackup-sync.timer"
printf '#!/bin/bash\nprintf restart >>%q\n' "$REWRITEFAIL_HOME/calls.log" >"$REWRITEFAIL_HOME/stub/restart"
chmod +x "$REWRITEFAIL_HOME/stub/restart"
{ printf '#!/bin/bash\n'
  printf 'if [[ -s %q ]]; then printf %%s %q; else printf 1; fi\n' \
      "$REWRITEFAIL_HOME/calls.log" "$(( $(date +%s) + 30 ))"
} >"$REWRITEFAIL_HOME/stub/probe"
chmod +x "$REWRITEFAIL_HOME/stub/probe"
{ printf '#!/bin/bash\n'
  printf 'if [[ -s %q ]]; then printf 2222; else printf 1111; fi\n' "$REWRITEFAIL_HOME/calls.log"
} >"$REWRITEFAIL_HOME/stub/identity"
chmod +x "$REWRITEFAIL_HOME/stub/identity"
printf '#!/bin/bash\nexit 0\n' >"$REWRITEFAIL_HOME/stub/systemctl"
chmod +x "$REWRITEFAIL_HOME/stub/systemctl"
REWRITEFAIL_OUT="$(HOME="$REWRITEFAIL_HOME" OMABACKUP_ROOT="$REWRITEFAIL_HOME/root" OMABACKUP_GROUPS="$PWD/groups.default.json" \
    OMABACKUP_STATE="$REWRITEFAIL_HOME/.state" OMABACKUP_PLUGIN_DIR="$REWRITEFAIL_HOME/plugin" \
    OMABACKUP_RESTART_SHELL="$REWRITEFAIL_HOME/stub/restart" OMABACKUP_SHELL_PROBE="$REWRITEFAIL_HOME/stub/probe" \
    OMABACKUP_SHELL_IDENTITY="$REWRITEFAIL_HOME/stub/identity" OMABACKUP_SYSTEMCTL="$REWRITEFAIL_HOME/stub/systemctl" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" reload 2>&1)"

it "a malformed source unit's die() during reload is contained to that one unit, not the whole command"
assert_eq "$(cat "$REWRITEFAIL_HOME/.config/systemd/user/omabackup-sync.service")" "$REWRITEFAIL_SYNC_BEFORE"
assert_contains "$(cat "$REWRITEFAIL_HOME/.config/systemd/user/omabackup-push.service")" "OMABACKUP_LOG_SKIP=1"
assert_contains "$REWRITEFAIL_OUT" "could not refresh"
assert_contains "$REWRITEFAIL_OUT" "reloaded"

# Bare `restore` (interactive TUI, no artifact argument) must not share its
# coalescing marker with a specific artifact preview call -- they used to
# both log under the plain action "restore", so the outer session's own
# eventual outcome could silently overwrite an inner preview's failure.
BARERESTORE_HOME="$(_log_home)"
HOME="$BARERESTORE_HOME" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$BARERESTORE_HOME/g.json" \
    OMABACKUP_STATE="$BARERESTORE_HOME/.state" OMABACKUP_REPO="$BARERESTORE_HOME/repo" \
    OMABACKUP_DESTINATIONS="$BARERESTORE_HOME/dest.json" XDG_RUNTIME_DIR=/nonexistent \
    "$OB" restore </dev/null >/dev/null 2>&1

it "bare interactive restore logs under a distinct action name from an artifact preview call"
assert_contains "$(cat "$(_log_today_file "$BARERESTORE_HOME")" 2>/dev/null)" "restore (interactive)"
assert_not_contains "$(cat "$(_log_today_file "$BARERESTORE_HOME")" 2>/dev/null)" $'\trestore\t'

# Round omabackup-24 review found a regression in round 23's own fix: the
# RETURN trap on cmd_restore_tui used to strip INT/TERM/HUP back to bash's
# untrapped default (`trap - RETURN INT TERM HUP`) instead of leaving them
# bound, reopening a narrow window between cmd_restore_tui returning and
# the process actually exiting where a signal would reach the dispatch
# EXIT trap with $?=0 from before the signal -- the exact false-"ok" bug
# round 23 existed to close. The window itself is too narrow to hit with a
# real signal race in a test (omabackup-rev-2 verified this same way
# during the review itself, not by racing a live signal): extract the
# four trap commands directly out of bin/omabackup -- not a frozen copy,
# so this tracks the real source -- and reproduce the exact RETURN/INT/
# TERM/HUP sequence, then check whether INT is still bound afterward.
RESTORETUI_TRAPS="$(sed -n "/^cmd_restore_tui() {/,/^}/p" "$OB" | grep -E "^[[:space:]]*trap '")"
RESTORETUI_TRAPCOUNT="$(printf '%s\n' "$RESTORETUI_TRAPS" | grep -c "^[[:space:]]*trap '")"

it "cmd_restore_tui still installs exactly its four RETURN/INT/TERM/HUP traps"
assert_eq "$RESTORETUI_TRAPCOUNT" "4"

RESTORETUI_AFTER_RETURN="$(bash -c "
    _restore_tui_cleanup_snapshot() { :; }
    _demo() {
        $RESTORETUI_TRAPS
        :
    }
    _demo
    trap -p INT
")"

it "cmd_restore_tui's RETURN trap leaves INT bound after returning, instead of stripping it to bash's untrapped default -- closing a false-ok reopening"
assert_contains "$RESTORETUI_AFTER_RETURN" "_restore_tui_cleanup_snapshot"
assert_contains "$RESTORETUI_AFTER_RETURN" "exit 130"

# OMABACKUP_TUI_SUPERVISED (set by bin/omabackup-tui on the CLI child it
# launches) suppresses the child's own self-logging for a bare interactive
# session -- the wrapper's own post-exit log-event call is already the
# authoritative record. Without this, a panel-launched Settings/Restore
# open wrote two entries for the same open: one from the child's own
# dispatch policy, one from the wrapper.
SUPERVISED_HOME="$(_log_home)"
HOME="$SUPERVISED_HOME" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$SUPERVISED_HOME/g.json" \
    OMABACKUP_STATE="$SUPERVISED_HOME/.state" OMABACKUP_REPO="$SUPERVISED_HOME/repo" \
    OMABACKUP_DESTINATIONS="$SUPERVISED_HOME/dest.json" OMABACKUP_TUI_SUPERVISED=1 \
    XDG_RUNTIME_DIR=/nonexistent "$OB" config </dev/null >/dev/null 2>&1

it "OMABACKUP_TUI_SUPERVISED suppresses the child's own self-log for a bare interactive session"
[[ ! -d "$(_log_dir "$SUPERVISED_HOME")" ]] \
    && ok || fail "the supervised child logged its own outcome despite the wrapper already covering it"

UNSUPERVISED_HOME="$(_log_home)"
HOME="$UNSUPERVISED_HOME" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$UNSUPERVISED_HOME/g.json" \
    OMABACKUP_STATE="$UNSUPERVISED_HOME/.state" OMABACKUP_REPO="$UNSUPERVISED_HOME/repo" \
    OMABACKUP_DESTINATIONS="$UNSUPERVISED_HOME/dest.json" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" config </dev/null >/dev/null 2>&1

it "without OMABACKUP_TUI_SUPERVISED, a bare interactive session still logs its own outcome"
assert_contains "$(cat "$(_log_today_file "$UNSUPERVISED_HOME")" 2>/dev/null)" "config (interactive)  ok"

# The coarse, CMD-only first pass means none of the genuinely inert
# commands ever reach _log_run_on_failure's "first observation" baseline --
# closing round omabackup-23's own regression (a bare invocation with no
# arguments used to write a malformed empty-action log line).
NEVERPOLICY_HOME="$(_log_home)"
_log_env "$NEVERPOLICY_HOME" >/dev/null 2>&1
_log_env "$NEVERPOLICY_HOME" help >/dev/null 2>&1
_log_env "$NEVERPOLICY_HOME" version >/dev/null 2>&1
_log_env "$NEVERPOLICY_HOME" artifacts >/dev/null 2>&1

it "bare invocation, help, version, and artifacts never write to the log at all"
[[ ! -d "$(_log_dir "$NEVERPOLICY_HOME")" ]] \
    && ok || fail "an inert command wrote a log entry -- expected none, including no malformed empty-action line"

# The `always` policy for `sync` must survive a die() during argument
# parsing, not just be assigned after parsing succeeds: the same mistake
# (an invalid --groups) repeated twice must log twice, not coalesce --
# `sync` is not `verify`/`status`, it does not have a persistent "state"
# for a repeat failure to collapse into.
ALWAYSPARSE_HOME="$(_log_home)"
_log_env "$ALWAYSPARSE_HOME" sync --groups >/dev/null 2>&1
_log_env "$ALWAYSPARSE_HOME" sync --groups >/dev/null 2>&1
ALWAYSPARSE_COUNT="$(grep -c '  sync  ' "$(_log_today_file "$ALWAYSPARSE_HOME")" 2>/dev/null || printf 0)"

it "a repeated parse-time die() on an always-policy command logs every time, not coalesced"
assert_eq "$ALWAYSPARSE_COUNT" "2"

# Round omabackup-24 review: OMABACKUP_TUI_SUPERVISED is inherited by the
# whole subtree bin/omabackup-tui launches, including a Settings session
# opened from INSIDE Restore's own recovery menu ("Open backup settings")
# -- a genuinely separate visit the wrapper's own outer "restore
# (interactive)" log entry does not cover. Without `env -u`, that nested
# session would silently have no log record anywhere. Isolates
# _restore_tui_recovery directly (extracted straight out of bin/omabackup,
# not a frozen copy) with a fake $cli that just records whether it saw the
# flag, driven through a scripted "2) Open backup settings" choice.
RECOVERYENV_HOME="$(mktemp -d)"
{
    printf '#!/bin/bash\n'
    printf 'printf "SUPERVISED=%%s\\n" "${OMABACKUP_TUI_SUPERVISED:-unset}" >%q\n' "$RECOVERYENV_HOME/marker"
} >"$RECOVERYENV_HOME/cli"
chmod +x "$RECOVERYENV_HOME/cli"
{
    sed -n "/^_restore_tui_recovery() {/,/^}/p" "$OB"
    printf 'tui_header() { :; }\n'
    printf 'tui_read_line() { printf -v "$1" %%s 2; return 0; }\n'
    printf '_restore_tui_sanitize() { printf %%s "$1"; }\n'
    printf '_restore_tui_recovery %q Title Detail >/dev/null\n' "$RECOVERYENV_HOME/cli"
} >"$RECOVERYENV_HOME/harness.sh"
OMABACKUP_TUI_SUPERVISED=1 bash "$RECOVERYENV_HOME/harness.sh" >/dev/null 2>&1

it "opening Settings from Restore's own recovery menu gets its own log record, not the outer session's inherited suppression"
assert_contains "$(cat "$RECOVERYENV_HOME/marker" 2>/dev/null)" "SUPERVISED=unset"

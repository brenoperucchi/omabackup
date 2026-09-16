# Regression coverage for lock-file acquisition. These specs deliberately
# preplant a symlink at each lock pathname: shell redirection follows it and
# can truncate an unrelated file before `flock` ever sees the descriptor.
# The production contract is that the lock is opened once, relative to a
# validated directory, with no symlink following, and the same descriptor is
# inherited by the protected command.

OB="$(realpath "$PWD/bin/omabackup")"

_lock_home() {
    local h; h="$(mktemp -d)"
    mkdir -p "$h/repo" "$h/stub" "$h/.config/app"
    printf 'x\n' >"$h/.config/app/f.txt"
    cat >"$h/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/app"]}]}
JSON
    printf '{"schemaVersion":1,"destinations":[]}\n' >"$h/dest.json"
    printf '#!/bin/bash\nexit 0\n' >"$h/stub/systemctl"
    chmod +x "$h/stub/systemctl"
    git init -q "$h/repo"
    git -C "$h/repo" config user.email t@t
    git -C "$h/repo" config user.name t
    printf '%s' "$h"
}

_lock_cli_env() {
    local h="$1"; shift
    HOME="$h" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$h/g.json" \
        OMABACKUP_STATE="$h/.state" OMABACKUP_REPO="$h/repo" \
        OMABACKUP_DESTINATIONS="$h/dest.json" OMABACKUP_SYSTEMCTL="$h/stub/systemctl" \
        XDG_RUNTIME_DIR=/nonexistent "$OB" "$@" 2>&1
}

# The log-prune lock is acquired from _log_write on the first write of a day.
PRUNE_HOME="$(_lock_home)"
PRUNE_LOG="$PRUNE_HOME/.state/log"
mkdir -p "$PRUNE_LOG"
printf 'KEEP-PRUNE\n' >"$PRUNE_HOME/prune-victim"
ln -s "$PRUNE_HOME/prune-victim" "$PRUNE_LOG/.prune.lock"
PRUNE_RC=0
HOME="$PRUNE_HOME" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$PRUNE_HOME/.state" \
    OMABACKUP_LOG_DIR="$PRUNE_LOG" LOG_CONFIG_FILE="$PRUNE_HOME/log.json" \
    bash -c 'source lib/tui.sh; source lib/log.sh; _log_write lock-regression ok ""' \
    >/dev/null 2>&1 || PRUNE_RC=$?

it "log pruning refuses a preplanted lock symlink without truncating its target"
assert_eq "$(cat "$PRUNE_HOME/prune-victim")" "KEEP-PRUNE"
(( PRUNE_RC == 0 )) && ok || fail "best-effort logging changed its return status ($PRUNE_RC)"

# The per-action failure-state lock follows the same path before it records a
# transition. It must not open a symlink to a file outside the log directory.
FAIL_HOME="$(_lock_home)"
FAIL_LOG="$FAIL_HOME/.state/log"
mkdir -p "$FAIL_LOG"
printf 'KEEP-FAIL\n' >"$FAIL_HOME/failure-victim"
ln -s "$FAIL_HOME/failure-victim" "$FAIL_LOG/.last-verify.lock"
FAIL_RC=0
HOME="$FAIL_HOME" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$FAIL_HOME/.state" \
    OMABACKUP_LOG_DIR="$FAIL_LOG" LOG_CONFIG_FILE="$FAIL_HOME/log.json" \
    bash -c 'source lib/tui.sh; source lib/log.sh; _log_run_on_failure verify 1' \
    >/dev/null 2>&1 || FAIL_RC=$?

it "failure-state logging refuses a preplanted lock symlink without truncating its target"
assert_eq "$(cat "$FAIL_HOME/failure-victim")" "KEEP-FAIL"
(( FAIL_RC == 0 )) && ok || fail "best-effort failure logging changed its return status ($FAIL_RC)"

# Destination updates currently open DESTINATIONS_FILE.lock with shell
# redirection before taking flock. A symlink there is an external write
# primitive, even though this command is a normal user-level configuration
# operation.
DEST_HOME="$(_lock_home)"
printf 'KEEP-DEST\n' >"$DEST_HOME/dest-victim"
ln -s "$DEST_HOME/dest-victim" "$DEST_HOME/dest.json.lock"
DEST_RC=0
_lock_cli_env "$DEST_HOME" config destination add local "$DEST_HOME/backup" 2 \
    >/dev/null 2>&1 || DEST_RC=$?

it "destination updates refuse a preplanted lock symlink without truncating its target"
assert_eq "$(cat "$DEST_HOME/dest-victim")" "KEEP-DEST"
(( DEST_RC != 0 )) && ok || fail "destination update unexpectedly succeeded through a symlink lock"

# Direct helper coverage pins the two other parts of the contract: the lock
# file itself is not truncated, and the exact fd survives exec. The second
# holder must time out while the first command sleeps with fd 9 inherited.
HELPER_HOME="$(mktemp -d)"
mkdir -p "$HELPER_HOME/locks"
printf 'KEEP-FD\n' >"$HELPER_HOME/locks/test.lock"
HELPER_MARK="$HELPER_HOME/marker"
/usr/bin/python3 "$PWD/lib/lock.py" exec-with-lock "$HELPER_HOME/locks" test.lock 9 -- \
    /usr/bin/bash -c 'flock -x 9 && test -e /proc/$$/fd/9 && printf held >"$1"; sleep 1' _ "$HELPER_MARK" \
    >/dev/null 2>&1 &
HELPER_PID=$!
for _ in {1..50}; do [[ -e "$HELPER_MARK" ]] && break; sleep 0.02; done
SECOND_RC=0
/usr/bin/python3 "$PWD/lib/lock.py" exec-with-lock "$HELPER_HOME/locks" test.lock 9 -- \
    /usr/bin/bash -c 'flock -n 9' >/dev/null 2>&1 || SECOND_RC=$?
wait "$HELPER_PID" 2>/dev/null || true

it "the safe lock helper preserves fd 9 across exec and times out a competing holder"
assert_eq "$(cat "$HELPER_MARK" 2>/dev/null)" "held"
assert_eq "$(cat "$HELPER_HOME/locks/test.lock")" "KEEP-FD"
(( SECOND_RC != 0 )) && ok || fail "a competing lock holder did not time out"

mkfifo "$HELPER_HOME/locks/not-a-file"
FIFO_RC=0
FIFO_OUT="$(/usr/bin/python3 "$PWD/lib/lock.py" exec-with-lock \
    "$HELPER_HOME/locks" not-a-file 9 -- /usr/bin/true 2>&1)" || FIFO_RC=$?

it "the safe lock helper rejects a FIFO without blocking or opening it as a lock"
[[ $FIFO_RC -eq 1 ]] && ok || fail "FIFO was not refused cleanly: rc=$FIFO_RC output=$FIFO_OUT"
assert_contains "$FIFO_OUT" "not a regular file"

# The helper is a new Python process. Its interpreter must not honor inherited
# startup hooks such as PYTHONPATH/sitecustomize before it opens the lock.
PY_HOOK_DIR="$HELPER_HOME/python-hook"
PY_HOOK_PROBE="$HELPER_HOME/python-hook-ran"
mkdir -p "$PY_HOOK_DIR"
cat >"$PY_HOOK_DIR/sitecustomize.py" <<PY
open("$PY_HOOK_PROBE", "w", encoding="ascii").write("hook-ran")
PY
PY_HOOK_RC=0
PYTHONPATH="$PY_HOOK_DIR" OMABACKUP_ROOT="$PWD" bash -c \
    'source lib/lock.sh; _lock_exec "$1" hook-test.lock /usr/bin/true' _ "$HELPER_HOME/locks" \
    >/dev/null 2>&1 || PY_HOOK_RC=$?

it "the lock helper ignores inherited Python startup hooks"
(( PY_HOOK_RC == 0 )) && ok || fail "isolated helper failed: rc=$PY_HOOK_RC"
[[ ! -e "$PY_HOOK_PROBE" ]] && ok || fail "sitecustomize ran inside the lock helper"

# Logging is deliberately best-effort, but a missing Python lock runtime must
# be visible rather than silently disabling the failure coalescer. Keep a
# PATH-shaped fixture with the ordinary shell tools the logger needs and omit
# only python3; the production entry point pins its own PATH, so this direct
# library call is the boundary that exercises the logger's degraded mode.
NO_PY_HOME="$(_lock_home)"
NO_PY_BIN="$NO_PY_HOME/no-python-bin"
mkdir -p "$NO_PY_BIN" "$NO_PY_HOME/.state/log"
for _tool in sed tr date mkdir chmod cat basename; do
    ln -s "$(type -P "$_tool")" "$NO_PY_BIN/$_tool"
done
NO_PY_FAILURE_OUT="$(
    PATH="$NO_PY_BIN" HOME="$NO_PY_HOME" OMABACKUP_ROOT="$PWD" \
        OMABACKUP_STATE="$NO_PY_HOME/.state" OMABACKUP_LOG_DIR="$NO_PY_HOME/.state/log" \
        LOG_CONFIG_FILE="$NO_PY_HOME/log.json" /usr/bin/bash -c \
        'source lib/tui.sh; source lib/log.sh; _log_run_on_failure verify 1; _log_run_on_failure verify 1' \
        2>&1
)"

it "missing Python diagnoses failure logging once without creating false state"
assert_eq "$(grep -c 'persistent failure logging and log retention unavailable' <<<"$NO_PY_FAILURE_OUT" || printf 0)" "1"
[[ ! -e "$NO_PY_HOME/.state/log/.last-verify" && ! -e "$NO_PY_HOME/.state/log/.last-verify.day" ]] \
    && ok || fail "failure logging wrote state despite a missing lock runtime"

NO_PY_APPEND_HOME="$(_lock_home)"
NO_PY_APPEND_BIN="$NO_PY_APPEND_HOME/no-python-bin"
mkdir -p "$NO_PY_APPEND_BIN" "$NO_PY_APPEND_HOME/.state/log"
for _tool in sed tr date mkdir chmod cat basename; do
    ln -s "$(type -P "$_tool")" "$NO_PY_APPEND_BIN/$_tool"
done
NO_PY_APPEND_OUT="$(
    PATH="$NO_PY_APPEND_BIN" HOME="$NO_PY_APPEND_HOME" OMABACKUP_ROOT="$PWD" \
        OMABACKUP_STATE="$NO_PY_APPEND_HOME/.state" OMABACKUP_LOG_DIR="$NO_PY_APPEND_HOME/.state/log" \
        LOG_CONFIG_FILE="$NO_PY_APPEND_HOME/log.json" /usr/bin/bash -c \
        'source lib/tui.sh; source lib/log.sh; _log_write always-regression ok 1s' \
        2>&1
)"
NO_PY_APPEND_LOG="$NO_PY_APPEND_HOME/.state/log/omabackup-$(date +%F).log"

it "missing Python preserves always-policy appends while skipping retention"
assert_eq "$(grep -c 'persistent failure logging and log retention unavailable' <<<"$NO_PY_APPEND_OUT" || printf 0)" "1"
[[ -f "$NO_PY_APPEND_LOG" ]] && ok || fail "always-policy log append disappeared without Python"
assert_contains "$(cat "$NO_PY_APPEND_LOG" 2>/dev/null)" "always-regression  ok"

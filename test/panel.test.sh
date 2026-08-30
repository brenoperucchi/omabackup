# Regressions for Panel.qml, run against real headless QuickShell.
#
# There is no QML test harness in this project, but there does not need to
# be a bespoke one: `QT_QPA_PLATFORM=offscreen qs -p <file>.qml` runs a real
# QuickShell process with no display, which is enough to exercise Process/
# Timer state machines -- exactly the class of bug this file's own probes
# were written against (a timeout message getting overwritten by the very
# process it just killed; a startup Process with no timeout at all). A
# review round found and confirmed both bugs this way, empirically, rather
# than by reading the code and reasoning about QML's signal-delivery order.
#
# A later round corrected this: what cannot be tested headless is
# APPEARANCE (perceived colour, legibility, whether something "reads" as
# secondary), not geometry. A FloatingWindow (not a bare ShellRoot, which
# never runs a layout pass at all) makes positioners really relayout, so
# implicitHeight/x/y are real, measurable numbers -- used below for the
# Config section's collapse and for confirming a MouseArea's click target
# actually has nonzero size, not just that its handler fires in isolation.

it "quickshell is available for QML process/timer probes"
command -v qs >/dev/null 2>&1 && ok || fail "qs (quickshell) not found on PATH -- cannot run these probes"

_qml_probe() {  # _qml_probe <file> -> runs it headless, returns its exit code
    QT_QPA_PLATFORM=offscreen timeout 10 qs -p "$1" >/dev/null 2>&1
}

it "a timed-out Process's timeout message survives its own onExited handler"
_qml_probe test/qml/timeout-message-not-overwritten.qml \
    && ok || fail "the timeout message was overwritten by the killed process's own exit handling"

it "a hung startup resolveProc still ends in cliMissing:true, not silence"
_qml_probe test/qml/resolve-proc-gets-its-own-timeout.qml \
    && ok || fail "a hung resolveProc left cliMissing false -- the widget would stay visible and inert forever"

it "an error message set by a failed operation survives its own trailing refresh()"
_qml_probe test/qml/error-message-survives-followup-refresh.qml \
    && ok || fail "refresh() cleared the error message the operation had just set, one line after setting it"

it "an operation's error also survives the periodic background refresh, not just its own"
_qml_probe test/qml/periodic-refresh-keeps-operation-error.qml \
    && ok || fail "the periodic Timer's own refresh() call cleared an operation error verify can never rediscover"

it "an invisible Grid inside a Column does not occupy layout space, and expanding it does"
_qml_probe test/qml/config-section-collapses-height.qml \
    && ok || fail "the collapsed/expanded Config section did not actually change the column's layout height"

it "expanding Settings scrolls its values into the visible panel area"
_qml_probe test/qml/settings-expands-and-scrolls.qml \
    && ok || fail "Settings expanded below the capped panel viewport without scrolling into view"

it "a group row's custom-styled tooltip does not break the Row's own layout"
_qml_probe test/qml/group-row-tooltip-is-safe-in-row.qml \
    && ok || fail "adding a HoverHandler/ToolTip child broke the Row's geometry"

it "the Config terminal handoff refreshes status when the panel is reopened"
_qml_probe test/qml/config-action-refresh.qml \
    && ok || fail "the Config handoff did not refresh after the panel was reopened"

PANEL_SOURCE="$(<Panel.qml)"
it "the Settings link delegates to the CLI-owned ANSI configuration"
if [[ "$PANEL_SOURCE" == *'text: root.configuring ? "Settings…" : "⚙ Settings…"'* \
      && "$PANEL_SOURCE" == *'function openConfig() { openExternalTui("config") }'* \
      && "$PANEL_SOURCE" == *'function openRestore() { openExternalTui("restore") }'* \
      && "$PANEL_SOURCE" == *'"--app-id=org.omarchy.omabackup-" + root.externalAction'* \
      && "$PANEL_SOURCE" == *'interval: 180'* \
      && "$PANEL_SOURCE" == *'externalProc.running = true'* \
      && "$PANEL_SOURCE" == *'root.refresh(true)'* \
      && "$PANEL_SOURCE" != *'externalProc.timedOut'* \
      && "$PANEL_SOURCE" == *'opacity: root.canOpenExternalTui ? 1.0 : 0.45'* \
      && "$PANEL_SOURCE" == *'id: settingsButton'* \
      && "$PANEL_SOURCE" == *'onClicked: root.openConfig()'* \
      && "$PANEL_SOURCE" == *'id: restoreButton'* \
      && "$PANEL_SOURCE" == *'onClicked: root.openRestore()'* \
      && "$PANEL_SOURCE" == *'root.refresh(false)'* ]]; then
    ok
else
    fail "Settings/Restore do not close with a fade, launch their TUIs, and refresh afterward"
fi

it "the fade closes the panel before the external TUI launch is scheduled"
OPEN_EXTERNAL_BLOCK="$(sed -n '/function openExternalTui/,/^  }/p' Panel.qml)"
OPEN_CLOSE_LINE="$(awk '/function openExternalTui/{inside=1} inside && /root\.close\(\)/{print NR; exit}' Panel.qml)"
OPEN_TIMER_LINE="$(awk '/function openExternalTui/{inside=1} inside && /externalLaunchTimer\.restart\(\)/{print NR; exit}' Panel.qml)"
if [[ "$OPEN_EXTERNAL_BLOCK" == *'root.close()'* \
      && "$OPEN_EXTERNAL_BLOCK" == *'externalLaunchTimer.restart()'* \
      && "$OPEN_CLOSE_LINE" =~ ^[0-9]+$ && "$OPEN_TIMER_LINE" =~ ^[0-9]+$ \
      && $OPEN_CLOSE_LINE -lt $OPEN_TIMER_LINE ]]; then
    ok
else
    fail "the external TUI was not scheduled after the panel close/fade"
fi

it "the panel never owns a restore apply path"
if [[ "$PANEL_SOURCE" != *'--apply'* \
      && "$PANEL_SOURCE" != *'id: restoreFlick'* \
      && "$PANEL_SOURCE" != *'id: artifactsProc'* \
      && "$PANEL_SOURCE" != *'function openTerminalForRestore'* ]]; then
    ok
else
    fail "the panel still contains the removed in-panel restore/apply flow"
fi

it "a live external TUI is not mistaken for a timed-out CLI operation"
EXTERNAL_BLOCK="$(sed -n '/id: externalProc/,/^  }/p' Panel.qml)"
LAUNCH_BLOCK="$(sed -n '/id: externalLaunchTimer/,/^  }/p' Panel.qml)"
if [[ "$PANEL_SOURCE" == *'function finishExternalTui(payload)'* \
      && "$PANEL_SOURCE" == *'root.externalAction !== action'* \
      && "$LAUNCH_BLOCK" == *'externalProc.running = true'* \
      && "$LAUNCH_BLOCK" == *'root.tuiCli, root.cli, root.externalAction'* \
      && "$EXTERNAL_BLOCK" == *'if (code !== 0)'* \
      && "$EXTERNAL_BLOCK" == *'root.refresh(true)'* \
      && "$EXTERNAL_BLOCK" != *'timedOut'* ]]; then
    ok
else
    fail "the external terminal handoff is still coupled to the short CLI timeout"
fi

it "the detached TUI notifies the panel only after its command finishes"
if [[ "$PANEL_SOURCE" == *'omabackup-tui'* \
      && "$PANEL_SOURCE" == *'function tuiFinished(action: string)'* \
      && "$PANEL_SOURCE" == *'function tuiHeartbeat(token: string)'* \
      && "$PANEL_SOURCE" == *'root.externalToken'* \
      && "$PANEL_SOURCE" == *'String(Date.now())'* \
      && "$PANEL_SOURCE" == *'^[0-9]+-[0-9]+$'* \
      && "$PANEL_SOURCE" == *'root.refresh(false)'* ]]; then
    ok
else
    fail "the detached TUI has no completion callback into the panel"
fi

it "tracks the terminal TUI wrapper used by the installed plugin"
if git ls-files --error-unmatch bin/omabackup-tui >/dev/null 2>&1 \
    && [[ -x bin/omabackup-tui ]]; then
    ok
else
    fail "bin/omabackup-tui is not tracked, so the installed plugin cannot launch Restore/Settings"
fi

it "the detached TUI has a finite recovery path when IPC cannot arrive"
TUI_TRAP=0
grep -Fq 'trap '\''_on_exit "$?"'\'' EXIT' bin/omabackup-tui && TUI_TRAP=1
if [[ "$PANEL_SOURCE" == *'readonly property int externalRecoveryMs'* \
      && "$PANEL_SOURCE" == *'id: externalRecoveryTimer'* \
      && "$PANEL_SOURCE" == *'externalRecoveryTimer.restart()'* \
      && "$PANEL_SOURCE" == *'externalRecoveryTimer.stop()'* \
      && "$PANEL_SOURCE" == *'terminal did not report completion; status refreshed'* \
      && $TUI_TRAP -eq 1 ]]; then
    ok
else
    fail "a closed terminal or missing IPC can leave the panel busy forever"
fi

it "the heartbeat is owned by the wrapper process"
if grep -Fq 'local parent_pid="$$"' bin/omabackup-tui \
    && grep -Fq 'while kill -0 "$parent_pid"' bin/omabackup-tui \
    && grep -Fq 'kill -0 "$parent_pid" >/dev/null 2>&1 || return 0' bin/omabackup-tui \
    && ! grep -Fq 'tui_running' bin/omabackup-tui; then
    ok
else
    fail "an orphaned heartbeat can keep refreshing a stale TUI token"
fi

it "the TUI wrapper does not leave its heartbeat child behind"
HEARTBEAT_HOME="$(mktemp -d)"
HEARTBEAT_BIN="$HEARTBEAT_HOME/bin"
HEARTBEAT_PID_FILE="$HEARTBEAT_HOME/sleep.pid"
mkdir -p "$HEARTBEAT_BIN"
cat >"$HEARTBEAT_BIN/sleep" <<'EOF'
#!/bin/bash
printf '%s\n' "$$" >"$HEARTBEAT_PID_FILE"
exec tail -f /dev/null
EOF
cat >"$HEARTBEAT_HOME/cli" <<'EOF'
#!/bin/bash
for _ in {1..50}; do
    [[ -s "$HEARTBEAT_PID_FILE" ]] && exit 0
    /usr/bin/sleep 0.01
done
exit 1
EOF
cat >"$HEARTBEAT_BIN/omarchy-shell" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$HEARTBEAT_BIN/sleep" "$HEARTBEAT_HOME/cli" "$HEARTBEAT_BIN/omarchy-shell"
HEARTBEAT_RC=0
PATH="$HEARTBEAT_BIN:$PATH" HEARTBEAT_PID_FILE="$HEARTBEAT_PID_FILE" \
    bin/omabackup-tui "$HEARTBEAT_HOME/cli" config heartbeat-test \
    >/dev/null 2>&1 || HEARTBEAT_RC=$?
HEARTBEAT_SLEEP_PID="$(cat "$HEARTBEAT_PID_FILE" 2>/dev/null || true)"
HEARTBEAT_LEFT_BEHIND=0
if [[ -n "$HEARTBEAT_SLEEP_PID" ]] && kill -0 "$HEARTBEAT_SLEEP_PID" >/dev/null 2>&1; then
    HEARTBEAT_LEFT_BEHIND=1
    kill "$HEARTBEAT_SLEEP_PID" >/dev/null 2>&1 || true
fi
[[ $HEARTBEAT_RC -eq 0 && -n "$HEARTBEAT_SLEEP_PID" && $HEARTBEAT_LEFT_BEHIND -eq 0 ]] \
    && ok || fail "the wrapper left a heartbeat child alive after normal exit"

it "bounds a blocked completion IPC instead of hanging the TUI wrapper"
IPC_HOME="$(mktemp -d)"; mkdir -p "$IPC_HOME/bin"
IPC_CLI="$IPC_HOME/cli"; IPC_PID_FILE="$IPC_HOME/ipc.pid"
printf '#!/bin/bash\nexit 0\n' >"$IPC_CLI"
cat >"$IPC_HOME/bin/omarchy-shell" <<'EOF'
#!/bin/bash
printf '%s\n' "$$" >"$IPC_PID_FILE"
exec tail -f /dev/null
EOF
chmod +x "$IPC_CLI" "$IPC_HOME/bin/omarchy-shell"
IPC_RC=0
PATH="$IPC_HOME/bin:$PATH" IPC_PID_FILE="$IPC_PID_FILE" \
    timeout 8s bin/omabackup-tui "$IPC_CLI" config blocked-ipc \
    >/dev/null 2>&1 || IPC_RC=$?
IPC_PID="$(cat "$IPC_PID_FILE" 2>/dev/null || true)"
if [[ -n "$IPC_PID" ]] && kill -0 "$IPC_PID" >/dev/null 2>&1; then
    kill -KILL "$IPC_PID" >/dev/null 2>&1 || true
fi
[[ $IPC_RC -eq 0 ]] && ok || fail "a blocked completion IPC hung or killed the wrapper (exit $IPC_RC)"

it "forwards a wrapper signal to the CLI and reaps its children"
SIGNAL_HOME="$(mktemp -d)"; mkdir -p "$SIGNAL_HOME/bin"
SIGNAL_CLI="$SIGNAL_HOME/cli"; SIGNAL_PID_FILE="$SIGNAL_HOME/cli.pid"
SIGNAL_MARKER="$SIGNAL_HOME/received"
SIGNAL_OLD_PGID="$(ps -o pgid= -p "$$" | tr -d '[:space:]')"
SIGNAL_PS_STATE="$SIGNAL_HOME/ps.count"
cat >"$SIGNAL_CLI" <<'EOF'
#!/bin/bash
printf '%s\n' "$$" >"$SIGNAL_PID_FILE"
( trap '' HUP; trap 'exit 0' TERM; while :; do /usr/bin/sleep 1; done ) &
printf '%s\n' "$!" >"$SIGNAL_HOME/child.pid"
trap 'printf TERM >"$SIGNAL_MARKER"; exit 0' TERM
while :; do /usr/bin/sleep 1; done
EOF
cat >"$SIGNAL_HOME/bin/omarchy-shell" <<'EOF'
#!/bin/bash
exit 0
EOF
cat >"$SIGNAL_HOME/bin/ps" <<'EOF'
#!/bin/bash
target=""
while (($#)); do
    if [[ "$1" == -p ]]; then target="${2:-}"; shift 2; continue; fi
    shift
done
if [[ "$target" =~ ^[0-9]+$ && -r "/proc/$target/cmdline" \
      && "$(tr '\0' ' ' <"/proc/$target/cmdline" 2>/dev/null)" == *omabackup-tui* ]]; then
    printf '%s\n' "$FAKE_OLD_PGID"
    exit 0
fi
count="$(cat "$FAKE_PS_STATE" 2>/dev/null || printf '0')"
printf '%s\n' "$((count + 1))" >"$FAKE_PS_STATE"
if [[ "$count" == 0 ]]; then printf '%s\n' "$FAKE_OLD_PGID"; else printf '%s\n' "$target"; fi
EOF
chmod +x "$SIGNAL_CLI" "$SIGNAL_HOME/bin/omarchy-shell" "$SIGNAL_HOME/bin/ps"
PATH="$SIGNAL_HOME/bin:$PATH" SIGNAL_HOME="$SIGNAL_HOME" SIGNAL_PID_FILE="$SIGNAL_PID_FILE" SIGNAL_MARKER="$SIGNAL_MARKER" \
    FAKE_OLD_PGID="$SIGNAL_OLD_PGID" FAKE_PS_STATE="$SIGNAL_PS_STATE" \
    bin/omabackup-tui "$SIGNAL_CLI" config signal-test >/dev/null 2>&1 &
SIGNAL_WRAPPER_PID=$!
SIGNAL_READY=0
for _ in {1..50}; do
    if [[ -s "$SIGNAL_PID_FILE" && -s "$SIGNAL_HOME/child.pid" ]]; then
        SIGNAL_READY=1
        break
    fi
    /usr/bin/sleep 0.01
done
kill -TERM "$SIGNAL_WRAPPER_PID" >/dev/null 2>&1 || true
SIGNAL_WRAPPER_RC=0
wait "$SIGNAL_WRAPPER_PID" >/dev/null 2>&1 || SIGNAL_WRAPPER_RC=$?
SIGNAL_CLI_PID="$(cat "$SIGNAL_PID_FILE" 2>/dev/null || true)"
SIGNAL_CLI_ALIVE=0
if [[ -n "$SIGNAL_CLI_PID" ]] && kill -0 "$SIGNAL_CLI_PID" >/dev/null 2>&1; then
    SIGNAL_CLI_ALIVE=1
    kill -KILL "$SIGNAL_CLI_PID" >/dev/null 2>&1 || true
fi
[[ $SIGNAL_READY -eq 1 && $SIGNAL_WRAPPER_RC -eq 143 && -s "$SIGNAL_MARKER" && $SIGNAL_CLI_ALIVE -eq 0 ]] \
    && ok || fail "wrapper TERM did not cleanly stop/reap the CLI (exit $SIGNAL_WRAPPER_RC)"
SIGNAL_CHILD_PID="$(cat "$SIGNAL_HOME/child.pid" 2>/dev/null || true)"
SIGNAL_CHILD_ALIVE=0
if [[ -n "$SIGNAL_CHILD_PID" ]] && kill -0 "$SIGNAL_CHILD_PID" >/dev/null 2>&1; then
    SIGNAL_CHILD_ALIVE=1
    kill -KILL "$SIGNAL_CHILD_PID" >/dev/null 2>&1 || true
fi

it "a wrapper signal also stops descendants of the CLI"
[[ $SIGNAL_CHILD_ALIVE -eq 0 ]] \
    && ok || fail "wrapper TERM left a descendant of the CLI alive"

# Ctrl-C is special to asynchronous Bash jobs: without an explicit default
# signal reset, the CLI inherits SIGINT=ignored and the wrapper escalates to
# KILL before the CLI can run its own cleanup.
INT_HOME="$(mktemp -d)"; mkdir -p "$INT_HOME/bin"
INT_CLI="$INT_HOME/cli"; INT_READY="$INT_HOME/ready"; INT_MARKER="$INT_HOME/int"
cat >"$INT_CLI" <<'EOF'
#!/bin/bash
printf ready >"$INT_READY"
trap 'printf INT >"$INT_MARKER"; exit 0' INT
while :; do /usr/bin/sleep 1; done
EOF
chmod +x "$INT_CLI"
mkfifo "$INT_HOME/input"
script -qec "env --default-signal=INT,QUIT INT_READY='$INT_READY' INT_MARKER='$INT_MARKER' \
     '$PWD/bin/omabackup-tui' '$INT_CLI' config ctrl-c-test" /dev/null \
    <"$INT_HOME/input" >"$INT_HOME/log" 2>&1 &
INT_SCRIPT_PID=$!
exec 8>"$INT_HOME/input"
INT_PROMPT=0
for _ in {1..100}; do
    if [[ -s "$INT_READY" ]]; then
        INT_PROMPT=1
        break
    fi
    /usr/bin/sleep 0.05
done
INT_WRITE=0
if (( INT_PROMPT )); then printf '\003' >&8 && INT_WRITE=1; fi
exec 8>&-
INT_RC=124
for _ in {1..120}; do
    if ! kill -0 "$INT_SCRIPT_PID" >/dev/null 2>&1; then
        wait "$INT_SCRIPT_PID" >/dev/null 2>&1; INT_RC=$?
        break
    fi
    /usr/bin/sleep 0.05
done
if kill -0 "$INT_SCRIPT_PID" >/dev/null 2>&1; then
    kill -TERM "$INT_SCRIPT_PID" >/dev/null 2>&1 || true
    /usr/bin/sleep 0.1
    kill -KILL "$INT_SCRIPT_PID" >/dev/null 2>&1 || true
    wait "$INT_SCRIPT_PID" >/dev/null 2>&1 || true
fi

it "Ctrl-C reaches the supervised CLI instead of forcing a KILL"
[[ $INT_PROMPT -eq 1 && $INT_WRITE -eq 1 && $INT_RC -eq 130 && -s "$INT_MARKER" ]] \
    && ok || fail "wrapper Ctrl-C did not reach the CLI's signal cleanup"

it "humanizes an every-minute schedule in the panel"
if [[ "$PANEL_SOURCE" == *'c === "* * * * *"'* \
      && "$PANEL_SOURCE" == *'c === "*/1 * * * *"'* \
      && "$PANEL_SOURCE" == *'c === "*:*:00"'* \
      && "$PANEL_SOURCE" == *'c === "*-*-* *:*:00"'* \
      && "$PANEL_SOURCE" == *'return "every minute"'* ]] \
   && _qml_probe test/qml/humanizes-every-minute-schedule.qml; then
    ok
else
    fail "the panel exposed the every-minute schedule as raw cron"
fi

HANDOFF_HOME="$(mktemp -d)"
mkdir -p "$HANDOFF_HOME/bin"
HANDOFF_CLI="$HANDOFF_HOME/fake-cli"
HANDOFF_CALL_LOG="$HANDOFF_HOME/call.log"
HANDOFF_CLI_LOG="$HANDOFF_HOME/cli.log"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >"%s"\nexit 7\n' "$HANDOFF_CLI_LOG" >"$HANDOFF_CLI"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >"%s"\n' "$HANDOFF_CALL_LOG" >"$HANDOFF_HOME/bin/omarchy-shell"
chmod +x "$HANDOFF_CLI" "$HANDOFF_HOME/bin/omarchy-shell"
HANDOFF_RC=0
PATH="$HANDOFF_HOME/bin:$PATH" bin/omabackup-tui "$HANDOFF_CLI" restore 42 >/dev/null 2>&1 || HANDOFF_RC=$?

it "the TUI handoff preserves the CLI result and sends completion IPC"
assert_eq "$HANDOFF_RC" "7"
assert_eq "$(cat "$HANDOFF_CLI_LOG" 2>/dev/null)" "restore"
assert_contains "$(cat "$HANDOFF_CALL_LOG" 2>/dev/null)" "shell call brenoperucchi.omabackup tuiFinished restore:7:42"

SIGNAL_CLI="$HANDOFF_HOME/signal-cli"
SIGNAL_CALL_LOG="$HANDOFF_HOME/signal-call.log"
printf '#!/bin/bash\nkill -HUP "$$"\n' >"$SIGNAL_CLI"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >"%s"\n' "$SIGNAL_CALL_LOG" >"$HANDOFF_HOME/bin/omarchy-shell"
chmod +x "$SIGNAL_CLI" "$HANDOFF_HOME/bin/omarchy-shell"
SIGNAL_RC=0
PATH="$HANDOFF_HOME/bin:$PATH" bin/omabackup-tui "$SIGNAL_CLI" config 42 >/dev/null 2>&1 || SIGNAL_RC=$?

it "the TUI wrapper notifies completion when its child terminates by signal"
assert_eq "$SIGNAL_RC" "129"
assert_contains "$(cat "$SIGNAL_CALL_LOG" 2>/dev/null)" "tuiFinished config:129:42"

# A terminal launcher gives the wrapper a tty. Bash otherwise replaces stdin
# with /dev/null for an asynchronous child, which silently sends the real
# config/restore CLI down its non-interactive path. Keep this as a real PTY
# regression, with a child that checks the descriptor rather than merely
# accepting whatever input it receives.
TTY_HOME="$(mktemp -d)"; TTY_CLI="$TTY_HOME/tty-cli"; TTY_MARKER="$TTY_HOME/marker"
cat >"$TTY_CLI" <<'EOF'
#!/bin/bash
if [[ -t 0 && -t 1 ]]; then
    printf tty >"$TTY_MARKER"
else
    printf no-tty >"$TTY_MARKER"
fi
exit 0
EOF
chmod +x "$TTY_CLI"
TTY_OB_RC=0
script -qec "env TTY_MARKER='$TTY_MARKER' '$PWD/bin/omabackup-tui' '$TTY_CLI' config tty-test" /dev/null \
    >/dev/null 2>&1 || TTY_OB_RC=$?

it "the terminal TUI wrapper preserves the PTY for its real CLI child"
[[ "$TTY_OB_RC" -eq 0 && "$(cat "$TTY_MARKER" 2>/dev/null)" == "tty" ]] \
    && ok || fail "the wrapper launched its CLI without the terminal stdin"

it "status exposes the manifest version used by the QuickShell panel"
STATUS_JSON=""
STATUS_RC=0
STATUS_JSON="$(OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$PWD/groups.default.json" \
    XDG_RUNTIME_DIR=/nonexistent "$PWD/bin/omabackup" status --json)" || STATUS_RC=$?
if (( STATUS_RC == 0 )); then
    assert_eq "$(printf '%s' "$STATUS_JSON" | jq -r '.tool.version')" "$(jq -r '.version' manifest.json)"
else
    fail "status --json exited $STATUS_RC"
fi

it "the panel binds the displayed version to Quickshell clipboard"
if [[ "$PANEL_SOURCE" == *'readonly property string toolVersion:'* \
      && "$PANEL_SOURCE" == *'Quickshell.clipboardText = root.toolVersion'* \
      && "$PANEL_SOURCE" == *'onClicked: root.copyToolVersion()'* ]]; then
    ok
else
    fail "the displayed OmaBackup version is not wired to the Quickshell clipboard"
fi

it "Quickshell copies the version through its Wayland clipboard"
QT_QPA_PLATFORM=offscreen timeout 10 qs -p test/qml/version-copy.qml \
    >/dev/null 2>&1 && ok || fail "the version-copy action did not reach Quickshell's clipboard"

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

it "a timed-out process's own child (git/rsync-shaped) is killed too, not orphaned"
_qml_probe test/qml/timeout-kills-descendant.qml \
    && ok || fail "the direct process was killed but its child survived -- QuickShell's Process has no group-kill of its own (setRunning(false)/signal() both target a single PID), so the fix wraps the command in setsid and spawns a disposable kill-group helper on timeout, using the PID captured BEFORE running=false clears it"

it "output past the panel's cap stops being accumulated, latches outputCapped, and kills the process -- output under it comes through unharmed"
_qml_probe test/qml/output-cap-stops-accumulating.qml \
    && ok || fail "either a small, well-formed output was not preserved byte-for-byte, or an oversized single-line output (StdioCollector's own unbounded buffer, confirmed in datastream.cpp) kept growing instead of latching outputCapped and stopping the process"

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

it "Restore gets the same accent-when-enabled color as Settings, not a permanent muted one"
# Match the closing brace at ANY indentation, not a literal ten spaces: a
# reindent (a footer wrapper, a QML reformat) would otherwise make the
# terminator stop matching, run the extraction to EOF, and pull settingsButton
# in too -- which already has the string this spec checks for, so the
# assertion would pass silently even with restoreButton regressed. That is
# exactly the false positive this scoped extraction exists to avoid.
RESTORE_BUTTON_BLOCK="$(awk '/id: restoreButton/{p=1} p{print} p && /^[[:space:]]*\}/{exit}' Panel.qml)"
if [[ "$RESTORE_BUTTON_BLOCK" == *'foreground: root.canOpenExternalTui ? Color.accent : Color.muted'* ]]; then
    ok
else
    fail "restoreButton's foreground is hardcoded instead of switching to Color.accent when enabled"
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
# Explicit, not just safe by accident: found by review (round omabackup-22)
# that this stub and HBARGV_CLI below were the only two of seven wrapper-
# invoked stubs in this file without their own `log-event` guard -- both
# happen to exit fast today because the file they poll for is already
# non-empty by the time _on_exit's log-event call runs, but that is a
# coincidence of timing, not a declared contract like the other five have.
[[ "$1" == log-event ]] && exit 0
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

# The handoff/signal tests below pin down _notify()'s IPC argv, but _heartbeat()
# had the identical "shell call ..." bug and no regression ever exercised it:
# the fake `sleep` above never returns (`exec tail -f /dev/null`), so the
# wrapper is torn down before its 30s sleep loop ever reaches the
# `_ipc_call ... tuiHeartbeat` line. A fake `sleep` that returns immediately
# lets that line run for real, on the first loop iteration, so this asserts
# the exact argv omarchy-shell actually receives -- not just that the CLI
# behaved and the child got reaped.
HBARGV_HOME="$(mktemp -d)"; mkdir -p "$HBARGV_HOME/bin"
HBARGV_CALL_LOG="$HBARGV_HOME/hb-call.log"
HBARGV_CLI="$HBARGV_HOME/cli"
printf '#!/bin/bash\nexit 0\n' >"$HBARGV_HOME/bin/sleep"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s"\n' "$HBARGV_CALL_LOG" >"$HBARGV_HOME/bin/omarchy-shell"
cat >"$HBARGV_CLI" <<EOF
#!/bin/bash
[[ "\$1" == log-event ]] && exit 0
for _ in {1..50}; do
    [[ -s "$HBARGV_CALL_LOG" ]] && exit 0
    /usr/bin/sleep 0.01
done
exit 1
EOF
chmod +x "$HBARGV_HOME/bin/sleep" "$HBARGV_HOME/bin/omarchy-shell" "$HBARGV_CLI"
HBARGV_RC=0
PATH="$HBARGV_HOME/bin:$PATH" bin/omabackup-tui "$HBARGV_CLI" config hb-argv-token \
    >/dev/null 2>&1 || HBARGV_RC=$?

it "the TUI wrapper's heartbeat sends the direct IPC argv, not the broken shell-call prefix"
assert_eq "$HBARGV_RC" "0"
assert_eq "$(head -n1 "$HBARGV_CALL_LOG" 2>/dev/null)" "brenoperucchi.omabackup tuiHeartbeat hb-argv-token"

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
# The real CLI understands `log-event` (bin/omabackup-tui calls it from
# _on_exit) and returns immediately; this stub must too, or the wrapper's
# own post-exit call launches ANOTHER copy of the infinite loop below.
[[ "$1" == log-event ]] && exit 0
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

# ── `omabackup kill-group` -- Panel.qml's own timeout has the same shape ────
# The wrapper's own TERM-and-reap above covers bin/omabackup-tui's
# supervision. Panel.qml's busyTimeoutTimer is a SEPARATE code path -- it
# talks to QuickShell.Io.Process directly, which has no group-kill of its
# own (confirmed against quickshell-mirror/quickshell's process.cpp:
# setRunning(false) and signal() both call a bare, single-PID kill(2)) --
# so a timed-out verify/status/sync/collect/enable-disable that was itself
# blocked on a git/rsync child used to leave that child orphaned. The fix
# is this subcommand, spawned by the panel against a `setsid`-wrapped
# target's PID instead of reimplementing group-kill in QML (design
# consultation, herdr-ask round omabackup-11). These tests exercise the
# subcommand directly; test/qml/timeout-kills-descendant.qml (run above,
# via _qml_probe) covers the QML wiring that calls it.
KGROUP_HOME="$(mktemp -d)"
KGROUP_PARENT_PID_FILE="$KGROUP_HOME/parent.pid"
KGROUP_CHILD_PID_FILE="$KGROUP_HOME/child.pid"
setsid -- bash -c '
    sleep 300 &
    echo $! >'"$KGROUP_CHILD_PID_FILE"'
    echo $$ >'"$KGROUP_PARENT_PID_FILE"'
    wait
' </dev/null >/dev/null 2>&1 &
disown
for _ in {1..50}; do
    [[ -s "$KGROUP_PARENT_PID_FILE" && -s "$KGROUP_CHILD_PID_FILE" ]] && break
    /usr/bin/sleep 0.05
done
KGROUP_PARENT_PID="$(cat "$KGROUP_PARENT_PID_FILE" 2>/dev/null)"
KGROUP_CHILD_PID="$(cat "$KGROUP_CHILD_PID_FILE" 2>/dev/null)"
HOME="$(mktemp -d)" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$(mktemp -d)" \
    XDG_RUNTIME_DIR=/nonexistent "$PWD/bin/omabackup" kill-group "$KGROUP_PARENT_PID" >/dev/null 2>&1
/usr/bin/sleep 0.5

it "kill-group stops a setsid-isolated target AND the child it spawned"
{ ! kill -0 "$KGROUP_PARENT_PID" 2>/dev/null && ! kill -0 "$KGROUP_CHILD_PID" 2>/dev/null; } \
    && ok || fail "expected both the target and its child gone after kill-group"

# The guard that makes this safe to call blind from a timeout: a target
# that was never setsid'd (a wiring mistake, not a hypothetical) shares
# its OWN process group with whatever spawned it -- kill-group must refuse
# to blast that shared group and fall back to signaling only the one pid
# it was actually given, or a wiring bug anywhere else in the panel could
# take the whole group down through this subcommand.
KGSAFE_HOME="$(mktemp -d)"
bash -c '
    sleep 300 & TARGET_PID=$!
    sleep 300 & SIBLING_PID=$!
    printf "%s\n" "$TARGET_PID" >'"$KGSAFE_HOME"'/target.pid
    printf "%s\n" "$SIBLING_PID" >'"$KGSAFE_HOME"'/sibling.pid
    HOME="$(mktemp -d)" OMABACKUP_ROOT="'"$PWD"'" OMABACKUP_STATE="$(mktemp -d)" \
        XDG_RUNTIME_DIR=/nonexistent "'"$PWD"'/bin/omabackup" kill-group "$TARGET_PID" >/dev/null 2>&1
    /usr/bin/sleep 0.5
    kill -0 "$TARGET_PID" 2>/dev/null && echo "TARGET_ALIVE" || echo "TARGET_GONE"
    kill -0 "$SIBLING_PID" 2>/dev/null && echo "SIBLING_ALIVE" || echo "SIBLING_GONE"
    kill "$SIBLING_PID" 2>/dev/null
' >"$KGSAFE_HOME/out" 2>&1

it "kill-group falls back to single-pid when the target was never its own group leader"
assert_contains "$(cat "$KGSAFE_HOME/out")" "TARGET_GONE"
assert_contains "$(cat "$KGSAFE_HOME/out")" "SIBLING_ALIVE"

KGBAD_OUT="$(HOME="$(mktemp -d)" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$(mktemp -d)" \
    XDG_RUNTIME_DIR=/nonexistent "$PWD/bin/omabackup" kill-group "not-a-pid; rm -rf /" 2>&1)"
KGBAD_RC=$?

it "kill-group rejects a non-numeric pid instead of doing something with it"
assert_eq "$KGBAD_RC" "1"
assert_contains "$KGBAD_OUT" "numeric pid"

# `kill-group 0` reached the fallback branch's `kill -TERM "$pid"` with the
# pid unchecked -- found by review (round omabackup-25): kill(2) treats
# pid 0 as a SEPARATE special case from the -1 broadcast this file already
# guards, distinct from both: it signals every process in the CALLER's
# own process group. Since `omabackup kill-group` shares QuickShell's own
# group whenever invoked normally (the exact premise `setsid --` exists
# to escape), this would have killed the panel's own process group.
# Reproduced live in an isolated setsid session before this fix (the test
# script itself died mid-run, alongside a sentinel in the same group,
# never reaching its own "rc=" line) -- this regression proves the fix
# the same way, not just that an error message appears.
KGZERO_HOME="$(mktemp -d)"
cat >"$KGZERO_HOME/probe.sh" <<PROBEEOF
#!/bin/bash
set -u
sleep 300 & echo \$! >"$KGZERO_HOME/sentinel.pid"
HOME="\$(mktemp -d)" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="\$(mktemp -d)" \\
    XDG_RUNTIME_DIR=/nonexistent "$PWD/bin/omabackup" kill-group 0 >"$KGZERO_HOME/out" 2>&1
echo "kill_group_rc=\$?" >>"$KGZERO_HOME/out"
echo "probe_reached_end" >"$KGZERO_HOME/reached_end"
PROBEEOF
chmod +x "$KGZERO_HOME/probe.sh"
timeout 10 setsid --wait "$KGZERO_HOME/probe.sh" >/dev/null 2>&1
KGZERO_SENTINEL="$(cat "$KGZERO_HOME/sentinel.pid" 2>/dev/null)"

it "kill-group rejects pid 0 instead of signaling its own whole process group"
[[ -f "$KGZERO_HOME/reached_end" ]] \
    && ok || fail "the isolated probe script never reached its own end -- kill-group 0 killed its process group, itself included"
assert_contains "$(cat "$KGZERO_HOME/out" 2>/dev/null)" "numeric pid greater than 1"
[[ -n "$KGZERO_SENTINEL" ]] && kill -0 "$KGZERO_SENTINEL" 2>/dev/null \
    && ok || fail "the sentinel in the same process group did not survive"
kill -KILL "$KGZERO_SENTINEL" >/dev/null 2>&1 || true

# pid 1 is a real, valid pid (init/systemd) -- _kg_stop_group's own
# `pgid != 1` guard correctly refuses it as a GROUP target, but that
# refusal falls through to the single-pid branch, which would run a bare
# `kill -TERM 1` against the real init process. Found by review (round
# omabackup-25): rejected at cmd_kill_group's own input validation now,
# before _kg_stop_group -- and therefore before any `ps`/`kill` at all --
# ever runs, so this is safe to test directly against the real pid 1
# without risk: the die() fires first.
KGONE_OUT="$(HOME="$(mktemp -d)" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$(mktemp -d)" \
    XDG_RUNTIME_DIR=/nonexistent "$PWD/bin/omabackup" kill-group 1 2>&1)"
KGONE_RC=$?

it "kill-group rejects pid 1 (init) before ever calling ps or kill on it"
assert_eq "$KGONE_RC" "1"
assert_contains "$KGONE_OUT" "numeric pid greater than 1"

# _kg_stop_group no longer rediscovers a target's pgid via `ps -p "$pid"`
# -- found by review (round omabackup-26, `omabackup-rev`): it now trusts
# $pid AS the group id directly (every real caller setsid-wraps its
# target first, so this holds by construction), since the old ps-based
# lookup only worked while the specific leader process was still alive --
# see _kg_stop_group's own comment for the full reasoning and the gap
# this closes. That redesign means the guard against pid 0/1 now lives as
# a direct comparison against $pid itself, not against a ps-derived pgid
# -- tested here by calling _kg_stop_group DIRECTLY (bypassing
# cmd_kill_group's own input validation entirely) with 0 and 1, with
# `kill` stubbed to just log calls. Defense in depth, same as
# cmd_kill_group's own validation already covers -- this proves the
# SECOND guard, inside _kg_stop_group itself, also holds on its own.
for KGDIRECT_PID in 0 1; do
    KGDIRECT_LOGFILE="$(mktemp)"
    KGDIRECT_FN="$(sed -n "/^_kg_stop_group() {/,/^}/p" "$PWD/bin/omabackup")"
    bash -c "
        $KGDIRECT_FN
        kill() { printf 'KILL_CALLED:%s\n' \"\$*\" >>'$KGDIRECT_LOGFILE'; return 0; }
        _kg_stop_group $KGDIRECT_PID TERM
    " >/dev/null 2>&1
    KGDIRECT_LOG="$(cat "$KGDIRECT_LOGFILE" 2>/dev/null)"
    rm -f "$KGDIRECT_LOGFILE"

    it "_kg_stop_group itself refuses to treat pid $KGDIRECT_PID as a group id, even called directly"
    assert_not_contains "$KGDIRECT_LOG" "CALLED:-TERM -- -$KGDIRECT_PID"
    assert_contains "$KGDIRECT_LOG" "KILL_CALLED:-TERM $KGDIRECT_PID"
done

# The fix for the gap `omabackup-rev` found in round omabackup-26: a
# setsid-wrapped leader that exits QUICKLY -- before this subcommand's own
# startup (bash, then sourcing lib/*.sh) completes -- used to be
# untraceable, since `ps -p <already-dead-pid>` finds nothing once the
# leader is gone. Reproduced directly: the leader here forks a child and
# exits IMMEDIATELY, well before kill-group is even invoked (there is no
# race to win here on purpose -- the leader is already long dead by the
# time the real subcommand starts), simulating the worst case rather than
# hoping to catch a narrow timing window.
KGDEAD_HOME="$(mktemp -d)"
setsid -- bash -c '
    sleep 300 & echo $! >'"$KGDEAD_HOME"'/child.pid
    echo $$ >'"$KGDEAD_HOME"'/parent.pid
' </dev/null >/dev/null 2>&1
for _ in {1..50}; do
    [[ -s "$KGDEAD_HOME/parent.pid" && -s "$KGDEAD_HOME/child.pid" ]] && break
    /usr/bin/sleep 0.05
done
KGDEAD_PARENT="$(cat "$KGDEAD_HOME/parent.pid" 2>/dev/null)"
KGDEAD_CHILD="$(cat "$KGDEAD_HOME/child.pid" 2>/dev/null)"
for _ in {1..50}; do
    kill -0 "$KGDEAD_PARENT" 2>/dev/null || break
    /usr/bin/sleep 0.05
done

it "the leader really did exit before kill-group is even called (proving this tests the dead-leader case, not the live one)"
kill -0 "$KGDEAD_PARENT" 2>/dev/null && fail "expected the leader to already be gone" || ok

HOME="$(mktemp -d)" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$(mktemp -d)" \
    XDG_RUNTIME_DIR=/nonexistent "$PWD/bin/omabackup" kill-group "$KGDEAD_PARENT" >/dev/null 2>&1
/usr/bin/sleep 0.5

it "kill-group still reaches a descendant even when the leader it was given already exited"
kill -0 "$KGDEAD_CHILD" 2>/dev/null && fail "expected the child to be gone -- the group id survives its original leader's exit" || ok

it "kill-group works even with a missing group manifest, same as log-event"
KGNOMANI_HOME="$(mktemp -d)"
/usr/bin/sleep 60 & KGNOMANI_PID=$!
KGNOMANI_OUT="$(HOME="$KGNOMANI_HOME" OMABACKUP_ROOT="$PWD" \
    OMABACKUP_GROUPS="$KGNOMANI_HOME/does-not-exist.json" OMABACKUP_STATE="$(mktemp -d)" \
    XDG_RUNTIME_DIR=/nonexistent "$PWD/bin/omabackup" kill-group "$KGNOMANI_PID" 2>&1)"
kill -KILL "$KGNOMANI_PID" >/dev/null 2>&1 || true
assert_not_contains "$KGNOMANI_OUT" "group manifest not found"

# Ctrl-C is special to asynchronous Bash jobs: without an explicit default
# signal reset, the CLI inherits SIGINT=ignored and the wrapper escalates to
# KILL before the CLI can run its own cleanup.
INT_HOME="$(mktemp -d)"; mkdir -p "$INT_HOME/bin"
INT_CLI="$INT_HOME/cli"; INT_READY="$INT_HOME/ready"; INT_MARKER="$INT_HOME/int"
cat >"$INT_CLI" <<'EOF'
#!/bin/bash
# See SIGNAL_CLI's own comment above: the wrapper's _on_exit calls this
# same path with `log-event`, which must not fall through into the loop.
[[ "$1" == log-event ]] && exit 0
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
printf '#!/bin/bash\n[[ "$1" == log-event ]] && exit 0\nprintf "%%s\\n" "$*" >"%s"\nexit 7\n' "$HANDOFF_CLI_LOG" >"$HANDOFF_CLI"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >"%s"\n' "$HANDOFF_CALL_LOG" >"$HANDOFF_HOME/bin/omarchy-shell"
chmod +x "$HANDOFF_CLI" "$HANDOFF_HOME/bin/omarchy-shell"
HANDOFF_RC=0
PATH="$HANDOFF_HOME/bin:$PATH" bin/omabackup-tui "$HANDOFF_CLI" restore 42 >/dev/null 2>&1 || HANDOFF_RC=$?

it "the TUI handoff preserves the CLI result and sends completion IPC"
assert_eq "$HANDOFF_RC" "7"
assert_eq "$(cat "$HANDOFF_CLI_LOG" 2>/dev/null)" "restore"
# Exact match, not assert_contains: `omarchy-shell --help` documents the real
# contract as `omarchy-shell <target> <method> [args...]` -- there is no
# working `shell call <id> <method> <arg>` indirection. Confirmed live against
# the running panel on 2026-08-31: `omarchy-shell shell call
# brenoperucchi.omabackup status ""` returns the literal string "unknown"
# while `omarchy-shell brenoperucchi.omabackup status` returns the real
# payload. A `shell call `-prefixed command is therefore never delivered to
# Panel.qml's IpcHandler -- externalBusy never clears and Restore/Settings
# stay disabled until the 900s recovery timer. assert_contains would still
# pass on the broken prefixed string (it is a superstring of the correct
# one), so only an exact match actually reproduces the bug.
assert_eq "$(cat "$HANDOFF_CALL_LOG" 2>/dev/null)" "brenoperucchi.omabackup tuiFinished restore:7:42"

SIGNAL_CLI="$HANDOFF_HOME/signal-cli"
SIGNAL_CALL_LOG="$HANDOFF_HOME/signal-call.log"
printf '#!/bin/bash\n[[ "$1" == log-event ]] && exit 0\nkill -HUP "$$"\n' >"$SIGNAL_CLI"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >"%s"\n' "$SIGNAL_CALL_LOG" >"$HANDOFF_HOME/bin/omarchy-shell"
chmod +x "$SIGNAL_CLI" "$HANDOFF_HOME/bin/omarchy-shell"
SIGNAL_RC=0
PATH="$HANDOFF_HOME/bin:$PATH" bin/omabackup-tui "$SIGNAL_CLI" config 42 >/dev/null 2>&1 || SIGNAL_RC=$?

it "the TUI wrapper notifies completion when its child terminates by signal"
assert_eq "$SIGNAL_RC" "129"
# See the note above the handoff assertion: exact match on purpose.
assert_eq "$(cat "$SIGNAL_CALL_LOG" 2>/dev/null)" "brenoperucchi.omabackup tuiFinished config:129:42"

# A terminal launcher gives the wrapper a tty. Bash otherwise replaces stdin
# with /dev/null for an asynchronous child, which silently sends the real
# config/restore CLI down its non-interactive path. Keep this as a real PTY
# regression, with a child that checks the descriptor rather than merely
# accepting whatever input it receives.
TTY_HOME="$(mktemp -d)"; TTY_CLI="$TTY_HOME/tty-cli"; TTY_MARKER="$TTY_HOME/marker"
cat >"$TTY_CLI" <<'EOF'
#!/bin/bash
# The wrapper's own post-exit `log-event` call redirects this script's
# stdout/stderr to /dev/null, which would otherwise overwrite TTY_MARKER
# with a false "no-tty" and corrupt the real (PTY) invocation's result.
[[ "$1" == log-event ]] && exit 0
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
# Isolated HOME/state and an explicit OMABACKUP_LOG_SKIP -- found by review
# (round omabackup-22): without HOME overridden, `status`'s new
# failure-policy logging wrote a real baseline/coalescing entry into
# THIS MACHINE's actual ~/.local/state/omabackup/log/, not a test fixture,
# on every suite run. This probe is about status's JSON output, not
# logging, so skipping it explicitly is correct on top of the isolation,
# not just belt-and-suspenders.
STATUS_HOME="$(mktemp -d)"
STATUS_JSON="$(HOME="$STATUS_HOME" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$PWD/groups.default.json" \
    OMABACKUP_STATE="$STATUS_HOME/.state" OMABACKUP_LOG_SKIP=1 \
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

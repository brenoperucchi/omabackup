# Regressions for `omabackup reload`.
#
# quickshell reads QML once, at startup, and watches nothing. So updating the
# installed plugin is two steps that must happen in order -- write the files,
# then restart the shell -- and doing them by hand went wrong repeatedly in one
# session: the shell came back up a second BEFORE the pull finished writing, so
# it re-read the old file and the update silently did not land. Twice I told the
# user it was updated when it was not.
#
# The check that catches it is comparing the shell's start time against the
# newest plugin file. That is the whole point of the verb.

OB="$PWD/bin/omabackup"

_rl_home() {
    local h; h="$(mktemp -d)"
    mkdir -p "$h/plugin" "$h/stub" "$h/.config/omabackup"
    printf 'x\n' >"$h/plugin/Panel.qml"
    git init -q "$h/plugin"
    git -C "$h/plugin" config user.email t@t; git -C "$h/plugin" config user.name t
    git -C "$h/plugin" add -A && git -C "$h/plugin" commit -qm one
    printf '#!/bin/bash\nprintf restart >>%q\n' "$h/calls.log" >"$h/stub/restart"
    chmod +x "$h/stub/restart"
    printf '%s' "$h"
}

_rl_run() {  # _rl_run <home> <shell-start-epoch> [args...]
    local h="$1" when="$2"; shift 2
    printf '#!/bin/bash\nprintf %%s %q\n' "$when" >"$h/stub/probe"
    chmod +x "$h/stub/probe"
    HOME="$h" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$PWD/groups.default.json" \
        OMABACKUP_STATE="$h/.state" OMABACKUP_PLUGIN_DIR="$h/plugin" \
        OMABACKUP_RESTART_SHELL="$h/stub/restart" OMABACKUP_SHELL_PROBE="$h/stub/probe" \
        XDG_RUNTIME_DIR=/nonexistent "$OB" reload "$@" 2>&1
}

# ── the healthy path ────────────────────────────────────────────────────────
AH="$(_rl_home)"
AOUT="$(_rl_run "$AH" "$(( $(date +%s) + 30 ))")"   # shell restarts after the files

it "reload restarts the shell"
assert_contains "$(cat "$AH/calls.log" 2>/dev/null)" "restart"

it "and confirms the shell came up after the files were written"
assert_contains "$AOUT" "reloaded"

it "reporting which commit is now live"
assert_contains "$AOUT" "$(git -C "$AH/plugin" rev-parse --short HEAD)"

# ── the race this verb exists for ───────────────────────────────────────────
BH="$(_rl_home)"
BOUT="$(_rl_run "$BH" "$(( $(date +%s) - 600 ))")"  # shell older than the files
BRC=$?

it "a shell older than the plugin files is reported as not reloaded"
assert_contains "$BOUT" "still running"

it "and reload fails rather than claiming success"
[[ $BRC -ne 0 ]] && ok || fail "reload exited 0 with the old shell still up"

# ── it refuses what it cannot do ────────────────────────────────────────────
CH="$(_rl_home)"; rm -rf "$CH/plugin"
COUT="$(_rl_run "$CH" "$(date +%s)")"

it "a missing plugin directory is named, not guessed at"
assert_contains "$COUT" "not installed"

it "and nothing is restarted over it"
[[ ! -s "$CH/calls.log" ]] && ok || fail "restarted the shell for a plugin that is not there"

# ── the destructive neighbour ───────────────────────────────────────────────
it "reload never reaches for omarchy-refresh-shell"
# `omarchy refresh shell` resets shell.json to Omarchy defaults, which would
# wipe the user's bar configuration -- including this very widget. The names
# are one word apart.
assert_not_contains "$(sed -n '/^cmd_reload/,/^}/p' "$OB")" "refresh-shell"

# ── the same second is not a failure ───────────────────────────────────────
# mtimes and process start times have one-second granularity, and the pull
# always happens before the restart -- so landing in the same second means it
# worked. Comparing with a strict `>` called that a failure, and did so on the
# very first real use of this verb.
DH="$(_rl_home)"
DNOW="$(date +%s)"
touch -d "@$DNOW" "$DH/plugin/Panel.qml"
DOUT="$(_rl_run "$DH" "$DNOW")"
DRC=$?

it "a shell starting in the same second as the write counts as reloaded"
assert_contains "$DOUT" "reloaded"

it "and exits clean"
[[ $DRC -eq 0 ]] && ok || fail "same-second reload reported failure"

# ── but a shell that never restarted is still caught ───────────────────────
# Loosening the comparison must not lose the check: if the restart command does
# nothing at all, the verb has to say so.
EH="$(_rl_home)"
printf '#!/bin/bash\nexit 0\n' >"$EH/stub/restart"; chmod +x "$EH/stub/restart"
EOUT="$(_rl_run "$EH" "$(( $(date +%s) - 600 ))")"

it "a shell that predates the files is still caught"
assert_contains "$EOUT" "still running"

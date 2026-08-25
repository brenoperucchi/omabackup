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

_rl_run() {  # _rl_run <home> <shell-start-epoch-AFTER-restart> [args...]
    local h="$1" when="$2"; shift 2
    # A real restart changes the process, so the probe must answer differently
    # before and after: a stub returning one fixed value pretends the same
    # process was there all along, which is exactly the case reload now refuses.
    { printf '#!/bin/bash\n'
      printf 'if [[ -s %q ]]; then printf %%s %q; else printf 1; fi\n' "$h/calls.log" "$when"
    } >"$h/stub/probe"
    chmod +x "$h/stub/probe"
    # "Did it restart" is now asked of the process, not the clock, so the
    # fixture has to answer as a different process once the restart has run.
    { printf '#!/bin/bash\n'
      printf 'if [[ -s %q ]]; then printf 2222; else printf 1111; fi\n' "$h/calls.log"
    } >"$h/stub/identity"
    chmod +x "$h/stub/identity"
    HOME="$h" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$PWD/groups.default.json" \
        OMABACKUP_STATE="$h/.state" OMABACKUP_PLUGIN_DIR="$h/plugin" \
        OMABACKUP_RESTART_SHELL="$h/stub/restart" OMABACKUP_SHELL_PROBE="$h/stub/probe" \
        OMABACKUP_SHELL_IDENTITY="$h/stub/identity" \
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
# The restart stub does nothing here, so the process is the same one before and
# after -- which is the condition reload now names directly.
assert_contains "$EOUT" "did not restart"

# ── the verification verb was giving false successes ───────────────────────
# reload exists because doing this by hand kept landing wrong. It then had two
# ways of reporting success while nothing had happened at all.

FH="$(_rl_home)"; rm -f "$FH/plugin/Panel.qml"; rm -rf "$FH/plugin/.git"
FOUT="$(_rl_run "$FH" 0)"     # no plugin files, and no shell running
FRC=$?

it "an empty plugin directory and no shell is not a successful reload"
# Both sides read 0 and `0 >= 0` was true, so it announced success with nothing
# running anywhere.
[[ $FRC -ne 0 ]] && ok || fail "reported success with no files and no shell"

it "and it says the shell is not running rather than inventing a version"
assert_contains "$FOUT" "not running"

GH="$(_rl_home)"
printf '#!/bin/bash\nexit 1\n' >"$GH/stub/restart"; chmod +x "$GH/stub/restart"
GOUT="$(_rl_run "$GH" "$(( $(date +%s) + 3600 ))")"   # restart fails; shell already newer
GRC=$?

it "a restart command that fails is not a successful reload"
# The old shell being newer than the files made the comparison pass, so a
# restart that returned 1 still reported the new version live.
[[ $GRC -ne 0 ]] && ok || fail "a failed restart reported success"

it "and the failure is named"
assert_contains "$GOUT" "restart"

# ── the shell must actually have restarted ─────────────────────────────────
HH="$(_rl_home)"
HSAME="$(( $(date +%s) + 3600 ))"
printf '#!/bin/bash\nexit 0\n' >"$HH/stub/restart"; chmod +x "$HH/stub/restart"
HOUT="$(_rl_run "$HH" "$HSAME")"

it "a shell that never restarted is caught even when it is newer than the files"
# Same process before and after: the restart did nothing, whatever it returned.
assert_contains "$HOUT" "did not restart"

# ── a genuine restart landing in the same second ───────────────────────────
# The check required a start time DIFFERENT from before. Process start times
# are second-granular, so a shell that really did restart within the same
# second reads as unchanged, and reload refuses a reload that worked. The
# fixtures never covered it because they always answered with two distinct
# values.
SSH2="$(_rl_home)"
SSNOW="$(date +%s)"
touch -d "@$SSNOW" "$SSH2/plugin/Panel.qml"
# The probe answers the SAME second before and after, while the restart command
# genuinely ran -- which is exactly the ambiguous case.
{ printf '#!/bin/bash\n'; printf 'printf %%s %q\n' "$SSNOW"
} >"$SSH2/stub/probe"; chmod +x "$SSH2/stub/probe"
# A different process, reported at the same second -- the ambiguous case.
{ printf '#!/bin/bash\n'
  printf 'if [[ -s %q ]]; then printf 2222; else printf 1111; fi\n' "$SSH2/calls.log"
} >"$SSH2/stub/identity"; chmod +x "$SSH2/stub/identity"
SSOUT="$(HOME="$SSH2" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$PWD/groups.default.json" \
    OMABACKUP_STATE="$SSH2/.state" OMABACKUP_PLUGIN_DIR="$SSH2/plugin" \
    OMABACKUP_RESTART_SHELL="$SSH2/stub/restart" OMABACKUP_SHELL_PROBE="$SSH2/stub/probe" \
    OMABACKUP_SHELL_IDENTITY="$SSH2/stub/identity" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" reload 2>&1)"
SSRC=$?

it "a restart that lands in the same second is not called a failure"
[[ $SSRC -eq 0 ]] && ok || fail "refused a reload that worked: $SSOUT"

# ── a reused pid is not the same shell ──────────────────────────────────────
# Identity was the pid alone. The old shell dies, the kernel hands the new one
# the same number, and reload reported that nothing had restarted -- refusing a
# reload that had in fact worked. The identity now carries the process start
# time, which a reused pid cannot match.
#
# Asked of a process this spec controls. Asserting on whatever quickshell is
# running would make the result depend on the machine, and a stub answering for
# _shell_identity would only prove the stub answers.
PRID="$(bash -c 'eval "$(sed -n "/^_proc_identity()/,/^}/p" bin/omabackup)"; _proc_identity $$')"
PRSTAT="$(cut -d" " -f22 <<<"$(sed "s/.*) //" /proc/self/stat)")"

it "a process identity is its pid paired with its start time"
[[ "$PRID" =~ ^[0-9]+:[0-9]+$ ]] && ok || fail "identity is not <pid>:<starttime>: ${PRID:-<empty>}"

it "and the start time is read from the right field, not from the comm"
[[ "${PRID##*:}" =~ ^[0-9]+$ && "${PRID##*:}" -gt 0 ]] \
    && ok || fail "start time is not a positive tick count: ${PRID:-<empty>}"

it "a pid that does not exist has no identity"
bash -c 'eval "$(sed -n "/^_proc_identity()/,/^}/p" bin/omabackup)"; _proc_identity 999999' \
    >/dev/null 2>&1 && fail "invented an identity for a dead pid" || ok

# The same pid on both sides with a different start time is a different process
# wearing a recycled number -- and must read as a restart, not as "unchanged".
PRH="$(_rl_home)"
PRNOW="$(date +%s)"
touch -d "@$PRNOW" "$PRH/plugin/Panel.qml"
{ printf '#!/bin/bash\n'; printf 'printf %%s %q\n' "$(( PRNOW + 30 ))"
} >"$PRH/stub/probe"; chmod +x "$PRH/stub/probe"
{ printf '#!/bin/bash\n'
  printf 'if [[ -s %q ]]; then printf "4242:99999"; else printf "4242:11111"; fi\n' "$PRH/calls.log"
} >"$PRH/stub/identity"; chmod +x "$PRH/stub/identity"
PROUT="$(HOME="$PRH" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$PWD/groups.default.json" \
    OMABACKUP_STATE="$PRH/.state" OMABACKUP_PLUGIN_DIR="$PRH/plugin" \
    OMABACKUP_RESTART_SHELL="$PRH/stub/restart" OMABACKUP_SHELL_PROBE="$PRH/stub/probe" \
    OMABACKUP_SHELL_IDENTITY="$PRH/stub/identity" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" reload 2>&1)"; PRRC=$?

it "a shell that restarts onto a recycled pid still reads as restarted"
[[ $PRRC -eq 0 ]] && ok || fail "refused a reload that worked: $PROUT"

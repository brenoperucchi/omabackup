# Regressions for `omabackup install` and the scheduler probe.
#
# `omarchy-plugin-add` clones and enables a plugin; it runs no hook from it.
# That is a sound security posture -- code from a URL should not execute at
# install time -- but it means the timers can never install themselves. So a
# fresh install gets the bar widget and the CLI and *no automation at all*: the
# panel would report coverage beautifully and back up nothing, forever.
#
# That is the August incident one level up. Not being scheduled has to be a
# visible state, never a silent one, which is what these specs pin down.

OB="$PWD/bin/omabackup"

# systemctl is stubbed so specs never touch the real user session, and so
# "enabled" is an assertion rather than a hope. It logs every call.
_stub_systemctl() {  # _stub_systemctl <dir> <is-active-answer>
    mkdir -p "$1"
    { printf '#!/bin/bash\n'
      printf 'printf "%%s\\n" "$*" >>%q\n' "$1/calls.log"
      printf '[[ "$*" == *is-active* ]] && { printf "%%s\\n" %q; [[ %q == active ]] && exit 0 || exit 3; }\n' "$2" "$2"
      printf 'exit 0\n'
    } >"$1/systemctl"
    chmod +x "$1/systemctl"
}

_inst_env() {  # _inst_env <home> <stubdir> <args...>
    local h="$1" s="$2"; shift 2
    HOME="$h" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$PWD/groups.default.json" \
        OMABACKUP_STATE="$h/.state" OMABACKUP_SYSTEMCTL="$s/systemctl" \
        XDG_RUNTIME_DIR=/nonexistent "$@" 2>&1
}

# ── install refuses to guess which repo receives the backup ──────────────────
IH="$(mktemp -d)"; IS="$IH/stub"; _stub_systemctl "$IS" inactive
IOUT="$(_inst_env "$IH" "$IS" bash "$OB" install)"

it "install with no OMABACKUP_REPO says so instead of inventing a path"
assert_contains "$IOUT" "OMABACKUP_REPO"

it "and writes nothing at all when it cannot proceed"
[[ ! -d "$IH/.config/systemd/user" ]] && ok || fail "units were written before the repo was known"

# ── a real install ──────────────────────────────────────────────────────────
IH2="$(mktemp -d)"; IS2="$IH2/stub"; _stub_systemctl "$IS2" inactive
IR2="$IH2/repo"; mkdir -p "$IR2"; git init -q "$IR2"
IOUT2="$(HOME="$IH2" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$PWD/groups.default.json" \
    OMABACKUP_STATE="$IH2/.state" OMABACKUP_SYSTEMCTL="$IS2/systemctl" \
    OMABACKUP_REPO="$IR2" XDG_RUNTIME_DIR=/nonexistent bash "$OB" install 2>&1)"

it "install writes both timers and both services"
[[ -f "$IH2/.config/systemd/user/omabackup-sync.timer" \
   && -f "$IH2/.config/systemd/user/omabackup-sync.service" \
   && -f "$IH2/.config/systemd/user/omabackup-push.timer" \
   && -f "$IH2/.config/systemd/user/omabackup-push.service" ]] \
    && ok || fail "missing units: $(ls "$IH2/.config/systemd/user" 2>/dev/null | tr '\n' ' ')"

it "ExecStart points at the tool that ran install, not a hardcoded plugin path"
# Otherwise installing from a working copy silently wires the timer to a plugin
# directory that may not exist, or may hold a different version.
assert_contains "$(grep ExecStart "$IH2/.config/systemd/user/omabackup-sync.service")" "$PWD/bin/omabackup"

it "install records which repo receives the backup"
assert_contains "$(cat "$IH2/.config/omabackup/env" 2>/dev/null)" "OMABACKUP_REPO=$IR2"

it "and actually enables both timers rather than only writing files"
assert_contains "$(cat "$IS2/calls.log" 2>/dev/null)" "enable"

it "reloading the daemon is part of it, or systemd never sees the new units"
assert_contains "$(cat "$IS2/calls.log" 2>/dev/null)" "daemon-reload"

# ── idempotent, and never clobbers a hand edit ──────────────────────────────
printf 'OMABACKUP_REPO=%s\n# my own note\n' "$IR2" >"$IH2/.config/omabackup/env"
HOME="$IH2" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$PWD/groups.default.json" \
    OMABACKUP_STATE="$IH2/.state" OMABACKUP_SYSTEMCTL="$IS2/systemctl" \
    OMABACKUP_REPO="$IR2" XDG_RUNTIME_DIR=/nonexistent bash "$OB" install >/dev/null 2>&1

it "running install twice is safe"
[[ -f "$IH2/.config/systemd/user/omabackup-sync.timer" ]] && ok || fail "second install broke the first"

it "and an env file the user edited is left alone"
assert_contains "$(cat "$IH2/.config/omabackup/env" 2>/dev/null)" "my own note"

# ── not being scheduled is a visible state ──────────────────────────────────
# The whole point. A tool that is installed but that nothing runs is a backup
# that reports coverage and saves nothing.
JH="$(mktemp -d)"; JS="$JH/stub"; _stub_systemctl "$JS" inactive
mkdir -p "$JH/.config/app"; printf 'x\n' >"$JH/.config/app/f.txt"
cat >"$JH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/app"]}]}
JSON
JOUT="$(HOME="$JH" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$JH/g.json" \
    OMABACKUP_STATE="$JH/.state" OMABACKUP_SYSTEMCTL="$JS/systemctl" \
    XDG_RUNTIME_DIR=/nonexistent bash "$OB" verify 2>&1)"
JRC=$?

it "verify says so when nothing is scheduled to run the backup"
assert_contains "$JOUT" "nothing is scheduled"

it "and names the command that fixes it"
assert_contains "$JOUT" "omabackup install"

it "but it is a warning, not a failure -- verify must work on a recovery tty"
[[ $JRC -eq 0 ]] && ok || fail "an unscheduled machine made verify fail (exit $JRC)"

# ── and stays quiet once it is scheduled ────────────────────────────────────
KH="$(mktemp -d)"; KS="$KH/stub"; _stub_systemctl "$KS" active
mkdir -p "$KH/.config/app"; printf 'x\n' >"$KH/.config/app/f.txt"
cp "$JH/g.json" "$KH/g.json"
KOUT="$(HOME="$KH" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$KH/g.json" \
    OMABACKUP_STATE="$KH/.state" OMABACKUP_SYSTEMCTL="$KS/systemctl" \
    XDG_RUNTIME_DIR=/nonexistent bash "$OB" verify 2>&1)"

it "a scheduled machine gets no nagging"
assert_not_contains "$KOUT" "nothing is scheduled"

it "it reports the schedule as covered instead"
assert_contains "$KOUT" "scheduled"

# ── the panel reads this from status --json ─────────────────────────────────
KSTATUS="$(HOME="$KH" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$KH/g.json" \
    OMABACKUP_STATE="$KH/.state" OMABACKUP_SYSTEMCTL="$KS/systemctl" \
    XDG_RUNTIME_DIR=/nonexistent bash "$OB" status --json 2>&1)"

it "status --json carries the scheduler state for the panel to draw"
assert_eq "$(printf '%s' "$KSTATUS" | jq -r '.scheduler.active' 2>/dev/null)" "true"

JSTATUS="$(HOME="$JH" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$JH/g.json" \
    OMABACKUP_STATE="$JH/.state" OMABACKUP_SYSTEMCTL="$JS/systemctl" \
    XDG_RUNTIME_DIR=/nonexistent bash "$OB" status --json 2>&1)"

it "and reports false when nothing runs it"
assert_eq "$(printf '%s' "$JSTATUS" | jq -r '.scheduler.active' 2>/dev/null)" "false"

# ── a path is not a sed script ─────────────────────────────────────────────
# ExecStart was built with `sed "s#...#$OMABACKUP_ROOT#"`, so a `#` in the path
# was a syntax error and a space produced an unquoted, invalid ExecStart.
it "install survives a tool path containing sed's own delimiter"
SH1="$(mktemp -d)"; SS1="$SH1/stub"; _stub_systemctl "$SS1" inactive
SR1="$SH1/repo"; mkdir -p "$SR1"; git init -q "$SR1"
SROOT="$SH1/a#b"; cp -r bin lib systemd groups.default.json secrets.deny.json "$SH1/" 2>/dev/null
mkdir -p "$SROOT"; cp -r "$SH1/bin" "$SH1/lib" "$SH1/systemd" "$SH1/groups.default.json" "$SH1/secrets.deny.json" "$SROOT/" 2>/dev/null
HOME="$SH1" OMABACKUP_ROOT="$SROOT" OMABACKUP_GROUPS="$SROOT/groups.default.json" \
  OMABACKUP_STATE="$SH1/.state" OMABACKUP_SYSTEMCTL="$SS1/systemctl" \
  OMABACKUP_REPO="$SR1" XDG_RUNTIME_DIR=/nonexistent bash "$SROOT/bin/omabackup" install >/dev/null 2>&1
assert_contains "$(grep ExecStart "$SH1/.config/systemd/user/omabackup-sync.service" 2>/dev/null)" "a#b"

it "and a path containing a space produces a quoted ExecStart systemd accepts"
SH2="$(mktemp -d)"; SS2="$SH2/stub"; _stub_systemctl "$SS2" inactive
SR2="$SH2/repo"; mkdir -p "$SR2"; git init -q "$SR2"
SROOT2="$SH2/a b"; mkdir -p "$SROOT2"
cp -r bin lib systemd groups.default.json secrets.deny.json "$SROOT2/" 2>/dev/null
HOME="$SH2" OMABACKUP_ROOT="$SROOT2" OMABACKUP_GROUPS="$SROOT2/groups.default.json" \
  OMABACKUP_STATE="$SH2/.state" OMABACKUP_SYSTEMCTL="$SS2/systemctl" \
  OMABACKUP_REPO="$SR2" XDG_RUNTIME_DIR=/nonexistent bash "$SROOT2/bin/omabackup" install >/dev/null 2>&1
EXECLINE="$(grep ExecStart "$SH2/.config/systemd/user/omabackup-sync.service" 2>/dev/null)"
[[ "$EXECLINE" == *"'"*"a b"*"'"* ]] && ok || fail "unquoted path with a space: $EXECLINE"

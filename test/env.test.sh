# The CLI reads its own machine config.
#
# OMABACKUP_REPO lived in ~/.config/omabackup/env and only systemd ever loaded
# it, through EnvironmentFile= in the units. Every other caller -- a human in a
# terminal, and the QML panel running `status --json` -- got nothing: no repo,
# so no github destination and an empty repo field, on a machine where the
# backup had been running hourly all day. One fact, loaded in one place, read by
# everyone else as absent.

OB="$PWD/bin/omabackup"

EH="$(mktemp -d)"
mkdir -p "$EH/.config/omabackup" "$EH/.config/app" "$EH/repo" "$EH/stub"
printf 'x\n' >"$EH/.config/app/f.txt"
cat >"$EH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/app"]}]}
JSON
printf '#!/bin/bash\nexit 0\n' >"$EH/stub/systemctl"; chmod +x "$EH/stub/systemctl"
git init -q "$EH/repo"
git -C "$EH/repo" config user.email t@t; git -C "$EH/repo" config user.name t
printf 'seed\n' >"$EH/repo/README.md"
git -C "$EH/repo" add -A && git -C "$EH/repo" commit -qm base
git -C "$EH/repo" remote add origin "$EH/remote.git"
printf 'OMABACKUP_REPO=%s\n' "$EH/repo" >"$EH/.config/omabackup/env"

_env_run() {  # deliberately WITHOUT OMABACKUP_REPO in the environment
    HOME="$EH" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$EH/g.json" \
        OMABACKUP_STATE="$EH/.state" OMABACKUP_SYSTEMCTL="$EH/stub/systemctl" \
        XDG_RUNTIME_DIR=/nonexistent "$OB" "$@" 2>&1
}

it "the repo configured in env is found without it being in the environment"
assert_contains "$(_env_run status --json | jq -r '.config.repo')" "$EH/repo"

it "so the github destination appears, as it does for the timer"
assert_contains "$(_env_run status --json | jq -r '.destinations[].id')" "github"

# ── the environment still wins ─────────────────────────────────────────────
# A file that overrode an explicit variable would make every spec in this suite
# a lie, since they all point the tool at a temp directory that way.
OTHER="$(mktemp -d)/other"; mkdir -p "$OTHER"; git init -q "$OTHER"

it "an explicit OMABACKUP_REPO overrides the file"
assert_contains "$(HOME="$EH" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$EH/g.json" \
    OMABACKUP_STATE="$EH/.state" OMABACKUP_REPO="$OTHER" \
    OMABACKUP_SYSTEMCTL="$EH/stub/systemctl" XDG_RUNTIME_DIR=/nonexistent \
    "$OB" status --json 2>&1 | jq -r '.config.repo')" "$OTHER"

# ── a missing or hostile env file is not fatal ─────────────────────────────
FH="$(mktemp -d)"; mkdir -p "$FH/.config/omabackup" "$FH/stub"
cp "$EH/g.json" "$FH/g.json"
printf '#!/bin/bash\nexit 0\n' >"$FH/stub/systemctl"; chmod +x "$FH/stub/systemctl"

it "no env file at all still produces a valid document"
assert_eq "$(HOME="$FH" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$FH/g.json" \
    OMABACKUP_STATE="$FH/.state" OMABACKUP_SYSTEMCTL="$FH/stub/systemctl" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" status --json 2>&1 | jq -r '.schemaVersion')" "1"

it "and the file is read as data, never executed"
# systemd's EnvironmentFile is KEY=VALUE, not a script. Sourcing it would hand
# anything that can write there a shell running as the user, on a timer.
printf 'OMABACKUP_REPO=%s\ntouch %s/PWNED\n' "$FH/repo" "$FH" >"$FH/.config/omabackup/env"
HOME="$FH" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$FH/g.json" \
    OMABACKUP_STATE="$FH/.state" OMABACKUP_SYSTEMCTL="$FH/stub/systemctl" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" status --json >/dev/null 2>&1
[[ ! -e "$FH/PWNED" ]] && ok || fail "the env file was executed as a script"

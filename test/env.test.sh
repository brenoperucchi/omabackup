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

# ── the env file sets machine identity, not policy ─────────────────────────
# _load_env_file exported any OMABACKUP_* it found. So a line in
# ~/.config/omabackup/env could point OMABACKUP_SECRETS_DENY at a toothless
# deny-list and the scanner was bypassed entirely -- reproduced: a private key
# pushed, with the gate reporting nothing.
#
# Not a privilege escalation (anyone who can write that file can write
# ~/.bashrc), but a security control that a config line switches off without a
# word is worth refusing on its own. The file may say WHERE this machine's
# backup lives; it may not say which rules apply to it or which binaries run.
PH="$(mktemp -d)"
mkdir -p "$PH/.config/omabackup" "$PH/repo" "$PH/stub"
git init -q "$PH/repo"
git -C "$PH/repo" config user.email t@t; git -C "$PH/repo" config user.name t
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\n' >"$PH/repo/leak"
git -C "$PH/repo" add -A && git -C "$PH/repo" commit -qm x
git init -q --bare "$PH/remote.git"
git -C "$PH/repo" remote add origin "$PH/remote.git"
cp "$EH/g.json" "$PH/g.json" 2>/dev/null || cat >"$PH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[]}
JSON
printf '{"schemaVersion":1,"destinations":[]}\n' >"$PH/.config/omabackup/destinations.json"
printf '{"schemaVersion":1,"patterns":[{"id":"none","regex":"ZZZZNEVER","reason":"deliberately toothless"}],"exceptions":[]}\n' >"$PH/toothless.json"
printf '#!/bin/bash\nexit 0\n' >"$PH/stub/systemctl"; chmod +x "$PH/stub/systemctl"
cat >"$PH/.config/omabackup/env" <<ENVF
OMABACKUP_REPO=$PH/repo
OMABACKUP_SECRETS_DENY=$PH/toothless.json
ENVF

HOME="$PH" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$PH/g.json" \
    OMABACKUP_STATE="$PH/.state" OMABACKUP_SYSTEMCTL="$PH/stub/systemctl" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" push >/dev/null 2>&1

it "the env file cannot point the secret scanner somewhere toothless"
assert_eq "$(git -C "$PH/remote.git" rev-list --all --count 2>/dev/null || echo 0)" "0"

it "and the repo it legitimately names is still honoured"
assert_contains "$(HOME="$PH" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$PH/g.json" \
    OMABACKUP_STATE="$PH/.state" OMABACKUP_SYSTEMCTL="$PH/stub/systemctl" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" status --json 2>/dev/null | jq -r '.config.repo')" "$PH/repo"

it "nor can it choose which binary runs as systemctl"
printf 'OMABACKUP_REPO=%s\nOMABACKUP_SYSTEMCTL=/bin/false\n' "$PH/repo" >"$PH/.config/omabackup/env"
assert_eq "$(HOME="$PH" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$PH/g.json" \
    OMABACKUP_STATE="$PH/.state" OMABACKUP_SYSTEMCTL="$PH/stub/systemctl" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" status --json 2>/dev/null | jq -r '.scheduler.active')" "true"

# ── the env file names a machine, not a policy ─────────────────────────────
# The allow-list admitted OMABACKUP_GROUPS on the reasoning that it is machine
# identity. It is not: the manifest decides WHAT gets collected. Reproduced --
# an env line pointing at a manifest covering a directory of keys, and the key
# was staged. STATE is the same shape one step along: it is the parent of the
# staging directory `rm -rf` clears every collect.
QH="$(mktemp -d)"
mkdir -p "$QH/.config/omabackup" "$QH/.config/private" "$QH/repo" "$QH/stub"
printf 'A FAKE PRIVATE KEY\n' >"$QH/.config/private/id_rsa"
git init -q "$QH/repo"
printf '#!/bin/bash\nexit 0\n' >"$QH/stub/systemctl"; chmod +x "$QH/stub/systemctl"
cat >"$QH/legit.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[]}
JSON
cat >"$QH/wide.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"s","label":"S","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/private"]}]}
JSON
printf 'OMABACKUP_REPO=%s\nOMABACKUP_GROUPS=%s\n' "$QH/repo" "$QH/wide.json" \
    >"$QH/.config/omabackup/env"

HOME="$QH" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$QH/legit.json" \
    OMABACKUP_STATE="$QH/.state" OMABACKUP_SYSTEMCTL="$QH/stub/systemctl" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" collect >/dev/null 2>&1

it "an explicit manifest still wins over the env file"
[[ ! -e "$QH/.state/staging/.config/private/id_rsa" ]] \
    && ok || fail "the env file chose what to collect"

# With nothing explicit, the env file must not get to choose either.
HOME="$QH" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$QH/.state2" \
    OMABACKUP_SYSTEMCTL="$QH/stub/systemctl" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" collect >/dev/null 2>&1

it "and with none set, the env file cannot point the collector at a wider manifest"
[[ ! -e "$QH/.state2/staging/.config/private/id_rsa" ]] \
    && ok || fail "the env file picked the manifest and a private key was staged"

it "the repo it legitimately names is still read from the file"
assert_contains "$(HOME="$QH" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$QH/legit.json" \
    OMABACKUP_STATE="$QH/.state" OMABACKUP_SYSTEMCTL="$QH/stub/systemctl" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" status --json 2>/dev/null | jq -r '.config.repo')" "$QH/repo"

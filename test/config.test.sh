# The panel's Config section: where this machine is pointed.
#
# Everything here is machine identity rather than project data -- the repo that
# receives the backup, the destinations file, the deny-list, the timer schedule.
# None of it lives in the public manifest, which is exactly why the interface
# has to show it: otherwise the only way to know what a machine is configured to
# do is to read four files in three directories.

OB="$PWD/bin/omabackup"

_cfg_env() {
    local h="$1"; shift
    HOME="$h" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$h/g.json" \
        OMABACKUP_STATE="$h/.state" OMABACKUP_REPO="$h/repo" \
        OMABACKUP_DESTINATIONS="$h/dest.json" OMABACKUP_SYSTEMCTL="$h/stub/systemctl" \
        XDG_RUNTIME_DIR=/nonexistent "$OB" "$@" 2>&1
}

_cfg_home() {
    local h; h="$(mktemp -d)"
    mkdir -p "$h/.config/app" "$h/stub" "$h/repo"
    printf 'x\n' >"$h/.config/app/f.txt"
    cat >"$h/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/app"]}]}
JSON
    printf '{"schemaVersion":1,"destinations":[]}\n' >"$h/dest.json"
    # A stub that answers the schedule query the way systemd does.
    { printf '#!/bin/bash\n'
      printf 'if [[ "$*" == *TimersCalendar* && "$*" == *sync* ]]; then echo "{ OnCalendar=*-*-* *:00/15:00 ; next_elapse=... }"; exit 0; fi\n'
      printf 'if [[ "$*" == *TimersCalendar* && "$*" == *push* ]]; then echo "{ OnCalendar=*-*-* *:00:00 ; next_elapse=... }"; exit 0; fi\n'
      printf 'exit 0\n'
    } >"$h/stub/systemctl"
    chmod +x "$h/stub/systemctl"
    git init -q "$h/repo"
    printf '%s' "$h"
}

CH="$(_cfg_home)"
CJ="$(_cfg_env "$CH" status --json)"

it "status --json reports which repo receives the backup"
assert_contains "$(printf '%s' "$CJ" | jq -r '.config.repo')" "$CH/repo"

it "and where the destinations are configured"
assert_contains "$(printf '%s' "$CJ" | jq -r '.config.destinationsFile')" "dest.json"

it "and which deny-list guards the push"
assert_contains "$(printf '%s' "$CJ" | jq -r '.config.denyList')" "secrets.deny.json"

it "and where its own state lives"
assert_contains "$(printf '%s' "$CJ" | jq -r '.config.state')" "$CH/.state"

it "the schedule is read from the timers, not hardcoded in the panel"
# The interval is systemd's to know. Repeating it in QML would be the same fact
# in two places, which is how four things in this project have already drifted.
assert_contains "$(printf '%s' "$CJ" | jq -r '.scheduler.sync')" "15"

it "and the push schedule with it"
[[ -n "$(printf '%s' "$CJ" | jq -r '.scheduler.push // empty')" ]] \
    && ok || fail "no push schedule reported"

# ── it degrades where there is no session to ask ─────────────────────────────
DH="$(_cfg_home)"
printf '#!/bin/bash\nexit 1\n' >"$DH/stub/systemctl"; chmod +x "$DH/stub/systemctl"
DJ="$(_cfg_env "$DH" status --json)"

it "a machine with no timers still produces a valid document"
assert_eq "$(printf '%s' "$DJ" | jq -r '.schemaVersion')" "1"

it "and reports the schedule as unknown rather than inventing one"
assert_eq "$(printf '%s' "$DJ" | jq -r '.scheduler.sync')" "null"

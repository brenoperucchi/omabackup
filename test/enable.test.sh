# `omabackup enable` / `disable` -- the master switch behind the panel's toggle.
#
# The panel already carries toggles that only report, because setting anything
# needed a verb that did not exist. This is that verb: it stops and starts the
# timers, which is what "is omabackup on" actually means -- with them stopped
# nothing collects, nothing commits and nothing is sent, and `verify` already
# says so ("nothing is scheduled to run the backup").

OB="$PWD/bin/omabackup"

_en_home() {
    local h; h="$(mktemp -d)"
    # A machine that has run `install`: the units exist, which is what
    # enable/disable act on. Without them the verbs correctly refuse.
    mkdir -p "$h/stub" "$h/.config/app" "$h/.config/systemd/user"
    touch "$h/.config/systemd/user/omabackup-sync.timer" \
          "$h/.config/systemd/user/omabackup-push.timer"
    printf 'x\n' >"$h/.config/app/f.txt"
    cat >"$h/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/app"]}]}
JSON
    # A stub that records every call and answers is-active from a state file.
    { printf '#!/bin/bash\n'
      printf 'printf "%%s\\n" "$*" >>%q\n' "$h/calls.log"
      printf 'if [[ "$*" == *is-active* ]]; then [[ -f %q ]] && exit 0 || exit 3; fi\n' "$h/on"
      printf 'if [[ "$*" == *"enable --now"* ]]; then touch %q; fi\n' "$h/on"
      printf 'if [[ "$*" == *"disable --now"* ]]; then rm -f %q; fi\n' "$h/on"
      printf 'exit 0\n'
    } >"$h/stub/systemctl"
    chmod +x "$h/stub/systemctl"
    touch "$h/on"
    printf '%s' "$h"
}

_en_run() {
    local h="$1"; shift
    HOME="$h" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$h/g.json" \
        OMABACKUP_STATE="$h/.state" OMABACKUP_SYSTEMCTL="$h/stub/systemctl" \
        XDG_RUNTIME_DIR=/nonexistent "$OB" "$@" 2>&1
}

AH="$(_en_home)"

it "with no units installed at all, the verbs refuse instead of guessing"
NH="$(mktemp -d)"; mkdir -p "$NH/stub"
cp "$AH/g.json" "$NH/g.json"; cp "$AH/stub/systemctl" "$NH/stub/systemctl"
assert_contains "$(HOME="$NH" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$NH/g.json" \
    OMABACKUP_STATE="$NH/.state" OMABACKUP_SYSTEMCTL="$NH/stub/systemctl" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" disable 2>&1)" "omabackup install"

it "a machine with its timers running reports enabled"
assert_eq "$(_en_run "$AH" status --json | jq -r '.scheduler.active')" "true"

_en_run "$AH" disable >/dev/null

it "disable stops the timers"
assert_contains "$(cat "$AH/calls.log")" "disable --now"

it "and the machine then reports itself off"
assert_eq "$(_en_run "$AH" status --json | jq -r '.scheduler.active')" "false"

it "verify says so rather than staying quiet about it"
assert_contains "$(_en_run "$AH" verify 2>&1)" "nothing is scheduled"

_en_run "$AH" enable >/dev/null

it "enable starts them again"
assert_eq "$(_en_run "$AH" status --json | jq -r '.scheduler.active')" "true"

it "disable is idempotent -- turning off what is already off is not an error"
_en_run "$AH" disable >/dev/null
_en_run "$AH" disable >/dev/null
[[ $? -eq 0 ]] && ok || fail "a second disable failed"

it "and neither verb accepts a flag it does not understand"
assert_contains "$(_en_run "$AH" enable --force 2>&1)" "unknown flag"

# ── it never removes the units, only stops them ────────────────────────────
# `disable` has to be reversible from the panel. Deleting units would make
# turning it back on a reinstall, which no toggle should ever mean.
it "disable stops the timers without removing anything"
assert_not_contains "$(sed -n '/^cmd_enable/,/^}/p' "$OB")" "rm "

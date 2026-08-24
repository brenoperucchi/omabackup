# Regressions for staleness -- docs/DESIGN.md §4: "the badge does not clear
# itself: a stale backup stays visible until it is dealt with."
#
# The panel could already say "nothing is scheduled". It could not say "the
# timer exists and the last successful run was three days ago", which is the
# worse of the two: a timer that fails silently leaves everything green. The
# mockup calls this state `Atrasado`, and it was the one gap in it that fixes a
# way the interface lies by omission.

OB="$PWD/bin/omabackup"

_stale_env() {  # _stale_env <home> <repo> <args...>
    local h="$1" r="$2"; shift 2
    HOME="$h" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$h/g.json" \
        OMABACKUP_STATE="$h/.state" OMABACKUP_REPO="$r" \
        OMABACKUP_DESTINATIONS="$h/dest.json" OMABACKUP_SYSTEMCTL="$h/stub/systemctl" \
        XDG_RUNTIME_DIR=/nonexistent "$OB" "$@" 2>&1
}

_stale_home() {  # prints a home with a manifest, a repo and an active-timer stub
    local h; h="$(mktemp -d)"
    mkdir -p "$h/.config/app" "$h/stub" "$h/repo"
    printf 'x\n' >"$h/.config/app/f.txt"
    cat >"$h/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/app"]}]}
JSON
    printf '{"schemaVersion":1,"destinations":[]}\n' >"$h/dest.json"
    printf '#!/bin/bash\nexit 0\n' >"$h/stub/systemctl"; chmod +x "$h/stub/systemctl"
    git init -q "$h/repo"
    git -C "$h/repo" config user.email t@t; git -C "$h/repo" config user.name t
    printf 'seed\n' >"$h/repo/README.md"
    git -C "$h/repo" add -A && git -C "$h/repo" commit -qm base
    printf '%s' "$h"
}

# ── a successful sync is recorded, whether or not it committed ─────────────
# A run that found nothing to do still proves the backup is working. Recording
# only commits would call a healthy idle machine stale.
AH="$(_stale_home)"
_stale_env "$AH" "$AH/repo" sync --commit >/dev/null

it "a sync that committed records when it succeeded"
[[ -s "$AH/.state/last-sync" ]] && ok || fail "nothing recorded"

FIRST="$(cat "$AH/.state/last-sync" 2>/dev/null)"
_stale_env "$AH" "$AH/repo" sync --commit >/dev/null

it "and so does a sync that found nothing to do"
SECOND="$(cat "$AH/.state/last-sync" 2>/dev/null)"
[[ -n "$SECOND" && "$SECOND" -ge "$FIRST" ]] \
    && ok || fail "an idle-but-healthy run did not count as success"

it "a fresh machine is not stale"
assert_eq "$(_stale_env "$AH" "$AH/repo" status --json | jq -r '.stale')" "false"

it "and verify says nothing about it"
assert_not_contains "$(_stale_env "$AH" "$AH/repo" verify 2>&1)" "stale"

# ── a day without a successful run is visible ──────────────────────────────
BH="$(_stale_home)"
_stale_env "$BH" "$BH/repo" sync --commit >/dev/null
printf '%s' "$(( $(date +%s) - 90000 ))" >"$BH/.state/last-sync"   # 25h ago

it "a backup that has not run for a day reports stale"
assert_eq "$(_stale_env "$BH" "$BH/repo" status --json | jq -r '.stale')" "true"

it "status carries how long it has been, so the panel can say it"
[[ "$(_stale_env "$BH" "$BH/repo" status --json | jq -r '.lastSyncAgeSec')" -gt 86400 ]] \
    && ok || fail "no age reported"

it "verify warns about it rather than staying quiet"
assert_contains "$(_stale_env "$BH" "$BH/repo" verify 2>&1)" "last successful backup"

it "but does not fail -- a stale backup is still a backup"
_stale_env "$BH" "$BH/repo" verify >/dev/null 2>&1
[[ $? -eq 0 ]] && ok || fail "staleness turned into a failure"

# ── never having run at all is its own answer ──────────────────────────────
CH="$(_stale_home)"

it "a machine that has never synced is reported stale, not fresh"
assert_eq "$(_stale_env "$CH" "$CH/repo" status --json | jq -r '.stale')" "true"

it "and says so plainly rather than reporting an age of zero"
assert_eq "$(_stale_env "$CH" "$CH/repo" status --json | jq -r '.lastSync')" "null"

it "verify names it as never having run"
assert_contains "$(_stale_env "$CH" "$CH/repo" verify 2>&1)" "never"

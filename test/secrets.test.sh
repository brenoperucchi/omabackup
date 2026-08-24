# Regressions for the deny-list scanner (lib/secrets.sh), docs/DESIGN.md §6.
#
# It blocks the push rather than warning about it. §6 is explicit about why: a
# leak is irreversible, and "it warns" is exactly the failure mode of lesson #1
# -- a warning nobody reads. This matters more now than when it was designed,
# because push runs unattended on an hourly timer: there is nobody there to read
# a warning at 03:00.
#
# The other half of these specs is the false-positive side. A scanner that fires
# on ordinary config teaches you to pass --force, which is the same failure one
# step later.

OB="$PWD/bin/omabackup"

_sec_env() {  # _sec_env <home> <repo> <args...>
    local h="$1" r="$2"; shift 2
    HOME="$h" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$PWD/groups.default.json" \
        OMABACKUP_STATE="$h/.state" OMABACKUP_REPO="$r" \
        OMABACKUP_DESTINATIONS="$h/destinations.json" \
        XDG_RUNTIME_DIR=/nonexistent "$OB" "$@" 2>&1
}

_sec_repo() {  # _sec_repo <dir> <file> <content>
    local r="$1"
    mkdir -p "$r/configs/app"
    git init -q "$r"; git -C "$r" config user.email t@t; git -C "$r" config user.name t
    printf 'ordinary config\n' >"$r/configs/app/fine.conf"
    [[ -n "${2:-}" ]] && printf '%s\n' "$3" >"$r/configs/app/$2"
    git -C "$r" add -A && git -C "$r" commit -qm one
}

source lib/secrets.sh

# ── the shapes that are a credential or nothing ──────────────────────────────
SH="$(mktemp -d)"
_check() {  # _check <label> <content> <expect hit|clean>
    local r="$SH/r$RANDOM$RANDOM"
    _sec_repo "$r" "probe.conf" "$2"
    local hits; hits="$(scan_secrets "$r" "$PWD/secrets.deny.json" 2>/dev/null)"
    it "$1"
    if [[ "$3" == hit ]]; then
        [[ -n "$hits" ]] && ok || fail "no hit on: $(printf '%s' "$2" | head -c 60)"
    else
        [[ -z "$hits" ]] && ok || fail "false positive: $hits"
    fi
}

_check "an unencrypted private key is caught" \
    "-----BEGIN OPENSSH PRIVATE KEY-----" hit
_check "an AWS access key id is caught" \
    "aws_access_key_id = AKIAIOSFODNN7EXAMPLE" hit
_check "a GitHub token is caught" \
    "token = ghp_016C7869C1D4C2E7B0F9A2B3D4E5F60718293A4B" hit
_check "a Slack token is caught" \
    "SLACK=xoxb-1234567890-abcdefghijkl" hit
_check "an OpenAI-style key is caught" \
    "OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz0123456789" hit
_check "a long literal assigned to something named like a credential is caught" \
    'client_secret: "8f4b2c9e1a7d3f6b5e8c0a2d4f6b8e0c"' hit

# ── and the things that merely look alarming ─────────────────────────────────
# Every one of these is real config from a real dotfiles tree.
_check "a chromium keyring flag is not a secret" \
    "--password-store=gnome-libsecret" clean
_check "an option merely named after a token is not one" \
    "set hide_token_restore on" clean
_check "a variable reference is not a literal" \
    'export API_KEY="$MY_KEY_FROM_KEYRING"' clean
_check "an empty default is not a credential" \
    'client_secret: ""' clean
_check "age ciphertext is how secrets are meant to be stored here" \
    "-----BEGIN AGE ENCRYPTED FILE-----" clean
_check "a password prompt string is not a password" \
    'read -s -p "password: " pw' clean
_check "ordinary config passes untouched" \
    "theme = catppuccin" clean

# ── it blocks the push, it does not warn about it ────────────────────────────
BH="$(mktemp -d)"; BR="$BH/repo"
_sec_repo "$BR" "leaked.conf" "-----BEGIN OPENSSH PRIVATE KEY-----"
BNAS="$BH/nas"
cat >"$BH/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"nas","type":"dir","path":"$BNAS","keep":2}]}
JSON
BOUT="$(_sec_env "$BH" "$BR" push)"
BRC=$?

it "push refuses to send when the deny-list hits"
[[ $BRC -ne 0 ]] && ok || fail "push exited 0 carrying a private key"

it "and nothing reached the destination"
[[ ! -d "$BNAS" || -z "$(find "$BNAS" -name 'omabackup-*' 2>/dev/null)" ]] \
    && ok || fail "a bundle was written despite the hit"

it "it names the file, so the fix is obvious"
assert_contains "$BOUT" "leaked.conf"

it "and names which rule fired"
assert_contains "$BOUT" "private-key-block"

it "the wording says blocked, not warned"
assert_contains "$BOUT" "blocked"

# ── github is gated too, not just the bundle destinations ────────────────────
# The git push sends the same content. Gating only the bundle would leave the
# default destination as the one hole.
GH="$(mktemp -d)"; GR="$GH/repo"
_sec_repo "$GR" "leaked.conf" "aws_access_key_id = AKIAIOSFODNN7EXAMPLE"
GREMOTE="$GH/remote.git"; git init -q --bare "$GREMOTE"
git -C "$GR" remote add origin "$GREMOTE"
printf '{"schemaVersion":1,"destinations":[]}\n' >"$GH/destinations.json"
_sec_env "$GH" "$GR" push >/dev/null

it "a hit blocks the git push as well"
assert_eq "$(git -C "$GREMOTE" rev-list --all --count 2>/dev/null)" "0"

# ── a clean repo is not obstructed ───────────────────────────────────────────
CH="$(mktemp -d)"; CR="$CH/repo"
_sec_repo "$CR" "" ""
CNAS="$CH/nas"
cat >"$CH/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"nas","type":"dir","path":"$CNAS","keep":2}]}
JSON
_sec_env "$CH" "$CR" push nas >/dev/null

it "a clean repo pushes normally"
assert_eq "$(find "$CNAS" -maxdepth 1 -name 'omabackup-*.tar.zst' 2>/dev/null | wc -l)" "1"

# ── the manifest cannot declare a rule the scanner ignores ───────────────────
DH="$(mktemp -d)"; DR="$DH/repo"; _sec_repo "$DR" "" ""
cat >"$DH/deny.json" <<'JSON'
{"schemaVersion":1,"patterns":[{"id":"x","regex":"y","reason":"z","fieldNobodyImplemented":true}],"exceptions":[]}
JSON

it "an unknown field in the deny-list aborts rather than being skipped"
assert_contains "$(OMABACKUP_SECRETS_DENY="$DH/deny.json" _sec_env "$DH" "$DR" push 2>&1)" \
    "fieldNobodyImplemented"

it "and a pattern with no reason is refused -- a rule nobody can justify gets forced past"
cat >"$DH/deny2.json" <<'JSON'
{"schemaVersion":1,"patterns":[{"id":"x","regex":"y"}],"exceptions":[]}
JSON
assert_contains "$(OMABACKUP_SECRETS_DENY="$DH/deny2.json" _sec_env "$DH" "$DR" push 2>&1)" "reason"

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

# ── the scanner must cover what the bundle actually carries ──────────────────
# It scanned `git grep HEAD` while the bundle ships `git bundle --all HEAD`.
# Reproduced: commit a private key, remove it in the next commit, and the
# scanner reports clean while the key stays recoverable from the artifact that
# leaves the machine. A secret you believe you deleted still ships.
HH="$(mktemp -d)"; HR="$HH/repo"
mkdir -p "$HR"; git init -q "$HR"
git -C "$HR" config user.email t@t; git -C "$HR" config user.name t
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\n' >"$HR/leak.txt"
git -C "$HR" add -A && git -C "$HR" commit -qm oops
git -C "$HR" rm -q leak.txt && git -C "$HR" commit -qm removed

it "a secret removed from HEAD but alive in history is still found"
[[ -n "$(scan_secrets "$HR" "$PWD/secrets.deny.json" 2>/dev/null)" ]] \
    && ok || fail "history was not scanned -- the bundle ships --all"

it "and a secret on a branch that is not HEAD is found"
BR2="$(mktemp -d)/repo"; mkdir -p "$BR2"; git init -q "$BR2"
git -C "$BR2" config user.email t@t; git -C "$BR2" config user.name t
printf 'clean\n' >"$BR2/f.txt"; git -C "$BR2" add -A; git -C "$BR2" commit -qm one
git -C "$BR2" checkout -q -b side
printf 'token = ghp_016C7869C1D4C2E7B0F9A2B3D4E5F60718293A4B\n' >"$BR2/s.txt"
git -C "$BR2" add -A; git -C "$BR2" commit -qm side
git -C "$BR2" checkout -q master 2>/dev/null || git -C "$BR2" checkout -q main
[[ -n "$(scan_secrets "$BR2" "$PWD/secrets.deny.json" 2>/dev/null)" ]] \
    && ok || fail "another ref was not scanned -- git bundle --all carries it"

# ── an exception explains one thing, it does not clear the line ─────────────
# Exceptions were plain substrings tested against the whole matched line, so an
# innocent phrase anywhere on it swallowed a real credential beside it.
ER="$(mktemp -d)/repo"; mkdir -p "$ER"; git init -q "$ER"
git -C "$ER" config user.email t@t; git -C "$ER" config user.name t
printf 'set hide_token_restore on # aws_access_key_id = AKIAIOSFODNN7EXAMPLE\n' >"$ER/f.conf"
git -C "$ER" add -A && git -C "$ER" commit -qm x

it "an excepted phrase does not clear a real credential sharing its line"
[[ -n "$(scan_secrets "$ER" "$PWD/secrets.deny.json" 2>/dev/null)" ]] \
    && ok || fail "the exception swallowed the AWS key next to it"

it "but the excepted phrase alone still passes"
ER2="$(mktemp -d)/repo"; mkdir -p "$ER2"; git init -q "$ER2"
git -C "$ER2" config user.email t@t; git -C "$ER2" config user.name t
printf 'set hide_token_restore on\n' >"$ER2/f.conf"
git -C "$ER2" add -A && git -C "$ER2" commit -qm x
[[ -z "$(scan_secrets "$ER2" "$PWD/secrets.deny.json" 2>/dev/null)" ]] \
    && ok || fail "the exception stopped working"

# ── a gate that cannot run must not read as "clean" ─────────────────────────
# Missing deny-list, unreadable JSON, a regex git rejects: each produced no
# output, which was indistinguishable from finding nothing, and the push went
# out. A security gate fails closed or it is not a gate.
FH="$(mktemp -d)"; FR="$FH/repo"; _sec_repo "$FR" "" ""
printf '{"schemaVersion":1,"destinations":[]}\n' >"$FH/destinations.json"

it "push refuses when the deny-list is missing entirely"
OUT_MISS="$(OMABACKUP_SECRETS_DENY="$FH/nope.json" _sec_env "$FH" "$FR" push 2>&1)"
assert_contains "$OUT_MISS" "deny-list"

it "push refuses when the deny-list cannot be parsed"
printf 'not json at all\n' >"$FH/broken.json"
OUT_BROKEN="$(OMABACKUP_SECRETS_DENY="$FH/broken.json" _sec_env "$FH" "$FR" push 2>&1)"
assert_contains "$OUT_BROKEN" "deny-list"

it "push refuses when a pattern is a regex git will not accept"
printf '%s\n' '{"schemaVersion":1,"patterns":[{"id":"bad","regex":"[unclosed","reason":"deliberately invalid"}],"exceptions":[]}' >"$FH/badre.json"
OUT_BADRE="$(OMABACKUP_SECRETS_DENY="$FH/badre.json" _sec_env "$FH" "$FR" push 2>&1)"
assert_contains "$OUT_BADRE" "bad"

# ── "no commits" and "this repo is broken" are not the same answer ─────────
# rev-list exits 0 with no output for an empty repo and 128 for a broken one,
# but the output was read through `mapfile < <(...)`, which throws the exit
# status away. Both became "nothing to scan", which became "clean", which
# became a push. The file this lives in claims everything fails closed.
XR="$(mktemp -d)/repo"; mkdir -p "$XR/.git"
printf 'not a ref\n' >"$XR/.git/HEAD"

it "a repository git cannot read is not reported as clean"
scan_secrets "$XR" "$PWD/secrets.deny.json" >/dev/null 2>&1 \
    && fail "a broken repo scanned clean" || ok

it "and push refuses on it rather than sending"
XH="$(mktemp -d)"; printf '{"schemaVersion":1,"destinations":[]}\n' >"$XH/destinations.json"
XOUT="$(_sec_env "$XH" "$XR" push 2>&1)"
assert_contains "$XOUT" "blocked"

# ── an empty repository is genuinely empty, and says so quietly ────────────
YR="$(mktemp -d)/repo"; git init -q "$YR"

it "a repository with no commits scans clean without an error"
scan_secrets "$YR" "$PWD/secrets.deny.json" >/dev/null 2>&1 \
    && ok || fail "an empty repo was treated as a scan failure"

# ── a commit message is content too ────────────────────────────────────────
# `git grep <rev>` searches the tree at that commit. It does not read the commit
# message, or an annotated tag's own object -- and `git bundle --all` packs both.
# A token pasted into a commit message shipped and scanned clean. Found by
# review, not by me: I had reasoned about which commits to scan and never about
# which parts of one.
MR="$(mktemp -d)/repo"; mkdir -p "$MR"; git init -q "$MR"
git -C "$MR" config user.email t@t; git -C "$MR" config user.name t
printf 'ok\n' >"$MR/f.txt"; git -C "$MR" add -A
git -C "$MR" commit -q -m "fix: with token ghp_016C7869C1D4C2E7B0F9A2B3D4E5F60718293A4B"

it "a secret in a commit message is found"
[[ -n "$(scan_secrets "$MR" "$PWD/secrets.deny.json" 2>/dev/null)" ]] \
    && ok || fail "commit messages are packed by git bundle and were never read"

it "and one in an annotated tag is found too"
TR="$(mktemp -d)/repo"; mkdir -p "$TR"; git init -q "$TR"
git -C "$TR" config user.email t@t; git -C "$TR" config user.name t
printf 'ok\n' >"$TR/f.txt"; git -C "$TR" add -A; git -C "$TR" commit -qm clean
git -C "$TR" tag -a v1 -m "release, key AKIAIOSFODNN7EXAMPLE"
[[ -n "$(scan_secrets "$TR" "$PWD/secrets.deny.json" 2>/dev/null)" ]] \
    && ok || fail "an annotated tag object is packed and was never read"

# ── a deny-list that yields no patterns is not a clean bill of health ──────
# jq ran inside a process substitution, so an unreadable deny-list produced zero
# patterns, the loop never ran, and the function returned success. cmd_push
# happens to validate first, but the scanner must not depend on its caller
# having been careful.
NR="$(mktemp -d)/repo"; mkdir -p "$NR"; git init -q "$NR"
git -C "$NR" config user.email t@t; git -C "$NR" config user.name t
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\n' >"$NR/leak"
git -C "$NR" add -A && git -C "$NR" commit -qm x
BADF="$(mktemp)"; printf '{"patterns": [BROKEN\n' >"$BADF"

it "an unreadable deny-list makes the scan fail, not pass"
scan_secrets "$NR" "$BADF" >/dev/null 2>&1 \
    && fail "zero patterns read reported as clean, over a real private key" || ok

it "and a deny-list with no patterns at all is refused rather than trusted"
EMPTYF="$(mktemp)"; printf '{"schemaVersion":1,"patterns":[],"exceptions":[]}\n' >"$EMPTYF"
scan_secrets "$NR" "$EMPTYF" >/dev/null 2>&1 \
    && fail "an empty rule set scanned clean" || ok

# ── an exception must not be able to disable a rule ────────────────────────
# _still_matches cuts excepted text out of the line and retries the pattern, so
# an exception that overlaps a credential shape would blank out that shape
# wherever it appeared -- a one-line entry silently switching off a detector.
# Caught at validation, where the cost of being wrong is a message instead of a
# leak.
AH="$(mktemp -d)"; AR="$AH/repo"; _sec_repo "$AR" "" ""
printf '{"schemaVersion":1,"destinations":[]}\n' >"$AH/destinations.json"
cat >"$AH/selfdefeating.json" <<'JSON'
{"schemaVersion":1,
 "patterns":[{"id":"aws","regex":"\\bAKIA[0-9A-Z]{16}\\b","reason":"AWS key id"}],
 "exceptions":[{"id":"oops","match":"AKIAIOSFODNN7EXAMPLE","reason":"looks harmless, is the whole key"}]}
JSON

it "an exception matching one of the deny patterns is refused"
assert_contains "$(OMABACKUP_SECRETS_DENY="$AH/selfdefeating.json" _sec_env "$AH" "$AR" push 2>&1)" \
    "oops"

it "while an exception that matches nothing dangerous is accepted"
cat >"$AH/fine.json" <<'JSON'
{"schemaVersion":1,
 "patterns":[{"id":"aws","regex":"\\bAKIA[0-9A-Z]{16}\\b","reason":"AWS key id"}],
 "exceptions":[{"id":"flag","match":"--password-store=gnome-libsecret","reason":"a keyring flag"}]}
JSON
assert_not_contains "$(OMABACKUP_SECRETS_DENY="$AH/fine.json" _sec_env "$AH" "$AR" push 2>&1)" \
    "cannot honor"

# ── the scanner leaves no state behind ─────────────────────────────────────
it "scanning does not leak its exception list into the caller"
unset DENY_EXCEPTIONS 2>/dev/null || true
scan_secrets "$AR" "$PWD/secrets.deny.json" >/dev/null 2>&1
[[ -z "${DENY_EXCEPTIONS+set}" ]] && ok || fail "DENY_EXCEPTIONS survived the call"

# ── a hit in a message has to say which commit ─────────────────────────────
# The tree scan reports `<sha>:<file>:<line>`. The message scan reported the
# offending line and nothing else, because it grepped one concatenated blob of
# every message at once. For a secret in a commit message the remedy is
# rewriting history, and you cannot rewrite what you cannot locate.
CMH="$(mktemp -d)/repo"; mkdir -p "$CMH"; git init -q "$CMH"
git -C "$CMH" config user.email t@t; git -C "$CMH" config user.name t
printf 'a\n' >"$CMH/f"; git -C "$CMH" add -A; git -C "$CMH" commit -qm "clean one"
printf 'b\n' >>"$CMH/f"; git -C "$CMH" add -A
git -C "$CMH" commit -q -m "first line
aws_access_key_id = AKIAIOSFODNN7EXAMPLE"
CMGUILTY="$(git -C "$CMH" rev-parse HEAD)"
CMHIT="$(scan_secrets "$CMH" "$PWD/secrets.deny.json" 2>/dev/null)"

it "a secret in a commit message names the commit that carries it"
assert_contains "$CMHIT" "${CMGUILTY:0:12}"

it "and not the innocent commit beside it"
CMCLEAN="$(git -C "$CMH" rev-parse HEAD~1)"
assert_not_contains "$CMHIT" "${CMCLEAN:0:12}"

it "a multi-line message does not let a match span two commits"
# %H%n%B concatenated every message into one blob, so a pattern could match
# across the seam between one commit's body and the next one's hash.
CMS="$(mktemp -d)/repo"; mkdir -p "$CMS"; git init -q "$CMS"
git -C "$CMS" config user.email t@t; git -C "$CMS" config user.name t
printf 'a\n' >"$CMS/f"; git -C "$CMS" add -A
# Two halves that only form a key when joined -- neither matches alone, so a
# hit here could only come from the seam.
git -C "$CMS" commit -q -m "key prefix AKIAIOSFODN"
printf 'b\n' >>"$CMS/f"; git -C "$CMS" add -A
git -C "$CMS" commit -q -m "N7EXAMPLE is the rest of it"
[[ -z "$(scan_secrets "$CMS" "$PWD/secrets.deny.json" 2>/dev/null)" ]] \
    && ok || fail "a match spanned the seam between two messages"

# ── an exception excuses a match, it does not edit the line ────────────────
# The scanner cut excepted text out of the line and retested the pattern on
# what was left. A four-character exception then bypassed it completely: "AKIA"
# does not itself match `\bAKIA[0-9A-Z]{16}\b`, so validation accepted it, and
# removing "AKIA" from the line destroyed the key. One innocuous-looking line
# in a JSON file turned the whole detector off.
#
# So an exception no longer rewrites anything: a match is excused only when the
# exception CONTAINS that exact matched text -- when it is genuinely the thing
# the exception was written to explain.
PXH="$(mktemp -d)"
cat >"$PXH/partial.json" <<'JSON'
{"schemaVersion":1,
 "patterns":[{"id":"aws","regex":"\\bAKIA[0-9A-Z]{16}\\b","reason":"AWS key id"}],
 "exceptions":[{"id":"innocent","match":"AKIA","reason":"a fragment, not a key"}]}
JSON
PXR="$(mktemp -d)/repo"; mkdir -p "$PXR"; git init -q "$PXR"
git -C "$PXR" config user.email t@t; git -C "$PXR" config user.name t
printf 'aws_access_key_id = AKIAIOSFODNN7EXAMPLE\n' >"$PXR/f.conf"
git -C "$PXR" add -A && git -C "$PXR" commit -qm x

it "an exception that is a fragment of a secret does not excuse the secret"
[[ -n "$(scan_secrets "$PXR" "$PXH/partial.json" 2>/dev/null)" ]] \
    && ok || fail "a four-character exception switched the detector off"

it "and two exceptions cannot be combined to erase one either"
cat >"$PXH/two.json" <<'JSON'
{"schemaVersion":1,
 "patterns":[{"id":"aws","regex":"\\bAKIA[0-9A-Z]{16}\\b","reason":"AWS key id"}],
 "exceptions":[{"id":"a","match":"AKIAIOSF","reason":"half"},
               {"id":"b","match":"ODNN7EXAMPLE","reason":"other half"}]}
JSON
[[ -n "$(scan_secrets "$PXR" "$PXH/two.json" 2>/dev/null)" ]] \
    && ok || fail "two fragments together erased the key"

it "while a real exception still excuses what it was written for"
# The shipped ones must keep working: this is the case the cutting existed for.
CLR="$(mktemp -d)/repo"; mkdir -p "$CLR"; git init -q "$CLR"
git -C "$CLR" config user.email t@t; git -C "$CLR" config user.name t
printf -- '--password-store=gnome-libsecret\n' >"$CLR/f.conf"
git -C "$CLR" add -A && git -C "$CLR" commit -qm x
[[ -z "$(scan_secrets "$CLR" "$PWD/secrets.deny.json" 2>/dev/null)" ]] \
    && ok || fail "a legitimate exception stopped working"

it "and a phrase beside a real credential still does not excuse it"
BTH="$(mktemp -d)/repo"; mkdir -p "$BTH"; git init -q "$BTH"
git -C "$BTH" config user.email t@t; git -C "$BTH" config user.name t
printf 'set hide_token_restore on # aws_access_key_id = AKIAIOSFODNN7EXAMPLE\n' >"$BTH/f.conf"
git -C "$BTH" add -A && git -C "$BTH" commit -qm x
[[ -n "$(scan_secrets "$BTH" "$PWD/secrets.deny.json" 2>/dev/null)" ]] \
    && ok || fail "the exception swallowed the key beside it"

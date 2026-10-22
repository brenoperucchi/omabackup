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

it "an exception equal to a real key excuses only that key, and nothing else"
# This assertion inverted when exceptions moved from cut-and-retest to
# equality. Refusing an exception that matches a pattern made every exception
# impossible, since an unreachable one is refused too. Under equality the
# entry excuses exactly the string it names -- deliberate, reviewable, and
# carrying a reason -- while a different key of the same shape still blocks.
OTHERR="$(mktemp -d)/repo"; mkdir -p "$OTHERR"; git init -q "$OTHERR"
git -C "$OTHERR" config user.email t@t; git -C "$OTHERR" config user.name t
printf 'aws_access_key_id = AKIAZZZZZZZZZZZZZZZZ\n' >"$OTHERR/f.conf"
git -C "$OTHERR" add -A && git -C "$OTHERR" commit -qm x
[[ -n "$(scan_secrets "$OTHERR" "$AH/selfdefeating.json" 2>/dev/null)" ]] \
    && ok || fail "an exception for one key excused a different one"

it "while an exception a rule genuinely produces is accepted"
# This assertion inverted deliberately. An exception matching nothing was once
# "harmless"; it is now refused, because an entry no pattern can produce reads
# as protection while protecting nothing.
cat >"$AH/fine.json" <<'JSON'
{"schemaVersion":1,
 "patterns":[{"id":"flag","ignoreCase":true,"regex":"password-store=[a-z-]+","reason":"fires on the flag"}],
 "exceptions":[{"id":"chromium","match":"password-store=gnome-libsecret","reason":"a keyring flag"}]}
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

# ── a secret inside a binary still ships ───────────────────────────────────
# `git grep -I` skips binary blobs, and `git bundle` packs them regardless. A
# credential in a .env compiled into something, a key inside an archive, a
# config with one stray NUL byte: none were scanned. The patterns are
# high-signal ASCII shapes, so reading binary as text costs no realistic false
# positive and closes the hole.
BINR="$(mktemp -d)/repo"; mkdir -p "$BINR"; git init -q "$BINR"
git -C "$BINR" config user.email t@t; git -C "$BINR" config user.name t
printf 'text\x00binary\naws_access_key_id = AKIAIOSFODNN7EXAMPLE\n' >"$BINR/blob.bin"
git -C "$BINR" add -A && git -C "$BINR" commit -qm x

it "a credential inside a binary blob is found"
[[ -n "$(scan_secrets "$BINR" "$PWD/secrets.deny.json" 2>/dev/null)" ]] \
    && ok || fail "binary blobs went unscanned while the bundle carried them"

it "and what it prints stays readable rather than dumping the blob"
# The secret shares its line with control bytes here, so the report has
# something to sanitise. Checked with tr rather than a bash pattern: a bash
# string cannot hold a NUL at all, so matching against $'\x00' compares against
# the empty string and passes for any input -- a check that cannot fail.
BINR2="$(mktemp -d)/repo"; mkdir -p "$BINR2"; git init -q "$BINR2"
git -C "$BINR2" config user.email t@t; git -C "$BINR2" config user.name t
printf 'aws_access_key_id = AKIAIOSFODNN7EXAMPLE \x01\x02\x07 trailing\n' >"$BINR2/blob.bin"
git -C "$BINR2" add -A && git -C "$BINR2" commit -qm x
BINOUT="$(scan_secrets "$BINR2" "$PWD/secrets.deny.json" 2>/dev/null)"
assert_eq "$(printf '%s' "$BINOUT" | tr -d '[:print:]\t\n' | wc -c)" "0"

it "while still reporting the credential it found in there"
assert_contains "$BINOUT" "AKIAIOSFODNN7EXAMPLE"

# ── the deny-list check cannot pass by failing ─────────────────────────────
it "a deny-list that is valid JSON but the wrong shape is refused"
# assert_deny_understood built its findings with a command substitution whose
# exit status nobody read. This file parses as JSON, so `jq -e .` is happy, but
# `.patterns[]` errors on a string -- which produced no findings, which read as
# "nothing wrong with this deny-list".
SHAPEH="$(mktemp -d)"; SHAPER="$SHAPEH/repo"; _sec_repo "$SHAPER" "" ""
printf '{"schemaVersion":1,"patterns":"not an array","exceptions":[]}\n' >"$SHAPEH/shape.json"
printf '{"schemaVersion":1,"destinations":[]}\n' >"$SHAPEH/destinations.json"
assert_contains "$(OMABACKUP_SECRETS_DENY="$SHAPEH/shape.json" _sec_env "$SHAPEH" "$SHAPER" push 2>&1)" \
    "deny-list"

# ── an exception must BE the match, not merely contain it ──────────────────
# Containment let an exception excuse a secret it happened to enclose:
# "exemploAKIAIOSFODNN7EXAMPLEfim" contains the key, so the key was excused
# everywhere. Same class as the four-character bypass, needing a longer string.
WBH="$(mktemp -d)"
cat >"$WBH/wrapped.json" <<'JSON'
{"schemaVersion":1,
 "patterns":[{"id":"aws","regex":"\\bAKIA[0-9A-Z]{16}\\b","reason":"AWS key id"}],
 "exceptions":[{"id":"quoted","match":"exemploAKIAIOSFODNN7EXAMPLEfim","reason":"quoted in prose"}]}
JSON
WBR="$(mktemp -d)/repo"; mkdir -p "$WBR"; git init -q "$WBR"
git -C "$WBR" config user.email t@t; git -C "$WBR" config user.name t
printf 'aws_access_key_id = AKIAIOSFODNN7EXAMPLE\n' >"$WBR/f.conf"
git -C "$WBR" add -A && git -C "$WBR" commit -qm x

it "an exception that merely encloses a secret does not excuse it"
[[ -n "$(scan_secrets "$WBR" "$WBH/wrapped.json" 2>/dev/null)" ]] \
    && ok || fail "an exception wrapping the key excused it"

# ── a case-insensitive pattern gets case-insensitive exceptions ────────────
# Declaring ignoreCase and then comparing exceptions case-sensitively is an
# inconsistency that fails closed -- it blocks what should pass -- but a rule
# should mean the same thing in both halves.
CIH="$(mktemp -d)"
cat >"$CIH/ci.json" <<'JSON'
{"schemaVersion":1,
 "patterns":[{"id":"t","ignoreCase":true,"regex":"\\bsecret-[a-z0-9]{10}\\b","reason":"test shape"}],
 "exceptions":[{"id":"doc","match":"secret-abcdefghij","reason":"the documented example"}]}
JSON
CIR="$(mktemp -d)/repo"; mkdir -p "$CIR"; git init -q "$CIR"
git -C "$CIR" config user.email t@t; git -C "$CIR" config user.name t
printf 'value = SECRET-ABCDEFGHIJ\n' >"$CIR/f.conf"
git -C "$CIR" add -A && git -C "$CIR" commit -qm x

it "a lowercase exception excuses the uppercase form of an ignoreCase pattern"
[[ -z "$(scan_secrets "$CIR" "$CIH/ci.json" 2>/dev/null)" ]] \
    && ok || fail "the exception did not apply to the same rule's other casing"

# ── the shipped chromium exception is actually exercised ───────────────────
# The old spec asserted this line scans clean, and it did -- but because no
# pattern matches it at all (the value is unquoted, so generic-assigned-secret
# never fires). The exception was never reached: the sixth green spec this
# session that proved nothing. This one makes the pattern match first.
CXH="$(mktemp -d)"
cat >"$CXH/cx.json" <<'JSON'
{"schemaVersion":1,
 "patterns":[{"id":"flagged","ignoreCase":true,"regex":"password-store=[a-z-]+","reason":"deliberately matches the flag"}],
 "exceptions":[{"id":"chromium","match":"password-store=gnome-libsecret","reason":"a keyring flag, not a secret"}]}
JSON
CXR="$(mktemp -d)/repo"; mkdir -p "$CXR"; git init -q "$CXR"
git -C "$CXR" config user.email t@t; git -C "$CXR" config user.name t
printf -- '--password-store=gnome-libsecret\n' >"$CXR/f.conf"
git -C "$CXR" add -A && git -C "$CXR" commit -qm x

it "an exception excuses a match that a pattern really produced"
[[ -z "$(scan_secrets "$CXR" "$CXH/cx.json" 2>/dev/null)" ]] \
    && ok || fail "the exception did not excuse a genuine match"

it "and the same rule still fires on a value it does not except"
printf -- '--password-store=something-else\n' >"$CXR/g.conf"
git -C "$CXR" add -A && git -C "$CXR" commit -qm y
[[ -n "$(scan_secrets "$CXR" "$CXH/cx.json" 2>/dev/null)" ]] \
    && ok || fail "the exception excused everything the rule matched"

# ── an exception no pattern can reach is not protection ────────────────────
# All three shipped exceptions turned out unreachable: no pattern matches the
# lines they excuse, because the patterns are precise enough not to fire there.
# They read as "we handle these false positives" while the false positives do
# not exist -- the same shape as a rule declared and silently ignored, which
# this project refuses everywhere else.
URH="$(mktemp -d)"; URR="$URH/repo"; _sec_repo "$URR" "" ""
printf '{"schemaVersion":1,"destinations":[]}\n' >"$URH/destinations.json"
cat >"$URH/dead.json" <<'JSON'
{"schemaVersion":1,
 "patterns":[{"id":"aws","regex":"\\bAKIA[0-9A-Z]{16}\\b","reason":"AWS key id"}],
 "exceptions":[{"id":"dead","match":"nothing here resembles a key","reason":"unreachable"}]}
JSON

it "an exception no pattern can produce is refused"
assert_contains "$(OMABACKUP_SECRETS_DENY="$URH/dead.json" _sec_env "$URH" "$URR" push 2>&1)" "dead"

it "and the shipped deny-list has no unreachable exceptions of its own"
assert_eq "$(jq -r '.exceptions | length' "$PWD/secrets.deny.json")" "0"

# ── a history the scanner could not read is not a history without secrets ────
# Commit messages were collected through an unchecked pipeline: a git that
# failed produced an empty string, every pattern found nothing in it, and the
# scan returned 0. The key in the message shipped. rev-list and the deny-list
# already refused on that shape; this half did not.
BLH="$(mktemp -d)"; BLR="$BLH/repo"; _sec_repo "$BLR" "" ""
git -C "$BLR" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m 'chave AKIA1234567890ABCDEF vazada' 2>/dev/null
mkdir -p "$BLH/fakebin"
{ printf '#!/bin/bash\n'
  printf 'for a in "$@"; do [[ "$a" == log ]] && exit 128; done\n'
  printf 'exec %s "$@"\n' "$(command -v git)"
} >"$BLH/fakebin/git"; chmod +x "$BLH/fakebin/git"

it "the key in a commit message is found while git works"
assert_contains "$(bash -c '
    source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
    scan_secrets "$1" "$2"' _ "$BLR" "$PWD/secrets.deny.json" 2>&1)" "AKIA1234567890ABCDEF"

BLOUT="$(PATH="$BLH/fakebin:$PATH" bash -c '
    source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
    scan_secrets "$1" "$2"' _ "$BLR" "$PWD/secrets.deny.json" 2>&1)"; BLRC=$?

it "and a git that cannot read the log refuses instead of reporting clean"
[[ $BLRC -ne 0 ]] && ok || fail "returned success on a history it could not read: ${BLOUT:-<no output>}"

# ── an exception validated by containment could never fire ──────────────────
# Reachability asked whether some pattern matched anywhere INSIDE the exception
# while _still_matches requires the exception to BE the match, so an exception
# carrying extra context passed validation and was dead at scan time.
CTH="$(mktemp -d)"; CTR="$CTH/repo"; _sec_repo "$CTR" "" ""
printf '{"schemaVersion":1,"destinations":[]}\n' >"$CTH/destinations.json"
cat >"$CTH/wider.json" <<'JSON'
{"schemaVersion":1,
 "patterns":[{"id":"aws","regex":"\\bAKIA[0-9A-Z]{16}\\b","reason":"AWS key id"}],
 "exceptions":[{"id":"wrapped","match":"exemplo AKIA1234567890ABCDEF fim",
                "reason":"carries context the pattern never matches"}]}
JSON

it "an exception that merely contains a match is refused, not silently dead"
assert_contains "$(OMABACKUP_SECRETS_DENY="$CTH/wider.json" _sec_env "$CTH" "$CTR" push 2>&1)" "wrapped"

# ── a pattern that matches everything and reports nothing ───────────────────
# "^" matches every line and hands grep -o nothing to extract, so the match
# array came back empty and _still_matches called the line clean -- a live
# deny-list entry that could never fire. Validation refuses it now, and the
# scanner fails closed if one ever reaches it anyway.
ZWH="$(mktemp -d)"; ZWR="$ZWH/repo"; _sec_repo "$ZWR" "" ""
printf '{"schemaVersion":1,"destinations":[]}\n' >"$ZWH/destinations.json"
cat >"$ZWH/zerowidth.json" <<'JSON'
{"schemaVersion":1,
 "patterns":[{"id":"everything","regex":"^","reason":"matches every line"}],
 "exceptions":[]}
JSON

it "a pattern that can match the empty string is refused"
assert_contains "$(OMABACKUP_SECRETS_DENY="$ZWH/zerowidth.json" _sec_env "$ZWH" "$ZWR" push 2>&1)" "everything"

it "and the refusal says why, not just that something is wrong"
assert_contains "$(OMABACKUP_SECRETS_DENY="$ZWH/zerowidth.json" _sec_env "$ZWH" "$ZWR" push 2>&1)" "empty string"

it "a line the pattern matched is never called clean for want of an extract"
bash -c 'source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
         DENY_EXCEPTIONS=(); _still_matches "abc AKIA1234567890ABCDEF" "^" false' \
    && ok || fail "zero-width match read as no match: the scanner failed open"

it "a regex the scanner cannot compile is refused too"
cat >"$ZWH/broken.json" <<'JSON'
{"schemaVersion":1,
 "patterns":[{"id":"malformed","regex":"[unclosed","reason":"not a regex"}],
 "exceptions":[]}
JSON
assert_contains "$(OMABACKUP_SECRETS_DENY="$ZWH/broken.json" _sec_env "$ZWH" "$ZWR" push 2>&1)" "malformed"

# ── an anchored pattern, and the decoration git grep puts in front of a hit ──
# git grep prefixes each hit with "<rev>:<path>:<lineno>:" and _still_matches
# was re-applying the pattern to that. ^AKIA[0-9A-Z]{16}$ matched inside git
# grep and failed here, because ^ no longer sat where the key begins -- the two
# halves disagreed and the disagreement resolved to "clean". The push went out
# with the key in it.
ANH="$(mktemp -d)"; ANR="$ANH/repo"; _sec_repo "$ANR" "" ""
printf 'AKIA1234567890ABCDEF\n' >"$ANR/key.txt"
git -C "$ANR" add key.txt 2>/dev/null
git -C "$ANR" -c user.email=t@t -c user.name=t \
    commit -q -m 'AKIA1234567890ABCDEF' 2>/dev/null
cat >"$ANH/anchored.json" <<'JSON'
{"schemaVersion":1,
 "patterns":[{"id":"anchored","regex":"^AKIA[0-9A-Z]{16}$","reason":"a key alone on its line"}],
 "exceptions":[]}
JSON
ANOUT="$(bash -c 'source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
                  scan_secrets "$1" "$2"' _ "$ANR" "$ANH/anchored.json" 2>&1)"

it "a key alone on its line is found by an anchored pattern"
assert_contains "$ANOUT" "key.txt"

it "and the same pattern still finds it in a commit message"
assert_contains "$ANOUT" "commit:"

it "the report still names the file and line, not just the pattern"
assert_contains "$ANOUT" ":1:AKIA1234567890ABCDEF"

it "and still names the commit a message hit came from"
assert_contains "$ANOUT" "$(git -C "$ANR" rev-parse HEAD | cut -c1-12)"

it "a pattern that only matches empty on SOME lines is refused as such"
cat >"$ANH/sometimes.json" <<'JSON'
{"schemaVersion":1,
 "patterns":[{"id":"sometimes","regex":"a?","reason":"zero-width wherever there is no a"}],
 "exceptions":[]}
JSON
printf '{"schemaVersion":1,"destinations":[]}\n' >"$ANH/destinations.json"
# Refused at validation, by name and for the right reason -- not merely
# blocked downstream by the fail-closed lock, which is what happened while the
# probe was "a" and could not see it.
assert_contains "$(OMABACKUP_SECRETS_DENY="$ANH/sometimes.json" _sec_env "$ANH" "$ANR" push 2>&1)" "sometimes can match the empty string"

# ── a message that carries the byte the reader was using as a separator ─────
# Commit bodies were split on \x01 and the sha taken off with \x02. A message
# holding either byte produced a record the awk could not parse, and the awk
# dropped it -- so everything after that byte was never scanned at all. Entries
# are NUL-terminated now (the one byte a commit message cannot carry) and the
# sha is read by width, not by a second delimiter.
SEPH="$(mktemp -d)"; SEPR="$SEPH/repo"; _sec_repo "$SEPR" "" ""
git -C "$SEPR" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "$(printf 'nota\x01\nAKIA1234567890ABCDEF')" 2>/dev/null
git -C "$SEPR" -c user.email=t@t -c user.name=t \
    tag -a v9 -m "$(printf 'AKIA1234567890ABCDEF\nsegunda linha')" 2>/dev/null
cat >"$SEPH/anchored.json" <<'JSON'
{"schemaVersion":1,
 "patterns":[{"id":"anchored","regex":"^AKIA[0-9A-Z]{16}$","reason":"a key alone on its line"}],
 "exceptions":[]}
JSON
SEPOUT="$(bash -c 'source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
                   scan_secrets "$1" "$2"' _ "$SEPR" "$SEPH/anchored.json" 2>&1)"

it "a key after a separator byte in a commit message is still found"
assert_contains "$SEPOUT" "$(git -C "$SEPR" rev-parse HEAD | cut -c1-12)"

it "a key on the first line of a tag body is found by an anchored pattern"
assert_contains "$SEPOUT" "tag:refs/tags/v9"

# A cut whose status nobody read used to stand between the messages and the
# patterns: when it failed, every message vanished and the push carried on.
# Asserted through an UNANCHORED pattern and the sha, so what the spec proves is
# the cut path and not the anchoring fix above it.
mkdir -p "$SEPH/stub"
printf '#!/bin/bash\nexit 3\n' >"$SEPH/stub/cut"; chmod +x "$SEPH/stub/cut"
SEPSHA="$(git -C "$SEPR" rev-parse HEAD)"; SEPSHA="${SEPSHA:0:12}"

it "and the scan does not lean on a cut whose status it never read"
assert_contains "$(PATH="$SEPH/stub:$PATH" bash -c '
    source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
    scan_secrets "$1" "$2"' _ "$SEPR" "$PWD/secrets.deny.json" 2>&1)" "$SEPSHA"

# ── a grep that cannot answer must not answer "clean" ───────────────────────
# _still_matches read grep's output and not its status: through a process
# substitution "no matches" and "I could not run" were the same empty array, so
# a grep failing on both halves declared a line holding a key to be clean.
mkdir -p "$SEPH/badgrep"
{ printf '#!/bin/bash\n'
  printf 'for a in "$@"; do case "$a" in -*o*|-*q*) exit 2;; esac; done\n'
  printf 'exec %s "$@"\n' "$(command -v grep)"
} >"$SEPH/badgrep/grep"; chmod +x "$SEPH/badgrep/grep"

it "a line holding a key is a hit even when grep cannot be run on it"
PATH="$SEPH/badgrep:$PATH" bash -c '
    source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
    DENY_EXCEPTIONS=(); _still_matches "AKIA1234567890ABCDEF" "^AKIA[0-9A-Z]{16}$" false' \
    >/dev/null 2>&1 && ok || fail "a grep that could not run read as an absence of secrets"

# ── a repository with no commits is not a licence to skip the deny-list ─────
# The scan returned at the empty commit list, before the patterns were checked
# and before the tags were read -- and a tag can name a blob. An unreadable
# deny-list on an empty repository was reported as a clean scan.
EMH="$(mktemp -d)"; git -C "$EMH" init -q 2>/dev/null
printf 'not json at all\n' >"$EMH/broken.json"

it "an unreadable deny-list is refused even with nothing committed"
bash -c 'source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
         scan_secrets "$1" "$2"' _ "$EMH" "$EMH/broken.json" >/dev/null 2>&1 \
    && fail "called an unscanned empty repository clean" || ok

# ── an object a ref names outright ──────────────────────────────────────────
# `git bundle --all` packs every ref, and a ref is free to name a blob.
# rev-list lists commits, git grep reads the trees of commits, and a blob
# hanging off a tag belongs to neither -- so it shipped and it scanned clean.
# Cloning the bundle handed the key straight back.
BLBH="$(mktemp -d)"; BLBR="$BLBH/repo"; _sec_repo "$BLBR" "" ""
BLOB="$(printf 'AKIA1234567890ABCDEF\n' | git -C "$BLBR" hash-object -w --stdin)"
git -C "$BLBR" tag loose "$BLOB" 2>/dev/null
PEELED="$(printf 'AKIA9999999999999999\n' | git -C "$BLBR" hash-object -w --stdin)"
git -C "$BLBR" -c user.email=t@t -c user.name=t \
    tag -a wrapped -m 'points at a blob' "$PEELED" 2>/dev/null
BLBOUT="$(bash -c 'source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
                   scan_secrets "$1" "$2"' _ "$BLBR" "$PWD/secrets.deny.json" 2>&1)"

it "the bundle really would carry a blob that only a ref names"
git -C "$BLBR" bundle create "$BLBH/b.bundle" --all HEAD >/dev/null 2>&1
git clone -q "$BLBH/b.bundle" "$BLBH/clone" 2>/dev/null
assert_contains "$(git -C "$BLBH/clone" cat-file blob "$BLOB" 2>&1)" "AKIA1234567890ABCDEF"

it "a key in a blob a tag names directly is found"
assert_contains "$BLBOUT" "blob:refs/tags/loose"

it "and one behind an annotated tag is found after peeling"
assert_contains "$BLBOUT" "blob:refs/tags/wrapped"

it "the finding names the object kind rather than calling everything a message"
assert_contains "$BLBOUT" "AKIA9999999999999999"

# ── the rest of what the bundle carries ─────────────────────────────────────
# A commit packs its author and committer, a tag packs its tagger, a ref packs
# its name and a tree packs its paths. All of it is free text and all of it
# leaves the machine, and none of it was read: git log took %B, for-each-ref
# took %(contents) from refs/tags alone, and git grep searches what a file
# holds rather than what it is called.
RESTH="$(mktemp -d)"; RESTR="$RESTH/repo"; _sec_repo "$RESTR" "" ""
GIT_AUTHOR_NAME='AKIA1234567890ABCDEF' GIT_AUTHOR_EMAIL=a@b \
GIT_COMMITTER_NAME=n GIT_COMMITTER_EMAIL=n@b \
    git -C "$RESTR" commit -q --allow-empty -m 'a clean message' 2>/dev/null
printf 'harmless\n' >"$RESTR/AKIA2222222222222222.txt"
git -C "$RESTR" add . 2>/dev/null
git -C "$RESTR" -c user.email=t@t -c user.name=t commit -q -m 'add a file' 2>/dev/null
git -C "$RESTR" update-ref refs/heads/AKIA3333333333333333 HEAD 2>/dev/null
RESTTAG="$(git -C "$RESTR" mktag <<TAGOBJ 2>/dev/null
object $(git -C "$RESTR" rev-parse HEAD)
type commit
tag r9
tagger t <t@t> 0 +0000

AKIA4444444444444444
TAGOBJ
)"
[[ -n "$RESTTAG" ]] && git -C "$RESTR" update-ref refs/releases/r9 "$RESTTAG" 2>/dev/null
RESTOUT="$(bash -c 'source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
                    scan_secrets "$1" "$2"' _ "$RESTR" "$PWD/secrets.deny.json" 2>&1)"

it "a key in a commit author is found"
assert_contains "$RESTOUT" "AKIA1234567890ABCDEF"

it "a key used as a file name is found, though no file contains it"
assert_contains "$RESTOUT" "AKIA2222222222222222"

it "a key used as a branch name is found"
assert_contains "$RESTOUT" "AKIA3333333333333333"

it "an annotated tag outside refs/tags has its message read"
assert_contains "$RESTOUT" "AKIA4444444444444444"

# ── the tag object itself, and the tags behind it ───────────────────────────
# A tag object carries its own name in a "tag <name>" header, which need not
# match the refname and ships beside it. That name was reaching the scanner
# only because rev-list --objects happens to print it in the path column: a
# side effect, not a reading. And a tag may name another tag -- %(*objecttype)
# peels straight through to the final commit, so every tag object in between
# had its message read by nobody.
TAGH="$(mktemp -d)"; TAGR="$TAGH/repo"; _sec_repo "$TAGR" "" ""
TAGIN="$(git -C "$TAGR" mktag <<TAGOBJ 2>/dev/null
object $(git -C "$TAGR" rev-parse HEAD)
type commit
tag inner
tagger t <t@t> 0 +0000

AKIA7777777777777777
TAGOBJ
)"
TAGOUT="$(git -C "$TAGR" mktag <<TAGOBJ 2>/dev/null
object $TAGIN
type tag
tag AKIA6666666666666666
tagger t <t@t> 0 +0000

a clean message
TAGOBJ
)"
[[ -n "$TAGOUT" ]] && git -C "$TAGR" update-ref refs/tags/chain "$TAGOUT" 2>/dev/null
TAGSCAN="$(bash -c 'source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
                    scan_secrets "$1" "$2"' _ "$TAGR" "$PWD/secrets.deny.json" 2>&1)"

it "a key in a tag object's own name is read as a tag, not as a path"
assert_contains "$TAGSCAN" "tag:refs/tags/chain: tag AKIA6666666666666666"

it "and a tag behind a tag has its message read"
assert_contains "$TAGSCAN" "AKIA7777777777777777"

# ── the ways out of the chain walk that are not "the chain ended" ───────────
# Every one of them used to be a break: a cat-file that failed, an awk that
# failed, a chain longer than the bound. The walk stopped quietly, the rest of
# the chain went unread, and the scan reported clean -- the fail-open this
# round has been about, reintroduced by the code written to close it.
DEEPH="$(mktemp -d)"; DEEPR="$DEEPH/repo"; _sec_repo "$DEEPR" "" ""
DEEPOBJ="$(git -C "$DEEPR" rev-parse HEAD)"; DEEPTYPE=commit
for i in $(seq 1 34); do
    DEEPOBJ="$(git -C "$DEEPR" mktag <<TAGOBJ 2>/dev/null
object $DEEPOBJ
type $DEEPTYPE
tag link$i
tagger t <t@t> 0 +0000

link $i
TAGOBJ
)"
    [[ -n "$DEEPOBJ" ]] || break
    DEEPTYPE=tag
done
git -C "$DEEPR" update-ref refs/tags/deep "$DEEPOBJ" 2>/dev/null

it "a tag chain deeper than the bound is refused, not silently truncated"
bash -c 'source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
         scan_secrets "$1" "$2"' _ "$DEEPR" "$PWD/secrets.deny.json" >/dev/null 2>&1 \
    && fail "walked off the end of a chain it could not finish and called it clean" || ok

it "and says the chain is what it could not follow"
assert_contains "$(bash -c 'source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
                            scan_secrets "$1" "$2"' _ "$DEEPR" "$PWD/secrets.deny.json" 2>&1)" "tag chain"

# A git that cannot say what an object is, in the middle of a healthy chain.
mkdir -p "$DEEPH/stub"
{ printf '#!/bin/bash\n'
  printf 'prev=""; for a in "$@"; do [[ "$prev" == cat-file && "$a" == -t ]] && exit 128; prev="$a"; done\n'
  printf 'exec %s "$@"\n' "$(command -v git)"
} >"$DEEPH/stub/git"; chmod +x "$DEEPH/stub/git"

it "a git that cannot identify a tag's target refuses instead of stopping"
PATH="$DEEPH/stub:$PATH" bash -c '
    source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
    scan_secrets "$1" "$2"' _ "$TAGR" "$PWD/secrets.deny.json" >/dev/null 2>&1 \
    && fail "a cat-file it could not run read as the end of the chain" || ok

# ── a replacement rewrites what git shows, not what the bundle packs ────────
# Point refs/replace/<oid> at a clean commit and rev-list, log, grep and
# cat-file all hand you the clean one. `git bundle` is a pack transfer and
# hands over the original. The half that checks and the half that packs were
# reading two different repositories: the key scanned clean and came back out
# of a clone of the bundle in plain text.
REPH="$(mktemp -d)"; REPR="$REPH/repo"; _sec_repo "$REPR" "" ""
printf 'AKIA1234567890ABCDEF\n' >"$REPR/leak.txt"
git -C "$REPR" add leak.txt 2>/dev/null
git -C "$REPR" -c user.email=t@t -c user.name=t commit -q -m 'the original' 2>/dev/null
REPORIG="$(git -C "$REPR" rev-parse HEAD)"
printf 'nothing to see\n' >"$REPR/leak.txt"
git -C "$REPR" add leak.txt 2>/dev/null
git -C "$REPR" -c user.email=t@t -c user.name=t commit -q --amend -m 'the clean one' 2>/dev/null
git -C "$REPR" replace "$REPORIG" "$(git -C "$REPR" rev-parse HEAD)" 2>/dev/null
git -C "$REPR" update-ref refs/heads/master "$REPORIG" 2>/dev/null

it "the bundle really would carry the original, replacement or not"
git -C "$REPR" bundle create "$REPH/b.bundle" --all HEAD >/dev/null 2>&1
git clone -q "$REPH/b.bundle" "$REPH/clone" 2>/dev/null
assert_contains "$(git -C "$REPH/clone" cat-file -p "$REPORIG:leak.txt" 2>&1)" "AKIA1234567890ABCDEF"

it "and the scan reads the original rather than what replace shows it"
assert_contains "$(bash -c 'source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
                            scan_secrets "$1" "$2"' _ "$REPR" "$PWD/secrets.deny.json" 2>&1)" "AKIA1234567890ABCDEF"

# ── two names, one blob ─────────────────────────────────────────────────────
# rev-list --objects prints each OID once, with the first path it was found at.
# Two files with identical content share a blob, so one of the two names never
# appears -- and a key used as a filename was hidden by any harmless file that
# happened to hold the same bytes.
ALIH="$(mktemp -d)"; ALIR="$ALIH/repo"; _sec_repo "$ALIR" "" ""
# The harmless name has to sort FIRST: rev-list keeps the path it reaches
# first, so with the key sorting earlier the old code passed this by luck.
printf 'identical bytes\n' >"$ALIR/aaa-harmless.txt"
printf 'identical bytes\n' >"$ALIR/zzz-AKIA1234567890ABCDEF.txt"
git -C "$ALIR" add . 2>/dev/null
git -C "$ALIR" -c user.email=t@t -c user.name=t commit -q -m 'two names' 2>/dev/null
ALIOUT="$(bash -c 'source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
                   scan_secrets "$1" "$2"' _ "$ALIR" "$PWD/secrets.deny.json" 2>&1)"

it "a key used as a filename is found even when another file shares its blob"
assert_contains "$ALIOUT" "zzz-AKIA1234567890ABCDEF.txt"

it "and the name is reported once, not once per source"
assert_eq "$(printf '%s\n' "$ALIOUT" | grep -c 'zzz-AKIA1234567890ABCDEF.txt')" "1"

# ── the commit object, not a list of fields worth reading ───────────────────
# Reading through --format meant naming in advance each field that ships: %B,
# then the author and committer when those turned out to ship too. A commit
# header holds more than the placeholders expose.
RAWH="$(mktemp -d)"; RAWR="$RAWH/repo"; _sec_repo "$RAWR" "" ""
GIT_AUTHOR_NAME='AKIA5555555555555555' GIT_AUTHOR_EMAIL=a@b \
GIT_COMMITTER_NAME=c GIT_COMMITTER_EMAIL=c@d \
    git -C "$RAWR" commit -q --allow-empty -m 'a clean message' 2>/dev/null
RAWOUT="$(bash -c 'source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
                   scan_secrets "$1" "$2"' _ "$RAWR" "$PWD/secrets.deny.json" 2>&1)"

it "the author line of the raw commit object is scanned"
assert_contains "$RAWOUT" "author AKIA5555555555555555"

# ── the files assembly adds after the gate has run ──────────────────────────
# push gates the repository, then build_bundle copies in the tool, the manifest
# and the restore notes. Those ride to the same destinations and the gate never
# saw them -- and the manifest is the user's own file.
STGH="$(mktemp -d)"; mkdir -p "$STGH/stage/tool"
printf '{"paths":["~/AKIA6666666666666666"]}\n' >"$STGH/stage/tool/groups.default.json"
printf 'nothing here\n' >"$STGH/stage/RESTORE.md"

# Asserted on the file, not the key: the report names where a hit is and never
# prints the line, because sync runs from a timer whose output is the journal.
it "a key in a file assembly added is found by the directory scan"
assert_contains "$(bash -c 'source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
                            scan_files "$1" "$2"' _ "$STGH/stage" "$PWD/secrets.deny.json" 2>&1)" \
    "tool/groups.default.json"

it "and a clean staging directory reports nothing"
rm -f "$STGH/stage/tool/groups.default.json"
assert_eq "$(bash -c 'source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
                      scan_files "$1" "$2"' _ "$STGH/stage" "$PWD/secrets.deny.json" 2>&1)" ""

# ── a path is free to contain a colon ───────────────────────────────────────
# `grep -r -H -n` prints "<path>:<lineno>:<content>", so stripping two
# colon-delimited fields off "a:b.txt:1:KEY" leaves "b.txt:1:KEY" and an
# anchored pattern misses the key. git grep's decoration defect, reached from
# the other direction.
COLH="$(mktemp -d)"; mkdir -p "$COLH/stage"
printf 'AKIA1234567890ABCDEF\n' >"$COLH/stage/a:b.txt"
cat >"$COLH/anchored.json" <<'JSON'
{"schemaVersion":1,
 "patterns":[{"id":"anchored","regex":"^AKIA[0-9A-Z]{16}$","reason":"a key alone on its line"}],
 "exceptions":[]}
JSON

it "an anchored pattern still matches in a file whose name holds a colon"
assert_contains "$(bash -c 'source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
                            scan_files "$1" "$2"' _ "$COLH/stage" "$COLH/anchored.json" 2>&1)" \
    "a:b.txt"

# ── the two object listings, each with its own status ───────────────────────
# Both inside one substitution reported only the last one's, so a rev-list that
# failed left the paths half-collected and the scan returned clean.
RLH="$(mktemp -d)"; RLR="$RLH/repo"; _sec_repo "$RLR" "" ""
printf 'AKIA1234567890ABCDEF\n' >"$RLR/leak.txt"
git -C "$RLR" add leak.txt 2>/dev/null
git -C "$RLR" -c user.email=t@t -c user.name=t commit -q -m 'a leak' 2>/dev/null
mkdir -p "$RLH/stub"
{ printf '#!/bin/bash\n'
  printf 'prev=""; for a in "$@"; do [[ "$prev" == rev-list && "$a" == --objects ]] && exit 128; prev="$a"; done\n'
  printf 'exec %s "$@"\n' "$(command -v git)"
} >"$RLH/stub/git"; chmod +x "$RLH/stub/git"

it "a rev-list --objects that fails refuses instead of reporting clean"
PATH="$RLH/stub:$PATH" bash -c '
    source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
    scan_secrets "$1" "$2"' _ "$RLR" "$PWD/secrets.deny.json" >/dev/null 2>&1 \
    && fail "a half-collected object listing read as a clean repository" || ok

# ── a header no --format placeholder exposes ────────────────────────────────
# mergetag carries an entire tag object inside a merge commit and survives the
# tag being deleted, so nothing else in this scan would ever see it. Built with
# hash-object because git will not produce one on demand.
MTH="$(mktemp -d)"; MTR="$MTH/repo"; _sec_repo "$MTR" "" ""
MTTREE="$(git -C "$MTR" rev-parse HEAD^{tree})"; MTPARENT="$(git -C "$MTR" rev-parse HEAD)"
MTTAG="$(git -C "$MTR" mktag <<TAGOBJ 2>/dev/null
object $MTPARENT
type commit
tag deleted-later
tagger t <t@t> 0 +0000

AKIA8888888888888888
TAGOBJ
)"
MTC="$(git -C "$MTR" cat-file tag "$MTTAG" 2>/dev/null | sed 's/^/ /' | {
    printf 'tree %s\nparent %s\nauthor t <t@t> 0 +0000\ncommitter t <t@t> 0 +0000\nmergetag' \
        "$MTTREE" "$MTPARENT"
    cat
    printf '\na merge with nothing in its message\n'
  } | git -C "$MTR" hash-object -t commit -w --stdin 2>/dev/null)"
[[ -n "$MTC" ]] && git -C "$MTR" update-ref refs/heads/master "$MTC" 2>/dev/null

it "the tag has no ref of its own -- only the header carries it"
assert_eq "$(git -C "$MTR" for-each-ref refs/tags | wc -l)" "0"

it "a key living only in a mergetag header is found"
assert_contains "$(bash -c 'source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
                            scan_secrets "$1" "$2"' _ "$MTR" "$PWD/secrets.deny.json" 2>&1)" \
    "AKIA8888888888888888"

# ── find's status did not survive the fix that removed the manual walk ──────
# The colon-in-filename fix walked file by file, discarding find's status
# through a process substitution -- the same fail-open this file exists to
# refuse, reintroduced. Rewritten on grep -r -Z, which does its own walk and
# whose own status already covers this; the regression was in the version that
# walked manually, not in the current one, but the spec pins the property.
SFFH="$(mktemp -d)"; mkdir -p "$SFFH/stage/open" "$SFFH/stage/locked"
printf 'AKIA1234567890ABCDEF\n' >"$SFFH/stage/open/a.txt"
printf 'x\n' >"$SFFH/stage/locked/b.txt"
chmod 000 "$SFFH/stage/locked"
cat >"$SFFH/anchored.json" <<'JSON'
{"schemaVersion":1,
 "patterns":[{"id":"anchored","regex":"^AKIA[0-9A-Z]{16}$","reason":"a key alone on its line"}],
 "exceptions":[]}
JSON

it "a subdirectory the scan cannot enter is a refusal, not a clean report"
bash -c 'source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
         scan_files "$1" "$2"' _ "$SFFH/stage" "$SFFH/anchored.json" >/dev/null 2>&1 \
    && fail "an unreadable subdirectory read as nothing to find" || ok
chmod 755 "$SFFH/stage/locked"

# Asserted on the rule and the file: the report never prints the key itself.
it "and a readable staging directory still finds a key when everything is fine"
assert_contains "$(bash -c 'source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
                            scan_files "$1" "$2"' _ "$SFFH/stage" "$SFFH/anchored.json" 2>&1)" \
    "anchored"$'\t'"open/a.txt:1"

# ── the path/content boundary needs no substitute byte at all ───────────────
# The first version of the colon-safe rewrite piped grep's -Z output through
# `tr '\0' '\001'` to make it hold in a bash variable, trading the colon
# ambiguity for a rarer one: 0x01 is legal in a filename, and a record ending
# in a literal newline (also legal in a filename) split into two lines, the
# first of which was discarded and the second reported the finding under a
# truncated path. Two sequential reads against the raw stream -- one stopping
# at the real NUL, one at the real newline -- need no substitute and have no
# such byte to collide with.
NLH="$(mktemp -d)"; mkdir -p "$NLH/stage"
NLNAME="$(printf 'a\nb.txt')"
printf 'AKIA1234567890ABCDEF\n' >"$NLH/stage/$NLNAME"
cat >"$NLH/anchored.json" <<'JSON'
{"schemaVersion":1,
 "patterns":[{"id":"anchored","regex":"^AKIA[0-9A-Z]{16}$","reason":"a key alone on its line"}],
 "exceptions":[]}
JSON
NLOUT="$(bash -c 'source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
                  scan_files "$1" "$2"' _ "$NLH/stage" "$NLH/anchored.json" 2>&1)"

it "a filename holding a literal newline is still matched"
assert_contains "$NLOUT" "anchored"

# Control bytes in a name are shown as "?": a name is free to hold ESC or CR,
# and printing them raw lets a filename drive the terminal or the journal
# (review omabackup-75). The newline is one of them.
it "and the full name is in the report, not truncated at the embedded newline"
assert_contains "$NLOUT" "a?b.txt"

# ── the zero-width-pattern check cannot pass by failing to run at all ───────
# Its own jq query fed `< <(jq ...)` straight into the while loop with no
# status a caller could check -- a query that failed produced the same
# empty read the check gets when a deny-list genuinely has no patterns at
# all, and a pattern that matches every line while reporting none (this
# file's own worked example is "^") passed validation silently. This
# file's own header promises "everything here fails closed"; this was the
# one gap in that promise. A PoC (jq stubbed to fail only on the query
# that feeds this specific check) confirmed push refused for the wrong
# reason before the fix -- die was never reached at all, since nothing
# downstream of the silent empty loop ever noticed.
ZQH="$(mktemp -d)"
cat >"$ZQH/zerowidth.json" <<'JSON'
{"schemaVersion":1,
 "patterns":[{"id":"broken","regex":"^","reason":"matches every line, reports none"}],
 "exceptions":[]}
JSON
mkdir -p "$ZQH/stub"
# A heredoc with a quoted delimiter, not printf -- printf's own backslash
# processing turned a literal `\t` (the two bytes jq's argv actually
# carries; the shell's single quotes around the jq PROGRAM leave escapes
# to jq's own parser, never bash's) into a real tab byte, which never
# matched jq's actual argument and made the stub a silent no-op.
#
# Matched by exact equality, not `*...*` -- scan_secrets' own pattern
# query (three fields: id, regex, ignoreCase) has this two-field query
# as a literal PREFIX, and a substring match caught both.
#
# assert_deny_understood is called directly here, not through a full
# `push` -- with THIS exact pattern ("^"), the real scan a few steps
# later happens to block anyway (it matches everywhere the scan looks,
# including git's own internal object listing, coincidentally not
# through the zero-width gap this spec exists to isolate), which made an
# end-to-end push refuse regardless of whether this specific check ran
# at all and masked the very gap being tested.
cat >"$ZQH/stub/jq" <<'STUB'
#!/bin/bash
for a in "$@"; do
    if [[ "$a" == '(.patterns // [])[] | "\(.id)\t\(.regex)"' ]]; then
        exit 2
    fi
done
exec /usr/bin/jq "$@"
STUB
chmod +x "$ZQH/stub/jq"

it "assert_deny_understood refuses when the zero-width-pattern check's own query fails"
PATH="$ZQH/stub:$PATH" bash -c '
    ob="$1"; denyfile="$2"
    set --
    source "$ob" >/dev/null 2>&1
    source lib/secrets.sh
    assert_deny_understood "$denyfile"
' _ "$OB" "$ZQH/zerowidth.json" >/dev/null 2>&1 \
    && fail "assert_deny_understood succeeded despite its own query failing" || ok

it "and a genuinely broken zero-width pattern is still caught when the query works"
ZQOUT="$(bash -c '
    ob="$1"; denyfile="$2"
    set --
    source "$ob" >/dev/null 2>&1
    source lib/secrets.sh
    assert_deny_understood "$denyfile"
' _ "$OB" "$ZQH/zerowidth.json" 2>&1)"
assert_contains "$ZQOUT" "match the empty string"

# -- the scanners judge bytes, whatever the session's locale ---------------------
# Under a UTF-8 locale a byte that is not valid UTF-8 right before a token takes
# away the word boundary for GNU grep reading a file and for bash's own =~, so
# both scan_files and the push scan called a token clean. The systemd user
# manager on this machine runs with LANG=en_US.UTF-8, so the timer was exposed.
# Found in review round omabackup-73, measured here: LC_ALL=C finds it,
# C.UTF-8 does not.
_utok="gh""p_$(printf 'D%.0s' {1..36})"
UL="$SH/utf8"; mkdir -p "$UL/stage"
printf '\xff%s\n' "$_utok" >"$UL/stage/bin.dat"

it "scan_files finds a token after an invalid UTF-8 byte under a UTF-8 locale"
[[ -n "$(LC_ALL=C.UTF-8 bash -c 'source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
         scan_files "$1" "$2"' _ "$UL/stage" "$PWD/secrets.deny.json" 2>/dev/null)" ]] \
    && ok || fail "a UTF-8 locale hid the token from the directory scan"

UR="$SH/utf8-repo"; git init -q "$UR"
printf '\xff%s\n' "$_utok" >"$UR/bin.dat"
git -C "$UR" add bin.dat && git -C "$UR" -c user.email=t@t -c user.name=t commit -qm x

it "the push scan finds a token after an invalid UTF-8 byte under a UTF-8 locale"
[[ -n "$(LC_ALL=C.UTF-8 bash -c 'source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
         scan_secrets "$1" "$2"' _ "$UR" "$PWD/secrets.deny.json" 2>/dev/null)" ]] \
    && ok || fail "a UTF-8 locale hid the token from the push scan"

UP="$SH/plain-line"; mkdir -p "$UP/stage"
printf 'token = %s\n' "$_utok" >"$UP/stage/creds.txt"
UP_OUT="$(bash -c 'source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
          scan_files "$1" "$2"' _ "$UP/stage" "$PWD/secrets.deny.json" 2>&1)"
it "the directory scan names the file and line of a hit"
assert_contains "$UP_OUT" "creds.txt:1"

it "but never prints the line it matched"
assert_not_contains "$UP_OUT" "$_utok"

# repo.bundle is skipped only where the caller says so: the artefact's own
# packfile was scanned as objects before. Anywhere else it is a file like any.
UB="$SH/bundle-name"; mkdir -p "$UB/stage/app"
printf '%s\n' "$_utok" >"$UB/stage/app/repo.bundle"
it "a file named repo.bundle is scanned unless the caller excludes it"
[[ -n "$(bash -c 'source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
         scan_files "$1" "$2"' _ "$UB/stage" "$PWD/secrets.deny.json" 2>/dev/null)" ]] \
    && ok || fail "a user file named repo.bundle was skipped"

# -- review round omabackup-75: the staging scan's names pass ---------------------
_v5tok="gh""p_$(printf 'G%.0s' {1..36})"
_scanf() {  # _scanf <dir> [PATH prefix] -- scan_files with the shipped deny-list
    PATH="${2:+$2:}$PATH" bash -c 'source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
        scan_files "$1" "$2"' _ "$1" "$PWD/secrets.deny.json" 2>&1
}

# The names pass called grep once per file per pattern -- 12 s on a real
# 667-file staging, against 0.03 s before it. It must cost a pass per pattern,
# whatever the number of files. Counted, not timed.
V5P="$SH/v5-perf"; mkdir -p "$V5P/stage" "$V5P/stub"
for i in $(seq 1 300); do : >"$V5P/stage/f$i.conf"; done
cat >"$V5P/stub/grep" <<SHIM
#!/bin/bash
echo x >>"$V5P/calls"
exec /usr/bin/grep "\$@"
SHIM
chmod +x "$V5P/stub/grep"
_scanf "$V5P/stage" "$V5P/stub" >/dev/null
it "the names pass costs a grep per pattern, not per file"
(( $(wc -l <"$V5P/calls" 2>/dev/null || echo 99999) < 100 )) && ok \
    || fail "$(wc -l <"$V5P/calls") grep calls for 300 clean files"

# A grep that fails to open a file prints that file's path -- and the name can
# be the token the scan just decided to hide.
V5E="$SH/v5-err"; mkdir -p "$V5E/stage" "$V5E/stub"
printf 'x\n' >"$V5E/stage/$_v5tok.conf"
cat >"$V5E/stub/grep" <<'SHIM'
#!/bin/bash
for a in "$@"; do
    if [[ "$a" == -r ]]; then
        f="$(find "${@: -1}" -type f | head -1)"
        echo "grep: $f: Input/output error" >&2; exit 2
    fi
done
exec /usr/bin/grep "$@"
SHIM
chmod +x "$V5E/stub/grep"
V5E_OUT="$(_scanf "$V5E/stage" "$V5E/stub")"
it "a grep error never prints a file name the scan hid"
assert_not_contains "$V5E_OUT" "$_v5tok"

# Control bytes from a name never reach the output raw.
V5C="$SH/v5-ctrl"; mkdir -p "$V5C/stage"
printf 'token = %s\n' "$_v5tok" >"$V5C/stage/$(printf 'x\033[2Jy.conf')"
V5C_OUT="$(_scanf "$V5C/stage")"
it "a hit in a file whose name holds control bytes prints none of them"
[[ -n "$V5C_OUT" && "$V5C_OUT" != *$'\033'* ]] && ok || fail "no hit, or an ESC from the name reached the output"

# Symlinks: git commits the link's NAME and its TARGET text as a blob, so both
# are judged; neither is printed.
V5L="$SH/v5-link"; mkdir -p "$V5L/stage"
printf 'fine\n' >"$V5L/stage/fine.conf"
ln -s fine.conf "$V5L/stage/$_v5tok"
ln -s "$_v5tok" "$V5L/stage/pointer"
V5L_OUT="$(_scanf "$V5L/stage")"
it "a symlink whose name holds a token is found"
assert_contains "$V5L_OUT" "(a file NAME, not shown)"
it "a symlink whose target holds a token is found"
assert_contains "$V5L_OUT" "symlink target"
it "and neither the name nor the target is printed"
assert_not_contains "$V5L_OUT" "$_v5tok"

# A hidden name still says where to look, when the directory is clean.
V5H="$SH/v5-hint"; mkdir -p "$V5H/stage/app"
printf 'x\n' >"$V5H/stage/app/$_v5tok.conf"
V5H_OUT="$(_scanf "$V5H/stage")"
it "a hidden file name still names the directory it is in"
assert_contains "$V5H_OUT" "in app/"

# _discard_staging is the proof that a refused staging is gone. A walk that
# could not run printed nothing and passed as "empty".
# The real function, extracted from the CLI; rm and find are PATH shims that
# fail without touching anything. The helper before review returned 0 here.
V5D="$SH/v5-discard"; mkdir -p "$V5D/staging" "$V5D/stub"; : >"$V5D/staging/left.conf"
printf '#!/bin/sh\nexit 1\n' >"$V5D/stub/find"; cp "$V5D/stub/find" "$V5D/stub/rm"
chmod +x "$V5D/stub/find" "$V5D/stub/rm"
V5D_OUT="$(STAGING="$V5D/staging" STUB="$V5D/stub" bash -c '
    die() { echo "DIE: $*"; exit 1; }; _tilde() { printf %s "$1"; }
    source <(sed -n "/^_discard_staging() {/,/^}/p" bin/omabackup)
    PATH="$STUB:$PATH"
    _discard_staging; echo "returned $?"' 2>&1)"
it "_discard_staging refuses when it cannot prove the staging is empty"
assert_contains "$V5D_OUT" "DIE: could not clear"

# -- review round omabackup-76 ----------------------------------------------------
# The grep hits of the names pass hold the full name or target that matched,
# token and all. They were written to "$names.hits", a predictable file made
# by a plain redirect: 0644 under umask 022 in a shared /tmp. Whatever holds
# them must be unreadable by others from the moment it exists.
V6P="$SH/v6-perm"; mkdir -p "$V6P/stage" "$V6P/stub" "$V6P/tmp"; chmod 1777 "$V6P/tmp"
: >"$V6P/stage/$_v5tok.conf"
cat >"$V6P/stub/grep" <<SHIM
#!/bin/bash
if [[ " \$* " == *" -z "* ]]; then
    o="\$(readlink /proc/\$\$/fd/1)"
    echo "\$(stat -c %a "\$o") \$(stat -c %a "\$(dirname "\$o")")" >>"$V6P/modes"
fi
exec /usr/bin/grep "\$@"
SHIM
chmod +x "$V6P/stub/grep"
(umask 022; TMPDIR="$V6P/tmp" _scanf "$V6P/stage" "$V6P/stub" >/dev/null)
it "the names pass keeps its grep hits where no other user can read them"
if [[ -s "$V6P/modes" ]] && ! awk '$1 !~ /00$/ && $2 !~ /00$/ {bad=1} END {exit !bad}' "$V6P/modes"; then
    ok
else
    fail "file/dir modes of the hits: $(tr '\n' ' ' <"$V6P/modes" 2>/dev/null)"
fi
it "and leaves nothing behind in TMPDIR"
[[ -z "$(ls -A "$V6P/tmp")" ]] && ok || fail "left in TMPDIR: $(ls -A "$V6P/tmp")"

# A temporary the scan cannot write is a scan that did not run. The redirect
# into the hits file failed with status 1 -- grep's "no match" -- and a name
# carrying a token came back clean. mktemp is a shim that hands out paths the
# scan cannot write to: a read-only directory for -d, and for plain files a
# path whose ".hits" sibling is a directory.
V6W="$SH/v6-write"; mkdir -p "$V6W/stage" "$V6W/stub" "$V6W/tmp"
: >"$V6W/stage/$_v5tok.conf"
cat >"$V6W/stub/mktemp" <<SHIM
#!/bin/bash
n=\$(ls "$V6W/tmp" | wc -l)
if [[ "\$1" == -d ]]; then
    d="$V6W/tmp/d\$n"; mkdir "\$d"; chmod 500 "\$d"; echo "\$d"
else
    f="$V6W/tmp/f\$n"; : >"\$f"; mkdir -p "\$f.hits"; echo "\$f"
fi
SHIM
chmod +x "$V6W/stub/mktemp"
PATH="$V6W/stub:$PATH" bash -c 'source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
    scan_files "$1" "$2"' _ "$V6W/stage" "$PWD/secrets.deny.json" >/dev/null 2>&1; V6W_RC=$?
chmod -R u+w "$V6W/tmp" 2>/dev/null
it "a names pass whose temporaries cannot be written refuses instead of calling it clean"
(( V6W_RC != 0 )) && ok || fail "scan_files returned 0 with a token in a file name"

# The prefilter read the raw name and _still_matches the name with newlines as
# spaces, so a name that only matches with the space -- a key header split by
# a newline -- never reached the check that would have caught it.
V6N="$SH/v6-newline"; mkdir -p "$V6N/stage/keys"
: >"$V6N/stage/keys/$(printf -- '-----BEGIN RSA\nPRIVATE KEY-----')"
V6N_OUT="$(_scanf "$V6N/stage")"
it "a key header split by a newline in a file name is found"
assert_contains "$V6N_OUT" "private-key-block"
V6T="$SH/v6-newline-target"; mkdir -p "$V6T/stage"
ln -s -- "$(printf -- '-----BEGIN RSA\nPRIVATE KEY-----')" "$V6T/stage/pointer"
V6T_OUT="$(_scanf "$V6T/stage")"
it "a key header split by a newline in a symlink target is found"
assert_contains "$V6T_OUT" "private-key-block"

# The directory hint was cut at the last "/", so a secret whose value crosses
# a "/" printed its first part as the directory.
# Split so the fixture itself is not a credential to a scanner reading this file.
_v6kv="pass""word=\"abcdefgh"
V6H="$SH/v6-hint"; mkdir -p "$V6H/stage/cfg/$_v6kv"
: >"$V6H/stage/cfg/$_v6kv/ijklmnopqrstu\""
V6H_OUT="$(_scanf "$V6H/stage")"
it "a directory hint stops before the secret starts"
assert_not_contains "$V6H_OUT" "abcdefgh"
it "and still names the clean directory before it"
assert_contains "$V6H_OUT" "in cfg/"

# "at the top" means the file is at the top. A match in the first directory
# left no "/" before it and printed "at the top" for a file two levels down.
V6U="$SH/v6-top"; mkdir -p "$V6U/stage/$_v5tok/sub"
: >"$V6U/stage/$_v5tok/sub/f.conf"
V6U_OUT="$(_scanf "$V6U/stage")"
it "a hidden name below a matching first directory is not said to be at the top"
[[ -n "$V6U_OUT" && "$V6U_OUT" != *"at the top"* && "$V6U_OUT" != *"$_v5tok"* ]] && ok \
    || fail "no hit, or a wrong hint: $V6U_OUT"
V6R="$SH/v6-root"; mkdir -p "$V6R/stage"; : >"$V6R/stage/$_v5tok.conf"
it "and a hidden name at the top still says so"
assert_contains "$(_scanf "$V6R/stage")" "at the top"

# -- the history scan must not depend on the user's git display settings ----------
# `git grep` honours color.ui/color.grep=always even into a pipe. The escape
# sequence lands right before the token, so the second pass of the regex found
# no word boundary before `gh` and dropped the hit: push called a history
# holding a GitHub token clean. Found in review round omabackup-69.
_ctok="gh""p_$(printf 'B%.0s' {1..36})"
for _cfg in color.ui color.grep; do
    CR="$SH/color-$_cfg"
    _sec_repo "$CR" "probe.conf" "token = $_ctok"
    git -C "$CR" config "$_cfg" always
    it "the history scan still finds a token with $_cfg=always"
    [[ -n "$(scan_secrets "$CR" "$PWD/secrets.deny.json" 2>/dev/null)" ]] \
        && ok || fail "$_cfg=always hid a token from the push gate"
done
CC="$SH/column"
_sec_repo "$CC" "probe.conf" "token = $_ctok"
git -C "$CC" config grep.column true
it "the history scan still finds a token with grep.column=true"
[[ -n "$(scan_secrets "$CC" "$PWD/secrets.deny.json" 2>/dev/null)" ]] \
    && ok || fail "grep.column=true hid a token from the push gate"

# -- scan_tree: a change with no directory above it --------------------------------
# The names list (files, then the directories above them) was built with
# `(( ${#dirs[@]} )) && printf ...`, which returns 1 when there is no directory
# at all -- so a tree whose only change sits at the root read as a scan that
# could not run. sync never publishes at the root today; scan_tree must not
# depend on that.
RT="$SH/root-tree"; git init -q "$RT"
printf 'clean\n' >"$RT/top.txt"; git -C "$RT" add top.txt
RT_TREE="$(git -C "$RT" write-tree)"; RT_WORK="$(mktemp -d)"
scan_tree "$RT" "$PWD/secrets.deny.json" "$RT_TREE" "$RT_WORK" top.txt >/dev/null 2>&1; RT_RC=$?
it "scan_tree judges a root-level-only change instead of failing"
(( RT_RC == 0 )) && ok || fail "a clean root-level file made the scan report that it could not run"

printf 'token = %s\n' "$_ctok" >"$RT/top.txt"; git -C "$RT" add top.txt
RT_TREE="$(git -C "$RT" write-tree)"
it "and still finds a token in that root-level file"
[[ -n "$(scan_tree "$RT" "$PWD/secrets.deny.json" "$RT_TREE" "$RT_WORK" top.txt 2>/dev/null)" ]] \
    && ok || fail "a token in a root-level file was missed"

# -- scan_tree judges bytes, whatever the session's locale -----------------------
# Same class as the staging and push scans (review omabackup-73): under a UTF-8
# locale an invalid byte right before a token takes the word boundary away from
# GNU grep and from bash's =~, and the token read as clean.
_ztok="gh""p_$(printf 'F%.0s' {1..36})"
ZT="$SH/utf8-tree"; git init -q "$ZT"
printf '\xff%s\n' "$_ztok" >"$ZT/bin.dat"; git -C "$ZT" add bin.dat
ZT_TREE="$(git -C "$ZT" write-tree)"; ZT_WORK="$(mktemp -d)"
it "scan_tree finds a token after an invalid UTF-8 byte under a UTF-8 locale"
[[ -n "$(LC_ALL=C.UTF-8 bash -c 'source lib/common.sh 2>/dev/null || true; source lib/secrets.sh
         scan_tree "$1" "$2" "$3" "$4" bin.dat' _ "$ZT" "$PWD/secrets.deny.json" "$ZT_TREE" "$ZT_WORK" 2>/dev/null)" ]] \
    && ok || fail "a UTF-8 locale hid the token from the pre-commit scan"

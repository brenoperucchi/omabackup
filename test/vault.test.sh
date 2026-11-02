# The secrets group, mode "age" (lib/vault.sh, docs/DESIGN.md §6).
# One theme throughout: a secret reaches the repo only as age ciphertext for
# recipients this machine accepted, and every drill or restore says exactly
# what it could decrypt. Every spec drives the CLI; none calls a function.

OB="$PWD/bin/omabackup"

_v_env() {  # _v_env <home> <cmd...>
    local h="$1"; shift
    HOME="$h" OMABACKUP_GROUPS="$h/g.json" OMABACKUP_STATE="$h/.state" OMABACKUP_REPO="$h/repo" \
        XDG_RUNTIME_DIR=/nonexistent OMABACKUP_LOG_SKIP=1 "$OB" "$@" 2>&1
}

# A home with two identities, both as recipients, one secret declared and a
# repo with a base commit. The secret carries a marker no other file holds,
# so its plaintext can be searched for anywhere.
_v_home() {  # _v_home <home> <marker>
    local h="$1" m="$2"
    mkdir -p "$h/.config/omabackup/secrets" "$h/.config/app" "$h/.config/misc" "$h/ids"
    age-keygen -o "$h/ids/a.txt" 2>/dev/null
    age-keygen -o "$h/ids/b.txt" 2>/dev/null
    { printf '# A: 1Password\n'; age-keygen -y "$h/ids/a.txt"; printf '# B: rescue\n'; age-keygen -y "$h/ids/b.txt"; } \
        >"$h/.config/omabackup/secrets/recipients.txt"
    printf 'TOKEN=%s\n' "$m" >"$h/.config/app/app.env"
    chmod 600 "$h/.config/app/app.env"
    printf 'plain\n' >"$h/.config/misc/x.conf"
    cat >"$h/.config/omabackup/secrets/files.json" <<'JSON'
{"schemaVersion":1,"files":[{"live":"~/.config/app/app.env","name":"app.env"}]}
JSON
    cat >"$h/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"misc","label":"Misc","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/misc"]},
 {"id":"secrets","label":"Secrets","mode":"age","coupled":false,"critical":false}]}
JSON
    git init -q "$h/repo"
    git -C "$h/repo" config user.email t@t
    git -C "$h/repo" config user.name t
    printf 'seed\n' >"$h/repo/README.md"
    git -C "$h/repo" add -A
    git -C "$h/repo" commit -qm base
}

_v_blob() { git -C "$1/repo" rev-parse -q --verify "HEAD:secrets/age/$2" 2>/dev/null; }
_v_head() { head -c 22 -- "$1" 2>/dev/null | tr '\n' '|'; }

# -- the first sync seals the secret ----------------------------------------------
VH="$(mktemp -d)"; VM="vaultmark$RANDOM$RANDOM"
_v_home "$VH" "$VM"
VOUT="$(_v_env "$VH" secrets accept)"
it "secrets accept names each recipient it accepted"
assert_contains "$VOUT" "$(age-keygen -y "$VH/ids/b.txt")"

VOUT="$(_v_env "$VH" sync --commit)"
it "a sync with accepted recipients commits the secret as age ciphertext"
assert_eq "$(_v_head "$VH/repo/secrets/age/app.env.age")" "age-encryption.org/v1|"

it "and commits an encrypted index that says where each secret lives"
assert_eq "$(_v_head "$VH/repo/secrets/age/_index.age")" "age-encryption.org/v1|"

it "and both are in the commit, not only in the working tree"
[[ -n "$(_v_blob "$VH" app.env.age)" && -n "$(_v_blob "$VH" _index.age)" ]] && ok || fail "not committed: $VOUT"

it "identity A alone decrypts the committed secret"
assert_eq "$(age -d -i "$VH/ids/a.txt" "$VH/repo/secrets/age/app.env.age" 2>&1)" "TOKEN=$VM"

it "identity B alone decrypts it too"
assert_eq "$(age -d -i "$VH/ids/b.txt" "$VH/repo/secrets/age/app.env.age" 2>&1)" "TOKEN=$VM"

it "the index maps the name back to its live path and mode"
assert_eq "$(age -d -i "$VH/ids/a.txt" "$VH/repo/secrets/age/_index.age" 2>/dev/null \
    | jq -r '.files[] | "\(.name) \(.live) \(.mode)"')" "app.env ~/.config/app/app.env 600"

it "the plaintext is nowhere in the repo, its history, the state dir or the output"
VLEAK="$(git -C "$VH/repo" log -p --all 2>/dev/null | grep -c -F "$VM")"
VLEAK2="$(grep -r -a -l -F "$VM" "$VH/repo" "$VH/.state" 2>/dev/null)"
[[ "$VLEAK" == 0 && -z "$VLEAK2" && "$VOUT" != *"$VM"* ]] && ok \
    || fail "plaintext found: history=$VLEAK files=$VLEAK2"

# -- unchanged secrets are not re-encrypted ---------------------------------------
VB1="$(_v_blob "$VH" app.env.age)"
_v_env "$VH" sync --commit >/dev/null
it "a second sync with nothing changed keeps the same ciphertext"
assert_eq "$(_v_blob "$VH" app.env.age)" "$VB1"

printf 'TOKEN=%s-rotated\n' "$VM" >"$VH/.config/app/app.env"
_v_env "$VH" sync --commit >/dev/null
VB2="$(_v_blob "$VH" app.env.age)"
it "a changed secret is re-encrypted"
[[ -n "$VB2" && "$VB2" != "$VB1" ]] && ok || fail "ciphertext did not change ($VB1 -> $VB2)"

it "and the new ciphertext holds the new value"
assert_eq "$(age -d -i "$VH/ids/a.txt" "$VH/repo/secrets/age/app.env.age" 2>&1)" "TOKEN=$VM-rotated"

rm -f "$VH/.state/secrets.json"
_v_env "$VH" sync --commit >/dev/null
VB3="$(_v_blob "$VH" app.env.age)"
it "losing the local state re-encrypts once"
[[ -n "$VB3" && "$VB3" != "$VB2" ]] && ok || fail "ciphertext did not change after the state was lost"

_v_env "$VH" sync --commit >/dev/null
it "and the run after that is stable again"
assert_eq "$(_v_blob "$VH" app.env.age)" "$VB3"

it "the local state never holds the plaintext"
[[ -z "$(grep -r -a -l -F "$VM" "$VH/.state" 2>/dev/null)" ]] && ok || fail "plaintext in the state dir"

# -- recipients are an accepted anchor --------------------------------------------
age-keygen -o "$VH/ids/c.txt" 2>/dev/null
age-keygen -y "$VH/ids/c.txt" >>"$VH/.config/omabackup/secrets/recipients.txt"
printf 'TOKEN=%s-again\n' "$VM" >"$VH/.config/app/app.env"
VC="$(git -C "$VH/repo" rev-list --count HEAD)"
VOUT="$(_v_env "$VH" sync --commit)"; VRC=$?
it "a recipient added without secrets accept stops the sync"
[[ "$VRC" != 0 && "$VOUT" == *"secrets accept"* ]] && ok || fail "rc=$VRC: $VOUT"

it "and nothing was committed"
assert_eq "$(git -C "$VH/repo" rev-list --count HEAD)" "$VC"

it "and no ciphertext for the unaccepted recipient reached staging"
[[ ! -e "$VH/.state/staging/.secrets" ]] && ok || fail "staging kept a .secrets dir"

_v_env "$VH" secrets accept >/dev/null
_v_env "$VH" sync --commit >/dev/null
it "after accept the new recipient decrypts the next sync"
assert_eq "$(age -d -i "$VH/ids/c.txt" "$VH/repo/secrets/age/app.env.age" 2>&1)" "TOKEN=$VM-again"

VH2="$(mktemp -d)"; _v_home "$VH2" "vaultmark$RANDOM"
VOUT="$(_v_env "$VH2" sync --commit)"; VRC=$?
it "recipients never accepted at all stop the sync too"
[[ "$VRC" != 0 && "$VOUT" == *"secrets accept"* && -z "$(_v_blob "$VH2" app.env.age)" ]] && ok || fail "rc=$VRC: $VOUT"

# -- what the collector refuses to read -------------------------------------------
VH3="$(mktemp -d)"; VM3="vaultmark$RANDOM$RANDOM"; _v_home "$VH3" "$VM3"
_v_env "$VH3" secrets accept >/dev/null
mv "$VH3/.config/app/app.env" "$VH3/.config/app/real.env"
ln -s real.env "$VH3/.config/app/app.env"
VOUT="$(_v_env "$VH3" sync --commit)"; VRC=$?
it "a declared secret that is a symlink is refused and nothing is committed"
[[ "$VRC" != 0 && "$VOUT" == *symlink* && -z "$(_v_blob "$VH3" app.env.age)" ]] && ok || fail "rc=$VRC: $VOUT"

rm -f "$VH3/.config/app/app.env"
head -c 1100000 /dev/zero >"$VH3/.config/app/app.env"
VOUT="$(_v_env "$VH3" sync --commit)"; VRC=$?
it "a declared secret over 1 MiB is refused and nothing is committed"
[[ "$VRC" != 0 && "$VOUT" == *"1 MiB"* && -z "$(_v_blob "$VH3" app.env.age)" ]] && ok || fail "rc=$VRC: $VOUT"

# -- the age-header gate fails closed ---------------------------------------------
# A broken age that writes its input through unchanged: the scanner's text
# rules would never notice a binary secret, so the header check is the gate.
VH4="$(mktemp -d)"; VM4="vaultmark$RANDOM$RANDOM"; _v_home "$VH4" "$VM4"
_v_env "$VH4" secrets accept >/dev/null
mkdir -p "$VH4/fakebin"
cat >"$VH4/fakebin/age" <<'SH'
#!/bin/bash
out=""; in=""
while (($#)); do case "$1" in -o) out="$2"; shift 2 ;; -R|-i) shift 2 ;; -*) shift ;; *) in="$1"; shift ;; esac; done
cat -- "$in" >"$out"
SH
chmod +x "$VH4/fakebin/age"
VOUT="$(PATH="$VH4/fakebin:$PATH" _v_env "$VH4" sync --commit)"; VRC=$?
it "an age that writes plaintext is caught by the header gate"
[[ "$VRC" != 0 && "$VOUT" == *"not age ciphertext"* ]] && ok || fail "rc=$VRC: $VOUT"

it "and the plaintext reached neither the repo nor its history"
[[ "$(git -C "$VH4/repo" log -p --all 2>/dev/null | grep -c -F "$VM4")" == 0 \
    && -z "$(grep -r -a -l -F "$VM4" "$VH4/repo" 2>/dev/null)" ]] && ok || fail "plaintext reached the repo"

it "and the staging that held it was discarded"
[[ -z "$(grep -r -a -l -F "$VM4" "$VH4/.state" 2>/dev/null)" ]] && ok || fail "plaintext left in the state dir"

# -- no secrets config: the group is a no-op ----------------------------------------
VH5="$(mktemp -d)"; _v_home "$VH5" "vaultmark$RANDOM"
rm -f "$VH5/.config/omabackup/secrets/files.json"
VOUT="$(PATH="$VH4/fakebin:$PATH" _v_env "$VH5" sync --commit)"; VRC=$?
it "with no files.json the secrets group does nothing and the sync still commits"
[[ "$VRC" == 0 && ! -e "$VH5/repo/secrets" && -n "$(git -C "$VH5/repo" rev-parse -q --verify HEAD:configs/misc/x.conf)" ]] \
    && ok || fail "rc=$VRC: $VOUT"

# -- drill ------------------------------------------------------------------------
VOUT="$(_v_env "$VH" verify)"
it "verify warns about a recipient that was never drilled"
assert_contains "$VOUT" "never drilled"

VOUT="$(_v_env "$VH" secrets drill -i "$VH/ids/a.txt")"; VRC=$?
it "a drill with identity A decrypts every secret and passes"
[[ "$VRC" == 0 && "$VOUT" == *"app.env"* ]] && ok || fail "rc=$VRC: $VOUT"

it "the drill never prints a secret"
assert_not_contains "$VOUT" "$VM"

VA="$(age-keygen -y "$VH/ids/a.txt")"
it "the drill records the date for identity A"
[[ "$(jq -r --arg k "$VA" '.[$k] // empty' "$VH/.state/secrets-drills.json" 2>/dev/null)" =~ ^[0-9]+$ ]] && ok \
    || fail "no drill date for A: $(cat "$VH/.state/secrets-drills.json" 2>&1)"

VOUT="$(_v_env "$VH" verify)"
it "after that, verify still warns about B but not about A"
[[ "$VOUT" == *"never drilled"* && "$VOUT" != *"${VA:0:16}"*"never drilled"* ]] && ok || fail "$VOUT"

age-keygen -o "$VH/ids/stranger.txt" 2>/dev/null
VOUT="$(_v_env "$VH" secrets drill -i "$VH/ids/stranger.txt")"; VRC=$?
it "a drill with an identity that is not a recipient fails"
[[ "$VRC" != 0 ]] && ok || fail "a stranger's identity passed the drill: $VOUT"

it "and records nothing for it"
VS="$(age-keygen -y "$VH/ids/stranger.txt")"
[[ -z "$(jq -r --arg k "$VS" '.[$k] // empty' "$VH/.state/secrets-drills.json" 2>/dev/null)" ]] && ok || fail "stranger recorded"

jq --arg k "$VA" '.[$k] = 1000' "$VH/.state/secrets-drills.json" >"$VH/d.json" && mv "$VH/d.json" "$VH/.state/secrets-drills.json"
VOUT="$(_v_env "$VH" verify)"
it "verify warns when a drill is older than 90 days"
assert_contains "$VOUT" "last drilled"

# -- restore ----------------------------------------------------------------------
VR="$(mktemp -d)"; mkdir -p "$VR/repo"; cp "$VH/g.json" "$VR/g.json"
cp -r "$VH/repo/secrets" "$VR/repo/"
VOUT="$(_v_env "$VR" secrets restore -i "$VH/ids/b.txt")"; VRC=$?
it "restore without --apply plans and writes nothing"
[[ "$VRC" == 0 && "$VOUT" == *"app.env"* && ! -e "$VR/.config/app/app.env" ]] && ok || fail "rc=$VRC: $VOUT"

VOUT="$(_v_env "$VR" secrets restore -i "$VH/ids/b.txt" --apply)"; VRC=$?
it "restore --apply with identity B writes the secret back to its live path"
[[ "$VRC" == 0 && "$(cat "$VR/.config/app/app.env" 2>/dev/null)" == "TOKEN=$VM-again" ]] && ok || fail "rc=$VRC: $VOUT"

it "with the mode it had"
assert_eq "$(stat -c %a "$VR/.config/app/app.env" 2>/dev/null)" "600"

it "and never prints it"
assert_not_contains "$VOUT" "$VM"

printf 'TOKEN=local-edit\n' >"$VR/.config/app/app.env"
VOUT="$(_v_env "$VR" secrets restore -i "$VH/ids/b.txt" --apply)"; VRC=$?
it "restore refuses to overwrite a live file that differs"
[[ "$VRC" != 0 && "$(cat "$VR/.config/app/app.env")" == "TOKEN=local-edit" ]] && ok || fail "rc=$VRC: $VOUT"

VOUT="$(_v_env "$VR" secrets restore -i "$VH/ids/b.txt" --apply --force)"; VRC=$?
it "and overwrites it with --force"
[[ "$VRC" == 0 && "$(cat "$VR/.config/app/app.env")" == "TOKEN=$VM-again" ]] && ok || fail "rc=$VRC: $VOUT"

VOUT="$(_v_env "$VR" secrets restore -i "$VH/ids/stranger.txt" --apply --force)"; VRC=$?
it "restore with an identity that cannot decrypt fails and writes nothing"
[[ "$VRC" != 0 && "$(cat "$VR/.config/app/app.env")" == "TOKEN=$VM-again" ]] && ok || fail "rc=$VRC: $VOUT"

# age does not authenticate the sender: anyone with the public keys can forge
# an index. One that points outside ~/ must not be restored anywhere.
VF="$(mktemp -d)"; mkdir -p "$VF/repo/secrets/age"; cp "$VH/g.json" "$VF/g.json"
VFA="$(age-keygen -y "$VH/ids/a.txt")"
printf 'forged\n' | age -r "$VFA" -o "$VF/repo/secrets/age/evil.age"
printf '{"schemaVersion":1,"files":[{"name":"evil","live":"~/../escaped","mode":"600"}]}' \
    | age -r "$VFA" -o "$VF/repo/secrets/age/_index.age"
mkdir -p "$VF/home"
VOUT="$(HOME="$VF/home" OMABACKUP_GROUPS="$VF/g.json" OMABACKUP_STATE="$VF/home/.state" OMABACKUP_REPO="$VF/repo" \
    XDG_RUNTIME_DIR=/nonexistent OMABACKUP_LOG_SKIP=1 "$OB" secrets restore -i "$VH/ids/a.txt" --apply --force 2>&1)"; VRC=$?
it "a forged index that points outside ~/ is refused and nothing is written there"
[[ "$VRC" != 0 && ! -e "$VF/escaped" && "$VOUT" == *unsafe* ]] && ok || fail "rc=$VRC: $VOUT"

printf '{"schemaVersion":1,"files":[{"live":"/etc/passwd","name":"p"}]}\n' >"$VH/.config/omabackup/secrets/files.json"
VOUT="$(_v_env "$VH" sync --commit)"; VRC=$?
it "files.json may only name paths under ~/"
[[ "$VRC" != 0 && "$VOUT" == *"files.json"* ]] && ok || fail "rc=$VRC: $VOUT"

# -- review omabackup-87 -----------------------------------------------------------
# A secret larger than a pipe buffer: the commit gate used to read the blob
# through a pipe that head closed early, and pipefail turned git's SIGPIPE
# into "not age ciphertext" on every sync from then on.
VH6="$(mktemp -d)"; _v_home "$VH6" "vaultmark$RANDOM"
head -c 675000 /dev/urandom | base64 -w0 >"$VH6/.config/app/app.env"
_v_env "$VH6" secrets accept >/dev/null
VOUT="$(_v_env "$VH6" sync --commit)"; VRC=$?
it "a secret of 900 KB commits and is not mistaken for plaintext"
[[ "$VRC" == 0 && -n "$(_v_blob "$VH6" app.env.age)" ]] && ok || fail "rc=$VRC: $(printf '%s' "$VOUT" | tail -3)"

it "and decrypts to exactly what was declared"
assert_eq "$(age -d -i "$VH6/ids/a.txt" "$VH6/repo/secrets/age/app.env.age" 2>/dev/null | sha256sum)" \
    "$(sha256sum <"$VH6/.config/app/app.env")"

# What accept recorded must be byte for byte what age encrypts for: an inline
# comment that age itself would reject must not break the sync after accept.
VH7="$(mktemp -d)"; _v_home "$VH7" "vaultmark$RANDOM"
printf '%s # A, inline comment\n  %s\n' "$(age-keygen -y "$VH7/ids/a.txt")" "$(age-keygen -y "$VH7/ids/b.txt")" \
    >"$VH7/.config/omabackup/secrets/recipients.txt"
_v_env "$VH7" secrets accept >/dev/null
VOUT="$(_v_env "$VH7" sync --commit)"; VRC=$?
it "recipients with inline comments and indentation encrypt as accepted"
[[ "$VRC" == 0 && "$(age -d -i "$VH7/ids/b.txt" "$VH7/repo/secrets/age/app.env.age" 2>/dev/null)" == TOKEN=* ]] \
    && ok || fail "rc=$VRC: $(printf '%s' "$VOUT" | tail -3)"

# A path the drill and the restore would refuse must be refused at sync time.
printf '{"schemaVersion":1,"files":[{"live":"~/.config//app/app.env","name":"app.env"}]}\n' \
    >"$VH7/.config/omabackup/secrets/files.json"
VOUT="$(_v_env "$VH7" sync --commit)"; VRC=$?
it "files.json refuses a path with an empty component"
[[ "$VRC" != 0 && "$VOUT" == *"files.json"* ]] && ok || fail "rc=$VRC: $VOUT"

# A forged index can name a mode; the restore keeps a secret private anyway.
VF2="$(mktemp -d)"; mkdir -p "$VF2/repo/secrets/age" "$VF2/home"; cp "$VH/g.json" "$VF2/g.json"
printf 'forged\n' | age -r "$VFA" -o "$VF2/repo/secrets/age/f.age"
printf '{"schemaVersion":1,"files":[{"name":"f","live":"~/f.txt","mode":"666"}]}' \
    | age -r "$VFA" -o "$VF2/repo/secrets/age/_index.age"
HOME="$VF2/home" OMABACKUP_GROUPS="$VF2/g.json" OMABACKUP_STATE="$VF2/home/.state" OMABACKUP_REPO="$VF2/repo" \
    XDG_RUNTIME_DIR=/nonexistent OMABACKUP_LOG_SKIP=1 "$OB" secrets restore -i "$VH/ids/a.txt" --apply >/dev/null 2>&1
it "a mode from the index never opens a restored secret to group or others"
assert_eq "$(stat -c %a "$VF2/home/f.txt" 2>/dev/null)" "600"

# A restore from an artifact must say the secrets are there and how to get
# them back: a disaster restore is exactly when this is needed.
_v_env "$VH" sync --commit >/dev/null 2>&1   # files.json above was replaced; restore it first
printf '{"schemaVersion":1,"files":[{"live":"~/.config/app/app.env","name":"app.env"}]}\n' \
    >"$VH/.config/omabackup/secrets/files.json"
_v_env "$VH" sync --commit >/dev/null 2>&1
HOME="$VH" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$VH/g.json" OMABACKUP_STATE="$VH/.state" \
    OMABACKUP_REPO="$VH/repo" XDG_RUNTIME_DIR=/nonexistent OMABACKUP_LOG_SKIP=1 "$OB" bundle >/dev/null 2>&1
VART="$(ls -t "$VH/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
VT="$(mktemp -d)"
VOUT="$(HOME="$VT" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$VT/.state" XDG_RUNTIME_DIR=/nonexistent \
    OMABACKUP_LOG_SKIP=1 "$OB" restore "$VART" 2>&1)"
it "a restore plan from an artifact names the encrypted secrets and the command for them"
[[ -n "$VART" && "$VOUT" == *"secrets/age/"* && "$VOUT" == *"secrets restore"* ]] && ok || fail "artifact=$VART: $VOUT"

# Plaintext left by a run that was killed outright: the fallback directory is
# persistent, so the next run clears what a dead process left there.
mkdir -p "$VH/.state/omabackup-secrets.999999.abc"
printf 'TOKEN=left-behind\n' >"$VH/.state/omabackup-secrets.999999.abc/plain"
_v_env "$VH" sync --commit >/dev/null 2>&1
it "a plaintext directory left by a dead run is removed by the next one"
[[ ! -e "$VH/.state/omabackup-secrets.999999.abc" ]] && ok || fail "still there"

# -- review omabackup-87, rev-1 ----------------------------------------------------
# A declared secret inside a tree another group copies must not also be
# copied in the clear: the deny-list cannot see a binary key or a bare value.
VO="$(mktemp -d)"; VOM="vaultmark$RANDOM$RANDOM"; _v_home "$VO" "x"
printf 'RAW%s\n' "$VOM" >"$VO/.config/misc/inside.key"
printf 'RAW%s\n' "$VOM" >"$VO/.config/single.key"
cat >"$VO/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"misc","label":"Misc","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/misc","~/.config/single.key"]},
 {"id":"secrets","label":"Secrets","mode":"age","coupled":false,"critical":false}]}
JSON
printf '{"schemaVersion":1,"files":[{"live":"~/.config/misc/inside.key","name":"inside.key"},{"live":"~/.config/single.key","name":"single.key"}]}\n' \
    >"$VO/.config/omabackup/secrets/files.json"
_v_env "$VO" secrets accept >/dev/null
VOUT="$(_v_env "$VO" sync --commit)"; VRC=$?
it "a secret inside another group's tree, or declared by it too, is never copied in the clear"
[[ "$(git -C "$VO/repo" log -p --all 2>/dev/null | grep -c -F "$VOM")" == 0 \
    && -z "$(grep -r -a -l -F "$VOM" "$VO/repo" "$VO/.state" 2>/dev/null)" ]] && ok || fail "plaintext reached the repo or staging: $VOUT"

it "and the overlap is refused, naming the secret and the group"
[[ "$VRC" != 0 && "$VOUT" == *"inside.key is declared a secret, and group misc"* \
    && "$VOUT" == *"single.key is declared a secret, and group misc"* ]] && ok || fail "rc=$VRC: $VOUT"

# An age that writes its input and then fails, or a bare `collect`: a file
# that is not ciphertext never reaches staging, whichever command ran.
VC2="$(mktemp -d)"; VCM="vaultmark$RANDOM$RANDOM"; _v_home "$VC2" "$VCM"
_v_env "$VC2" secrets accept >/dev/null
mkdir -p "$VC2/fakebin"
cat >"$VC2/fakebin/age" <<'SH'
#!/bin/bash
out=""; in=""
while (($#)); do case "$1" in -o) out="$2"; shift 2 ;; -R|-i) shift 2 ;; -*) shift ;; *) in="$1"; shift ;; esac; done
cat -- "$in" >"$out"; exit 1
SH
chmod +x "$VC2/fakebin/age"
PATH="$VC2/fakebin:$PATH" _v_env "$VC2" sync --commit >/dev/null
it "an age that writes plaintext and then fails leaves nothing in staging"
[[ -z "$(grep -r -a -l -F "$VCM" "$VC2/.state" "$VC2/repo" 2>/dev/null)" ]] && ok || fail "plaintext left behind"
cp "$VH4/fakebin/age" "$VC2/fakebin/age"
VOUT="$(PATH="$VC2/fakebin:$PATH" _v_env "$VC2" collect)"; VRC=$?
it "a bare collect with an age that writes plaintext refuses and stages nothing"
[[ "$VRC" != 0 && -z "$(grep -r -a -l -F "$VCM" "$VC2/.state" 2>/dev/null)" ]] && ok || fail "rc=$VRC: $VOUT"

# Recipients the age parser would reject are refused at accept, not later.
VC3="$(mktemp -d)"; _v_home "$VC3" "x"
printf 'age1%s\n' "$(printf 'q%.0s' {1..58})" >"$VC3/.config/omabackup/secrets/recipients.txt"
VOUT="$(_v_env "$VC3" secrets accept)"; VRC=$?
it "accept refuses a key whose checksum is wrong"
[[ "$VRC" != 0 && ! -e "$VC3/.state/secrets-recipients.accepted" ]] && ok || fail "rc=$VRC: $VOUT"
VK="$(age-keygen -y "$VC3/ids/a.txt")"
printf '%s %s\n' "${VK:0:30}" "${VK:30}" >"$VC3/.config/omabackup/secrets/recipients.txt"
VOUT="$(_v_env "$VC3" secrets accept)"; VRC=$?
it "accept refuses a key with a space inside it"
[[ "$VRC" != 0 && ! -e "$VC3/.state/secrets-recipients.accepted" ]] && ok || fail "rc=$VRC: $VOUT"

# A drill proves one identity at a time.
cat "$VH/ids/a.txt" "$VH/ids/b.txt" >"$VH/ids/ab.txt"
VOUT="$(_v_env "$VH" secrets drill -i "$VH/ids/ab.txt")"; VRC=$?
it "a drill refuses an identity file holding more than one key"
[[ "$VRC" != 0 && "$VOUT" == *"one identity"* ]] && ok || fail "rc=$VRC: $VOUT"

# Restore never writes through a symlinked parent, nor through a temporary
# name planted in advance.
VS1="$(mktemp -d)"; mkdir -p "$VS1/repo/secrets/age" "$VS1/home" "$VS1/outside"; cp "$VH/g.json" "$VS1/g.json"
ln -s "$VS1/outside" "$VS1/home/link"
printf 'forged\n' | age -r "$VFA" -o "$VS1/repo/secrets/age/x.age"
printf '{"schemaVersion":1,"files":[{"name":"x","live":"~/link/x","mode":"600"}]}' \
    | age -r "$VFA" -o "$VS1/repo/secrets/age/_index.age"
VOUT="$(HOME="$VS1/home" OMABACKUP_GROUPS="$VS1/g.json" OMABACKUP_STATE="$VS1/home/.state" OMABACKUP_REPO="$VS1/repo" \
    XDG_RUNTIME_DIR=/nonexistent OMABACKUP_LOG_SKIP=1 "$OB" secrets restore -i "$VH/ids/a.txt" --apply --force 2>&1)"; VRC=$?
it "restore refuses a destination whose parent is a symlink out of ~/"
[[ "$VRC" != 0 && ! -e "$VS1/outside/x" ]] && ok || fail "rc=$VRC: $VOUT"

VS2="$(mktemp -d)"; mkdir -p "$VS2/repo/secrets/age" "$VS2/home"; cp "$VH/g.json" "$VS2/g.json"
printf 'victim\n' >"$VS2/victim"; chmod 644 "$VS2/victim"
ln -s "$VS2/victim" "$VS2/home/t.txt.omabackup-tmp"
printf 'forged\n' | age -r "$VFA" -o "$VS2/repo/secrets/age/t.age"
printf '{"schemaVersion":1,"files":[{"name":"t","live":"~/t.txt","mode":"600"}]}' \
    | age -r "$VFA" -o "$VS2/repo/secrets/age/_index.age"
HOME="$VS2/home" OMABACKUP_GROUPS="$VS2/g.json" OMABACKUP_STATE="$VS2/home/.state" OMABACKUP_REPO="$VS2/repo" \
    XDG_RUNTIME_DIR=/nonexistent OMABACKUP_LOG_SKIP=1 "$OB" secrets restore -i "$VH/ids/a.txt" --apply >/dev/null 2>&1
it "restore never writes through a planted temporary symlink"
[[ "$(cat "$VS2/victim")" == victim && "$(stat -c %a "$VS2/victim")" == 644 \
    && -f "$VS2/home/t.txt" && ! -L "$VS2/home/t.txt" ]] && ok || fail "victim=$(cat "$VS2/victim") t=$(ls -l "$VS2/home/t.txt" 2>&1)"

# The local state holds plaintext hashes: its writer must not follow a link.
printf 'victim\n' >"$VH/victim2"
ln -s "$VH/victim2" "$VH/.state/secrets.json.tmp"
printf 'TOKEN=%s-statecheck\n' "$VM" >"$VH/.config/app/app.env"
_v_env "$VH" sync --commit >/dev/null 2>&1
it "the state writer never writes through a planted temporary symlink"
[[ "$(cat "$VH/victim2")" == victim && -f "$VH/.state/secrets.json" && ! -L "$VH/.state/secrets.json" ]] \
    && ok || fail "victim=$(cat "$VH/victim2")"

# -- review omabackup-88 -----------------------------------------------------------
# The same file reached through a symlinked spelling: compared by real path.
VP="$(mktemp -d)"; VPM="vaultmark$RANDOM$RANDOM"; _v_home "$VP" "$VPM"
ln -s .config "$VP/.cfg"
cat >"$VP/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"misc","label":"Misc","mode":"copy","coupled":false,"critical":false,"paths":["~/.cfg/app"]},
 {"id":"secrets","label":"Secrets","mode":"age","coupled":false,"critical":false}]}
JSON
_v_env "$VP" secrets accept >/dev/null
VOUT="$(_v_env "$VP" sync --commit)"; VRC=$?
it "a group reaching a secret through a symlinked spelling is refused"
[[ "$VRC" != 0 && "$VOUT" == *"declared a secret"* ]] && ok || fail "rc=$VRC: $VOUT"
it "and the plaintext reached neither the repo nor staging"
[[ "$(git -C "$VP/repo" log -p --all 2>/dev/null | grep -c -F "$VPM")" == 0 \
    && -z "$(grep -r -a -l -F "$VPM" "$VP/repo" "$VP/.state" 2>/dev/null)" ]] && ok || fail "plaintext leaked"

# A hardlink, or any copy under another name: compared by bytes.
VQ="$(mktemp -d)"; VQM="vaultmark$RANDOM$RANDOM"; _v_home "$VQ" "$VQM"
ln "$VQ/.config/app/app.env" "$VQ/.config/misc/linked.env"
_v_env "$VQ" secrets accept >/dev/null
VOUT="$(_v_env "$VQ" sync --commit)"; VRC=$?
it "a hardlink of a secret inside another group's tree is refused by its bytes"
[[ "$VRC" != 0 && "$VOUT" == *"declared secret's bytes"* ]] && ok || fail "rc=$VRC: $VOUT"
it "and the plaintext reached neither the repo nor staging"
[[ "$(git -C "$VQ/repo" log -p --all 2>/dev/null | grep -c -F "$VQM")" == 0 \
    && -z "$(grep -r -a -l -F "$VQM" "$VQ/repo" "$VQ/.state" 2>/dev/null)" ]] && ok || fail "plaintext leaked"

# A triple group at a root other than the usual one.
VT3="$(mktemp -d)"; _v_home "$VT3" "x"
mkdir -p "$VT3/.config/x/plugins/p"; printf 'k\n' >"$VT3/.config/x/plugins/p/private.bin"
cat >"$VT3/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"plugins","label":"Plugins","mode":"triple","coupled":false,"critical":false,"paths":["~/.config/x/plugins"]},
 {"id":"secrets","label":"Secrets","mode":"age","coupled":false,"critical":false}]}
JSON
printf '{"schemaVersion":1,"files":[{"live":"~/.config/x/plugins/p/private.bin","name":"p"}]}\n' \
    >"$VT3/.config/omabackup/secrets/files.json"
_v_env "$VT3" secrets accept >/dev/null
VOUT="$(_v_env "$VT3" collect)"; VRC=$?
it "a secret under a triple group's root is refused, wherever that root is"
[[ "$VRC" != 0 && "$VOUT" == *"group plugins"* ]] && ok || fail "rc=$VRC: $VOUT"

# Names the overlap check cannot reason about are refused up front.
printf '{"schemaVersion":1,"files":[{"live":"~/.config/app/app.env ","name":"a"}]}\n' \
    >"$VT3/.config/omabackup/secrets/files.json"
VOUT="$(_v_env "$VT3" collect)"; VRC=$?
it "files.json refuses a path ending in whitespace"
[[ "$VRC" != 0 && "$VOUT" == *"files.json"* ]] && ok || fail "rc=$VRC: $VOUT"

# An empty list is the group switched off, not an error.
printf '{"schemaVersion":1,"files":[]}\n' >"$VT3/.config/omabackup/secrets/files.json"
printf '{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[{"id":"misc","label":"Misc","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/misc"]},{"id":"secrets","label":"Secrets","mode":"age","coupled":false,"critical":false}]}\n' >"$VT3/g.json"
VOUT="$(_v_env "$VT3" sync --commit)"; VRC=$?
it "an empty files.json leaves the other groups syncing"
[[ "$VRC" == 0 && -n "$(git -C "$VT3/repo" rev-parse -q --verify HEAD:configs/misc/x.conf)" ]] && ok || fail "rc=$VRC: $VOUT"

# A directory without an owner PID in its name is not swept.
mkdir -p "$VH/.state/omabackup-secrets.legacy1"
_v_env "$VH" sync --commit >/dev/null 2>&1
it "a leftover directory whose owner cannot be told from its name is kept"
[[ -d "$VH/.state/omabackup-secrets.legacy1" ]] && ok || fail "it was removed"

# The plan refuses what --apply would refuse.
VOUT="$(HOME="$VS1/home" OMABACKUP_GROUPS="$VS1/g.json" OMABACKUP_STATE="$VS1/home/.state" OMABACKUP_REPO="$VS1/repo" \
    XDG_RUNTIME_DIR=/nonexistent OMABACKUP_LOG_SKIP=1 "$OB" secrets restore -i "$VH/ids/a.txt" 2>&1)"; VRC=$?
it "the restore plan already refuses a destination that resolves outside ~/"
[[ "$VRC" != 0 && "$VOUT" == *"resolves outside"* && "$VOUT" != *"would be written"* ]] && ok || fail "rc=$VRC: $VOUT"

# -- review omabackup-89 -----------------------------------------------------------
# The byte check holds whichever groups run.
VG="$(mktemp -d)"; VGM="vaultmark$RANDOM$RANDOM"; _v_home "$VG" "$VGM"
ln "$VG/.config/app/app.env" "$VG/.config/misc/linked.env"
_v_env "$VG" secrets accept >/dev/null
VOUT="$(_v_env "$VG" sync --commit --groups misc)"; VRC=$?
it "with --groups leaving the secrets group out, a copy of a secret is still refused"
[[ "$VRC" != 0 && "$(git -C "$VG/repo" log -p --all 2>/dev/null | grep -c -F "$VGM")" == 0 ]] && ok || fail "rc=$VRC: $VOUT"
sed -i 's/"mode":"age",/"mode":"age","enabled":false,/' "$VG/g.json"
VOUT="$(_v_env "$VG" sync --commit)"; VRC=$?
it "with the secrets group disabled, a copy of a secret is still refused"
[[ "$VRC" != 0 && "$(git -C "$VG/repo" log -p --all 2>/dev/null | grep -c -F "$VGM")" == 0 ]] && ok || fail "rc=$VRC: $VOUT"
sed -i 's/"enabled":false,//' "$VG/g.json"

# The refusal never names the copy: its name could be the secret.
rm -f "$VG/.config/misc/linked.env"
ln "$VG/.config/app/app.env" "$VG/.config/misc/$VGM"
VOUT="$(_v_env "$VG" sync --commit)"; VRC=$?
it "a copy named after the secret is refused without printing its name"
[[ "$VRC" != 0 && "$VOUT" == *"names not shown"* && "$VOUT" != *"$VGM"* ]] && ok || fail "rc=$VRC: $VOUT"
rm -f "$VG/.config/misc/$VGM"

# A listing or a hash that fails is a refusal, not "no copies found".
mkdir -p "$VG/shim"
cat >"$VG/shim/find" <<'SH'
#!/bin/bash
for a in "$@"; do [[ "$a" == -prune ]] && exit 1; done
exec /usr/bin/find "$@"
SH
cat >"$VG/shim/sha256sum" <<'SH'
#!/bin/bash
for a in "$@"; do [[ "$a" == */.state/staging/* ]] && exit 1; done
exec /usr/bin/sha256sum "$@"
SH
chmod +x "$VG/shim/find" "$VG/shim/sha256sum"
cp "$VG/.config/app/app.env" "$VG/.config/misc/same-size.env"; sed -i 's/^T/X/' "$VG/.config/misc/same-size.env"
VOUT="$(PATH="$VG/shim:$PATH" _v_env "$VG" sync --commit)"; VRC=$?
it "a failed listing or hash in the byte check refuses the collect"
[[ "$VRC" != 0 && "$VOUT" == *"could not be checked"* ]] && ok || fail "rc=$VRC: $VOUT"
rm -f "$VG/shim/find"
VOUT="$(PATH="$VG/shim:$PATH" _v_env "$VG" sync --commit)"; VRC=$?
it "and so does a hash that fails on a candidate of a secret's size"
[[ "$VRC" != 0 && "$VOUT" == *"could not be checked"* ]] && ok || fail "rc=$VRC: $VOUT"
rm -f "$VG/.config/misc/same-size.env"

# A restore's temporary, holding a version no current hash matches.
printf 'TOKEN=an-older-%s\n' "$VGM" >"$VG/.config/misc/.omabackup-restore.Ab12Cd"
VOUT="$(_v_env "$VG" sync --commit)"; VRC=$?
it "a restore's leftover temporary inside another group's tree is refused"
[[ "$VRC" != 0 && "$(git -C "$VG/repo" log -p --all 2>/dev/null | grep -c -F "an-older-$VGM")" == 0 ]] && ok || fail "rc=$VRC: $VOUT"
rm -f "$VG/.config/misc/.omabackup-restore.Ab12Cd"

# An empty list on a machine that never set up age at all.
VE="$(mktemp -d)"; _v_home "$VE" "x"
rm -f "$VE/.config/omabackup/secrets/recipients.txt"
printf '{"schemaVersion":1,"files":[]}\n' >"$VE/.config/omabackup/secrets/files.json"
VOUT="$(PATH="$VC2/fakebin:$PATH" _v_env "$VE" sync --commit)"; VRC=$?
it "an empty list needs neither age nor recipients"
[[ "$VRC" == 0 && -n "$(git -C "$VE/repo" rev-parse -q --verify HEAD:configs/misc/x.conf)" ]] && ok || fail "rc=$VRC: $VOUT"
VOUT="$(_v_env "$VE" verify)"
it "and verify does not report missing recipients for it"
assert_not_contains "$VOUT" "recipients"

# A destination under a directory another account can write to.
VW="$(mktemp -d)"; mkdir -p "$VW/repo/secrets/age" "$VW/home/shared"; cp "$VH/g.json" "$VW/g.json"
chmod 777 "$VW/home/shared"
printf 'forged\n' | age -r "$VFA" -o "$VW/repo/secrets/age/w.age"
printf '{"schemaVersion":1,"files":[{"name":"w","live":"~/shared/w.txt","mode":"600"}]}' \
    | age -r "$VFA" -o "$VW/repo/secrets/age/_index.age"
VOUT="$(HOME="$VW/home" OMABACKUP_GROUPS="$VW/g.json" OMABACKUP_STATE="$VW/home/.state" OMABACKUP_REPO="$VW/repo" \
    XDG_RUNTIME_DIR=/nonexistent OMABACKUP_LOG_SKIP=1 "$OB" secrets restore -i "$VH/ids/a.txt" --apply 2>&1)"; VRC=$?
it "restore refuses a destination under a directory others can write to"
[[ "$VRC" != 0 && "$VOUT" == *"not private"* && ! -e "$VW/home/shared/w.txt" ]] && ok || fail "rc=$VRC: $VOUT"

# -- review omabackup-90 -----------------------------------------------------------
# A restore's temporary is the tool's own name: refused even on a machine with
# no secrets list at all.
VN="$(mktemp -d)"; VNM="vaultmark$RANDOM$RANDOM"; _v_home "$VN" "x"
rm -f "$VN/.config/omabackup/secrets/files.json"
printf 'TOKEN=%s\n' "$VNM" >"$VN/.config/misc/.omabackup-restore.Zz90Aa"
VOUT="$(_v_env "$VN" sync --commit)"; VRC=$?
it "a restore's leftover temporary is refused even with no secrets list"
[[ "$VRC" != 0 && "$VOUT" == *"restore's temporary"* && "$(git -C "$VN/repo" log -p --all 2>/dev/null | grep -c -F "$VNM")" == 0 ]] && ok || fail "rc=$VRC: $VOUT"

# A git plugin turns its local files into a patch, whose bytes no longer equal
# the secret's. The plugin's files are checked before the patch is made.
VP="$(mktemp -d)"; VPM="vaultmark$RANDOM$RANDOM"; _v_home "$VP" "$VPM"
mkdir -p "$VP/.config/x/plugins/p"
git -C "$VP/.config/x/plugins/p" init -q
git -C "$VP/.config/x/plugins/p" config user.email t@t
git -C "$VP/.config/x/plugins/p" config user.name t
printf 'init\n' >"$VP/.config/x/plugins/p/plugin.txt"
git -C "$VP/.config/x/plugins/p" add -A
git -C "$VP/.config/x/plugins/p" commit -qm base
git -C "$VP/.config/x/plugins/p" remote add origin https://example.invalid/p.git
cat >"$VP/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"plugins","label":"Plugins","mode":"triple","coupled":false,"critical":false,"paths":["~/.config/x/plugins"]},
 {"id":"secrets","label":"Secrets","mode":"age","coupled":false,"critical":false}]}
JSON
_v_env "$VP" secrets accept >/dev/null
cp "$VP/.config/app/app.env" "$VP/.config/x/plugins/p/copied.env"
VOUT="$(_v_env "$VP" sync --commit --groups plugins)"; VRC=$?
it "a copy of a secret inside a git plugin is refused before it becomes a patch"
[[ "$VRC" != 0 && "$(git -C "$VP/repo" log -p --all 2>/dev/null | grep -c -F "$VPM")" == 0 \
    && -z "$(grep -r -a -l -F "$VPM" "$VP/.state" 2>/dev/null)" ]] && ok || fail "rc=$VRC: $VOUT"
rm -f "$VP/.config/x/plugins/p/copied.env"
printf 'TOKEN=old-%s\n' "$VPM" >"$VP/.config/x/plugins/p/.omabackup-restore.Pp90Qq"
VOUT="$(_v_env "$VP" sync --commit --groups plugins)"; VRC=$?
it "and so is a restore's leftover temporary inside it"
[[ "$VRC" != 0 && "$(git -C "$VP/repo" log -p --all 2>/dev/null | grep -c -F "old-$VPM")" == 0 ]] && ok || fail "rc=$VRC: $VOUT"
rm -f "$VP/.config/x/plugins/p/.omabackup-restore.Pp90Qq"
VOUT="$(_v_env "$VP" sync --commit --groups plugins)"; VRC=$?
it "a git plugin with nothing secret in it still syncs"
[[ "$VRC" == 0 ]] && ok || fail "rc=$VRC: $VOUT"

# A declared secret that is a symlink is refused before any collector runs,
# whichever groups are selected.
VL="$(mktemp -d)"; VLM="vaultmark$RANDOM$RANDOM"; _v_home "$VL" "$VLM"
mkdir -p "$VL/keys"; mv "$VL/.config/app/app.env" "$VL/keys/real.env"
ln -s "$VL/keys/real.env" "$VL/.config/app/app.env"
cp "$VL/keys/real.env" "$VL/.config/misc/copy.env"
_v_env "$VL" secrets accept >/dev/null
VOUT="$(_v_env "$VL" sync --commit --groups misc)"; VRC=$?
it "a declared secret that is a symlink is refused even when the secrets group does not run"
[[ "$VRC" != 0 && "$VOUT" == *"symlink"* && "$(git -C "$VL/repo" log -p --all 2>/dev/null | grep -c -F "$VLM")" == 0 ]] \
    && ok || fail "rc=$VRC: $VOUT"

# Size and hash come from the same read: a size taken from one version and a
# hash from another would match no file at all.
VZ="$(mktemp -d)"; VZM="vaultmark$RANDOM$RANDOM"; _v_home "$VZ" "$VZM"
cp "$VZ/.config/app/app.env" "$VZ/.config/misc/copy.env"
_v_env "$VZ" secrets accept >/dev/null
mkdir -p "$VZ/shim"
cat >"$VZ/shim/stat" <<'SH'
#!/bin/bash
# Reports the declared secret one byte shorter than it is, as if it grew
# between the size and the hash.
out="$(/usr/bin/stat "$@")" || exit $?
if [[ "$*" == *"%s"* && "$*" == */.config/app/app.env* ]]; then
    printf '%s\n' "$(( out - 1 ))"
else
    printf '%s\n' "$out"
fi
SH
chmod +x "$VZ/shim/stat"
VOUT="$(PATH="$VZ/shim:$PATH" _v_env "$VZ" sync --commit --groups misc)"; VRC=$?
it "a secret's size and hash describe the same bytes"
[[ "$VRC" != 0 && "$(git -C "$VZ/repo" log -p --all 2>/dev/null | grep -c -F "$VZM")" == 0 ]] && ok || fail "rc=$VRC: $VOUT"

# The home itself must not be renameable by someone else: every directory
# above it belongs to root or to the user, and one others can write to has
# the sticky bit.
_v_restore_fixture() {  # _v_restore_fixture <dir> <home>
    mkdir -p "$1/repo/secrets/age" "$2/.config"; chmod 700 "$2"; cp "$VH/g.json" "$1/g.json"
    printf 'anchored\n' | age -r "$VFA" -o "$1/repo/secrets/age/w.age"
    printf '{"schemaVersion":1,"files":[{"name":"w","live":"~/.config/w.txt","mode":"600"}]}' \
        | age -r "$VFA" -o "$1/repo/secrets/age/_index.age"
}
_v_restore() {  # _v_restore <dir> <home>
    HOME="$2" OMABACKUP_GROUPS="$1/g.json" OMABACKUP_STATE="$2/.state" OMABACKUP_REPO="$1/repo" \
        XDG_RUNTIME_DIR=/nonexistent OMABACKUP_LOG_SKIP=1 "$OB" secrets restore -i "$VH/ids/a.txt" --apply 2>&1
}
VA="$(mktemp -d)"; mkdir -p "$VA/open"; chmod 777 "$VA/open"; _v_restore_fixture "$VA" "$VA/open/home"
VOUT="$(_v_restore "$VA" "$VA/open/home")"; VRC=$?
it "restore refuses a home whose parent others can write to without the sticky bit"
[[ "$VRC" != 0 && ! -e "$VA/open/home/.config/w.txt" ]] && ok || fail "rc=$VRC: $VOUT"
chmod 1777 "$VA/open"
VOUT="$(_v_restore "$VA" "$VA/open/home")"; VRC=$?
it "and accepts it once that parent has the sticky bit"
[[ "$VRC" == 0 && "$(cat "$VA/open/home/.config/w.txt" 2>/dev/null)" == anchored ]] && ok || fail "rc=$VRC: $VOUT"

VA2="$(mktemp -d)"; mkdir -p "$VA2/other" "$VA2/shim"; chmod 711 "$VA2/other"; _v_restore_fixture "$VA2" "$VA2/other/home"
cat >"$VA2/shim/stat" <<SH
#!/bin/bash
# The home's parent, as if another account owned it.
if [[ "\${*: -1}" == "$VA2/other" && "\$*" == *"%u"* ]]; then
    printf '4242 711\n'; exit 0
fi
exec /usr/bin/stat "\$@"
SH
chmod +x "$VA2/shim/stat"
VOUT="$(PATH="$VA2/shim:$PATH" _v_restore "$VA2" "$VA2/other/home")"; VRC=$?
it "restore refuses a home whose parent another account owns"
[[ "$VRC" != 0 && ! -e "$VA2/other/home/.config/w.txt" ]] && ok || fail "rc=$VRC: $VOUT"

# -- review omabackup-91 -----------------------------------------------------------
# A destination another group collects in the clear is refused by restore: on
# a machine that only restored there is no files.json, so the next sync would
# have nothing to compare it with.
VQ="$(mktemp -d)"; VQM="vaultmark$RANDOM$RANDOM"
mkdir -p "$VQ/repo/secrets/age" "$VQ/home/.config/misc"; chmod 700 "$VQ/home"; cp "$VH/g.json" "$VQ/g.json"
printf 'TOKEN=%s\n' "$VQM" | age -r "$VFA" -o "$VQ/repo/secrets/age/q.age"
printf '{"schemaVersion":1,"files":[{"name":"q","live":"~/.config/misc/q.env","mode":"600"}]}' \
    | age -r "$VFA" -o "$VQ/repo/secrets/age/_index.age"
VOUT="$(_v_restore "$VQ" "$VQ/home")"; VRC=$?
it "restore refuses a destination another group collects in the clear"
[[ "$VRC" != 0 && "$VOUT" == *"in the clear"* && ! -e "$VQ/home/.config/misc/q.env" ]] && ok || fail "rc=$VRC: $VOUT"

# A plugin's patch also carries what HEAD had: removed lines and context. A
# copy of a secret committed in the plugin, then edited or deleted, is checked
# on that side too.
VP2="$(mktemp -d)"; VP2M="vaultmark$RANDOM$RANDOM"; _v_home "$VP2" "$VP2M"
_v_plugin() {  # _v_plugin <home>: a git plugin with a remote under ~/.config/x/plugins/p
    mkdir -p "$1/.config/x/plugins/p"
    git -C "$1/.config/x/plugins/p" init -q
    git -C "$1/.config/x/plugins/p" config user.email t@t
    git -C "$1/.config/x/plugins/p" config user.name t
    printf 'init\n' >"$1/.config/x/plugins/p/plugin.txt"
    git -C "$1/.config/x/plugins/p" add -A
    git -C "$1/.config/x/plugins/p" commit -qm base
    git -C "$1/.config/x/plugins/p" remote add origin https://example.invalid/p.git
    cp "$VP/g.json" "$1/g.json"
}
_v_plugin "$VP2"
_v_env "$VP2" secrets accept >/dev/null
cp "$VP2/.config/app/app.env" "$VP2/.config/x/plugins/p/kept.env"
git -C "$VP2/.config/x/plugins/p" add kept.env
git -C "$VP2/.config/x/plugins/p" commit -qm kept
printf 'harmless\n' >"$VP2/.config/x/plugins/p/kept.env"
VOUT="$(_v_env "$VP2" sync --commit --groups plugins)"; VRC=$?
it "a secret's copy in a plugin's HEAD is refused when the file is edited"
[[ "$VRC" != 0 && "$(git -C "$VP2/repo" log -p --all 2>/dev/null | grep -c -F "$VP2M")" == 0 \
    && -z "$(grep -r -a -l -F "$VP2M" "$VP2/.state" 2>/dev/null)" ]] && ok || fail "rc=$VRC: $VOUT"
rm -f "$VP2/.config/x/plugins/p/kept.env"
VOUT="$(_v_env "$VP2" sync --commit --groups plugins)"; VRC=$?
it "and when it is deleted"
[[ "$VRC" != 0 && "$(git -C "$VP2/repo" log -p --all 2>/dev/null | grep -c -F "$VP2M")" == 0 ]] && ok || fail "rc=$VRC: $VOUT"
git -C "$VP2/.config/x/plugins/p" checkout -q -- kept.env
git -C "$VP2/.config/x/plugins/p" rm -q kept.env
git -C "$VP2/.config/x/plugins/p" commit -qm gone
printf 'TOKEN=old-%s\n' "$VP2M" >"$VP2/.config/x/plugins/p/.omabackup-restore.Hh91Kk"
git -C "$VP2/.config/x/plugins/p" add -f .omabackup-restore.Hh91Kk
git -C "$VP2/.config/x/plugins/p" commit -qm leftover
rm -f "$VP2/.config/x/plugins/p/.omabackup-restore.Hh91Kk"
VOUT="$(_v_env "$VP2" sync --commit --groups plugins)"; VRC=$?
it "and a restore's temporary deleted from a plugin's HEAD is refused"
[[ "$VRC" != 0 && "$(git -C "$VP2/repo" log -p --all 2>/dev/null | grep -c -F "old-$VP2M")" == 0 ]] && ok || fail "rc=$VRC: $VOUT"
git -C "$VP2/.config/x/plugins/p" checkout -q -- .omabackup-restore.Hh91Kk
git -C "$VP2/.config/x/plugins/p" rm -q .omabackup-restore.Hh91Kk
git -C "$VP2/.config/x/plugins/p" commit -qm clean
printf 'edited\n' >>"$VP2/.config/x/plugins/p/plugin.txt"
VOUT="$(_v_env "$VP2" sync --commit --groups plugins)"; VRC=$?
it "an ordinary edit in a git plugin still syncs"
[[ "$VRC" == 0 ]] && ok || fail "rc=$VRC: $VOUT"

# Restore reads ciphertext anyone holding the public keys can write: what it
# decrypts is bounded, the same 1 MiB as collect.
_v_plan() {  # _v_plan <dir> <home> [env...]
    local d="$1" h="$2"; shift 2
    env "$@" HOME="$h" OMABACKUP_GROUPS="$d/g.json" OMABACKUP_STATE="$h/.state" OMABACKUP_REPO="$d/repo" \
        XDG_RUNTIME_DIR=/nonexistent OMABACKUP_LOG_SKIP=1 "$OB" secrets restore -i "$VH/ids/a.txt" 2>&1
}
_v_index() {  # _v_index <dir> <json>
    printf '%s' "$2" | age -r "$VFA" -o "$1/repo/secrets/age/_index.age"
}
VB="$(mktemp -d)"; mkdir -p "$VB/repo/secrets/age" "$VB/home/.config"; chmod 700 "$VB/home"; cp "$VH/g.json" "$VB/g.json"
head -c 1048577 /dev/zero | tr '\0' 'a' | age -r "$VFA" -o "$VB/repo/secrets/age/big.age"
head -c 1048576 /dev/zero | tr '\0' 'a' | age -r "$VFA" -o "$VB/repo/secrets/age/edge.age"
_v_index "$VB" '{"schemaVersion":1,"files":[{"name":"big","live":"~/.config/big.txt"},{"name":"edge","live":"~/.config/edge.txt"}]}'
VOUT="$(_v_plan "$VB" "$VB/home")"; VRC=$?
it "restore refuses a secret that decrypts to more than 1 MiB"
[[ "$VRC" != 0 && "$VOUT" == *"big"*"larger than 1 MiB"* ]] && ok || fail "rc=$VRC: $VOUT"
it "and still plans one of exactly 1 MiB"
assert_contains "$VOUT" "edge would be written"
it "and leaves no plaintext behind"
[[ -z "$(find "$VB/home" -type f -size +1000k 2>/dev/null)" ]] && ok || fail "left: $(find "$VB/home" -type f -size +1000k)"

_v_index "$VB" "$(jq -nc '{schemaVersion:1, files:[], pad:("a" * 1048577)}')"
VOUT="$(_v_plan "$VB" "$VB/home")"; VRC=$?
it "restore refuses an index larger than 1 MiB"
[[ "$VRC" != 0 && "$VOUT" == *"index"* ]] && ok || fail "rc=$VRC: $VOUT"
_v_index "$VB" "$(jq -nc '{schemaVersion:1, files:[range(1001) | {name:"n\(.)", live:"~/.config/n\(.)"}]}')"
VOUT="$(_v_plan "$VB" "$VB/home")"; VRC=$?
it "restore refuses an index with more than 1000 entries"
[[ "$VRC" != 0 && "$VOUT" == *"index"* ]] && ok || fail "rc=$VRC: $VOUT"

mkdir -p "$VB/slow"; printf '#!/bin/bash\nexec sleep 20\n' >"$VB/slow/age"; chmod +x "$VB/slow/age"
_v_index "$VB" '{"schemaVersion":1,"files":[]}'
VT0=$SECONDS
VOUT="$(_v_plan "$VB" "$VB/home" PATH="$VB/slow:$PATH" OMABACKUP_SECRETS_DECRYPT_TIMEOUT=1)"; VRC=$?
it "a decrypt that hangs is cut off by its deadline"
[[ "$VRC" != 0 && $((SECONDS - VT0)) -lt 10 ]] && ok || fail "rc=$VRC after $((SECONDS - VT0))s: $VOUT"

# An index that would draw on the terminal is refused before anything prints.
printf 'x\n' | age -r "$VFA" -o "$VB/repo/secrets/age/c.age"
_v_index "$VB" "$(jq -nc '{schemaVersion:1, files:[{name:"c", live:"~/safe\u001b[2Jredraw"}]}')"
VOUT="$(_v_plan "$VB" "$VB/home")"; VRC=$?
it "restore refuses an index with control characters, without echoing them"
[[ "$VRC" != 0 && "$VOUT" != *$'\033[2J'* ]] && ok || fail "rc=$VRC: $(printf '%q' "$VOUT")"
_v_index "$VB" "$(jq -nc '{schemaVersion:1, files:[{name:"c", live:"~/.config/café.txt"}]}')"
VOUT="$(_v_plan "$VB" "$VB/home")"; VRC=$?
it "and still plans a UTF-8 path"
[[ "$VRC" == 0 && "$VOUT" == *"café.txt"* ]] && ok || fail "rc=$VRC: $VOUT"
printf '{"schemaVersion":1,"files":[{"live":"~/.config/app/a\\u001b[2J","name":"a"}]}\n' \
    >"$VP2/.config/omabackup/secrets/files.json"
VOUT="$(_v_env "$VP2" collect)"; VRC=$?
it "files.json refuses a path with a control character"
[[ "$VRC" != 0 && "$VOUT" == *"files.json"* ]] && ok || fail "rc=$VRC: $VOUT"

# -- review omabackup-92 -----------------------------------------------------------
# --groups narrows what a command collects, never which groups restore
# compares a destination with.
VOUT="$(HOME="$VQ/home" OMABACKUP_GROUPS="$VQ/g.json" OMABACKUP_STATE="$VQ/home/.state" OMABACKUP_REPO="$VQ/repo" \
    XDG_RUNTIME_DIR=/nonexistent OMABACKUP_LOG_SKIP=1 "$OB" secrets restore -i "$VH/ids/a.txt" --apply --groups secrets 2>&1)"; VRC=$?
it "restore with --groups still refuses a destination another group collects in the clear"
[[ "$VRC" != 0 && "$VOUT" == *"in the clear"* && ! -e "$VQ/home/.config/misc/q.env" ]] && ok || fail "rc=$VRC: $VOUT"

# Collect never writes an index restore would refuse.
VI="$(mktemp -d)"; _v_home "$VI" "x"
jq -nc '{schemaVersion:1, files:[range(1001) | {live:"~/.config/app/n\(.)", name:"n\(.)"}]}' \
    >"$VI/.config/omabackup/secrets/files.json"
_v_env "$VI" secrets accept >/dev/null
VOUT="$(_v_env "$VI" sync --commit)"; VRC=$?
it "collect refuses a list of more than 1000 secrets, which restore could not read back"
[[ "$VRC" != 0 && "$VOUT" == *"1000"* && -z "$(_v_blob "$VI" _index.age)" ]] && ok || fail "rc=$VRC: $VOUT"

# The deadline cannot be switched off by its override.
for VTO in 0 0s abc; do
    VT0=$SECONDS
    VOUT="$(_v_plan "$VB" "$VB/home" PATH="$VB/slow:$PATH" OMABACKUP_SECRETS_DECRYPT_TIMEOUT="$VTO")"; VRC=$?
    it "a decrypt deadline of '$VTO' is refused rather than disabling it"
    [[ "$VRC" != 0 && "$VOUT" == *"OMABACKUP_SECRETS_DECRYPT_TIMEOUT"* && $((SECONDS - VT0)) -lt 10 ]] && ok \
        || fail "rc=$VRC after $((SECONDS - VT0))s: $VOUT"
done

# -- third analysis (scout, omabackup-27) -------------------------------------------
# Restore never writes plaintext inside the backup itself: the repo, the
# directory --from names, or the git tree holding it.
VR="$(mktemp -d)"; mkdir -p "$VR/home/repo/secrets/age" "$VR/home/other/secrets/age"; cp "$VH/g.json" "$VR/g.json"
git init -q "$VR/home/repo"; git init -q "$VR/home/other"
chmod -R go-rwx "$VR/home"
ln -s "$VR/home/repo" "$VR/home/link"
for VD in repo other; do
    printf 'TOKEN=leak\n' | age -r "$VFA" -o "$VR/home/$VD/secrets/age/q.age"
done
_v_rplan() {  # _v_rplan <live> [--apply] [--from dir]: restore with OMABACKUP_REPO=~/repo
    local live="$1"; shift
    jq -nc --arg l "$live" '{schemaVersion:1, files:[{name:"q", live:$l}]}' | age -r "$VFA" -o "$VR/home/repo/secrets/age/_index.age"
    cp "$VR/home/repo/secrets/age/_index.age" "$VR/home/other/secrets/age/_index.age"
    HOME="$VR/home" OMABACKUP_GROUPS="$VR/g.json" OMABACKUP_STATE="$VR/home/.state" OMABACKUP_REPO="$VR/home/repo" \
        XDG_RUNTIME_DIR=/nonexistent OMABACKUP_LOG_SKIP=1 "$OB" secrets restore -i "$VH/ids/a.txt" "$@" 2>&1
}
VOUT="$(_v_rplan "~/repo/leaked.env")"; VRC=$?
it "the restore plan refuses a destination inside the backup repo"
[[ "$VRC" != 0 && "$VOUT" == *"backup"* && "$VOUT" != *"would be written"* ]] && ok || fail "rc=$VRC: $VOUT"
VOUT="$(_v_rplan "~/repo/leaked.env" --apply)"; VRC=$?
it "and --apply writes nothing there, not even a temporary"
[[ "$VRC" != 0 && -z "$(find "$VR/home/repo" -name 'leaked.env' -o -name '.omabackup-restore.*')" ]] && ok || fail "rc=$VRC: $VOUT"
VOUT="$(_v_rplan "~/link/leaked.env" --apply)"; VRC=$?
it "and so is the backup repo reached through a symlink"
[[ "$VRC" != 0 && ! -e "$VR/home/repo/leaked.env" ]] && ok || fail "rc=$VRC: $VOUT"
VOUT="$(_v_rplan "~/other/leaked.env" --apply --from "$VR/home/other/secrets/age")"; VRC=$?
it "and so is the git tree that --from points into"
[[ "$VRC" != 0 && ! -e "$VR/home/other/leaked.env" ]] && ok || fail "rc=$VRC: $VOUT"
VOUT="$(_v_rplan "~/.config/q.env" --apply)"; VRC=$?
it "a private destination outside the backup still restores"
[[ "$VRC" == 0 && "$(cat "$VR/home/.config/q.env" 2>/dev/null)" == "TOKEN=leak" ]] && ok || fail "rc=$VRC: $VOUT"

# Collect refuses an index over 1 MiB. Many names for one file with a long
# path get there without many files, and a stand-in age keeps it fast.
VX="$(mktemp -d)"; _v_home "$VX" "x"
VXP="d"; for VI2 in $(seq 15); do VXP="$VXP/$(printf 'p%.0s' $(seq 250))"; done
mkdir -p "$VX/$VXP"; printf 'k\n' >"$VX/$VXP/s"
jq -nc --arg l "~/$VXP/s" '{schemaVersion:1, files:[range(280) | {live:$l, name:"n\(.)"}]}' \
    >"$VX/.config/omabackup/secrets/files.json"
_v_env "$VX" secrets accept >/dev/null
mkdir -p "$VX/fakeage"
cat >"$VX/fakeage/age" <<'SH'
#!/bin/bash
out=""; while (($#)); do [[ "$1" == -o ]] && { out="$2"; shift; }; shift; done
printf 'age-encryption.org/v1\nstand-in\n' >"$out"
SH
chmod +x "$VX/fakeage/age"
VOUT="$(PATH="$VX/fakeage:$PATH" _v_env "$VX" sync --commit)"; VRC=$?
it "collect refuses an index larger than 1 MiB, which restore could not read back"
[[ "$VRC" != 0 && "$VOUT" == *"index is larger than 1 MiB"* && -z "$(_v_blob "$VX" _index.age)" ]] && ok || fail "rc=$VRC: ${VOUT:0:400}"

# -- a passphrase-wrapped identity, binary or armored -------------------------------
# The rescue identity is wrapped with `age -p`, and its printed copy is the
# armored form (`age -p -a`), the only one that fits on paper. The loader knew
# only the binary header, so the armored file was read as a plain identity and
# refused. age asks for a passphrase on the terminal, so a stand-in age plays
# the person typing it: `age -d -- <file>` unlocks with a key of its own, and
# every other call goes to the real age.
VP="$(mktemp -d)"; _v_home "$VP" "vaultmark$RANDOM"
_v_env "$VP" secrets accept >/dev/null
_v_env "$VP" sync --commit >/dev/null
mkdir -p "$VP/wrap/bin"
age-keygen -o "$VP/wrap/k.txt" 2>/dev/null
age-keygen -o "$VP/wrap/other.txt" 2>/dev/null
age -r "$(age-keygen -y "$VP/wrap/k.txt")" -o "$VP/wrap/b.age" "$VP/ids/b.txt"
age -a -r "$(age-keygen -y "$VP/wrap/k.txt")" -o "$VP/wrap/b.age.txt" "$VP/ids/b.txt"
age -a -r "$(age-keygen -y "$VP/wrap/other.txt")" -o "$VP/wrap/locked.age.txt" "$VP/ids/b.txt"
cat >"$VP/wrap/bin/age" <<SH
#!/bin/bash
if [[ \$# == 3 && "\$1" == -d && "\$2" == -- ]]; then
    exec "$(command -v age)" -d -i "$VP/wrap/k.txt" -- "\$3"
fi
exec "$(command -v age)" "\$@"
SH
chmod +x "$VP/wrap/bin/age"

VOUT="$(PATH="$VP/wrap/bin:$PATH" _v_env "$VP" secrets drill -i "$VP/wrap/b.age")"; VRC=$?
it "a drill unlocks a passphrase-wrapped identity in its binary form"
[[ "$VRC" == 0 && "$VOUT" == *"drill passed"* ]] && ok || fail "rc=$VRC: $VOUT"

VOUT="$(PATH="$VP/wrap/bin:$PATH" _v_env "$VP" secrets drill -i "$VP/wrap/b.age.txt")"; VRC=$?
it "and in its armored form, the one that is printed"
[[ "$VRC" == 0 && "$VOUT" == *"drill passed"* ]] && ok || fail "rc=$VRC: $VOUT"

VOUT="$(PATH="$VP/wrap/bin:$PATH" _v_env "$VP" secrets restore -i "$VP/wrap/b.age.txt")"; VRC=$?
it "restore takes the armored form too"
[[ "$VRC" == 0 && "$VOUT" == *"app.env"* ]] && ok || fail "rc=$VRC: $VOUT"

VOUT="$(PATH="$VP/wrap/bin:$PATH" _v_env "$VP" secrets drill -i "$VP/wrap/locked.age.txt")"; VRC=$?
it "an armored identity that does not unlock is refused as one that did not unlock"
[[ "$VRC" != 0 && "$VOUT" == *"could not unlock"* ]] && ok || fail "rc=$VRC: $VOUT"

# Typed back from paper, the armored file easily gains blank lines on top; age
# skips them, so the detection must too (review 94, rev-2).
{ printf '\n  \r\n'; cat "$VP/wrap/b.age.txt"; } >"$VP/wrap/typed.age.txt"
VOUT="$(PATH="$VP/wrap/bin:$PATH" _v_env "$VP" secrets drill -i "$VP/wrap/typed.age.txt")"; VRC=$?
it "an armored identity with blank lines above its header still unlocks"
[[ "$VRC" == 0 && "$VOUT" == *"drill passed"* ]] && ok || fail "rc=$VRC: $VOUT"

# A plain identity whose comment only mentions the header stays plain.
{ printf '# -----BEGIN AGE ENCRYPTED FILE-----\n'; cat "$VP/ids/b.txt"; } >"$VP/wrap/plain.txt"
VOUT="$(PATH="$VP/wrap/bin:$PATH" _v_env "$VP" secrets drill -i "$VP/wrap/plain.txt")"; VRC=$?
it "a plain identity whose comment names the armor header is still read as plain"
[[ "$VRC" == 0 && "$VOUT" == *"drill passed"* ]] && ok || fail "rc=$VRC: $VOUT"

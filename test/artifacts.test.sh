# Regressions for `omabackup artifacts` (lib/artifacts.sh).
#
# This is the verb a restore-picking UI needs to exist at all: the panel
# cannot list a `dir` destination itself (Quickshell.Io.Process is the only
# I/O it is allowed), and "no artifacts here" must never look like "could not
# tell" -- the same distinction docs/DESIGN.md already draws for verify's own
# findings, applied here to what gets shown before a restore is even chosen.

OB="$PWD/bin/omabackup"

_art_env() {  # _art_env <home> <args...>
    local h="$1"; shift
    HOME="$h" OMABACKUP_GROUPS="$PWD/groups.default.json" OMABACKUP_STATE="$h/.state" \
        OMABACKUP_REPO="${OMABACKUP_REPO_OVERRIDE:-/nonexistent}" \
        OMABACKUP_DESTINATIONS="$h/destinations.json" \
        XDG_RUNTIME_DIR=/nonexistent "$OB" "$@" 2>&1
}

_art_repo() {
    local r="$1"
    mkdir -p "$r/configs/app"
    git init -q "$r"; git -C "$r" config user.email t@t; git -C "$r" config user.name t
    printf 'one\n' >"$r/configs/app/f.txt"
    git -C "$r" add -A && git -C "$r" commit -qm one
}

# ── no dir destinations configured ──────────────────────────────────────────
NH="$(mktemp -d)"
cat >"$NH/destinations.json" <<'JSON'
{"schemaVersion":1,"destinations":[]}
JSON
NOUT="$(_art_env "$NH" artifacts --json)"

it "no dir destinations at all is an empty list, not an error"
assert_eq "$(jq -r '.destinations | length' <<<"$NOUT")" "0"

# ── a real pushed bundle is read back with its own manifest ────────────────
RH="$(mktemp -d)"; RR="$RH/repo"; _art_repo "$RR"
RNAS="$RH/nas"
cat >"$RH/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"nas","type":"dir","path":"$RNAS","keep":3}]}
JSON
OMABACKUP_REPO_OVERRIDE="$RR" _art_env "$RH" push nas >/dev/null
ROUT="$(OMABACKUP_REPO_OVERRIDE="$RR" _art_env "$RH" artifacts --json)"

it "the destination reports state ok"
assert_eq "$(jq -r '.destinations[0].state' <<<"$ROUT")" "ok"

it "the pushed bundle is listed"
assert_eq "$(jq -r '.destinations[0].artifacts | length' <<<"$ROUT")" "1"

it "and its own manifest was read back, not left empty"
assert_eq "$(jq -r '.destinations[0].artifacts[0].valid' <<<"$ROUT")" "true"

it "host comes from the artifact's manifest"
assert_eq "$(jq -r '.destinations[0].artifacts[0].host' <<<"$ROUT")" "$(hostname)"

it "so does the Omarchy version"
[[ "$(jq -r '.destinations[0].artifacts[0].omarchy.version' <<<"$ROUT")" != "null" ]] && ok \
    || fail "omarchy.version came back null from a real manifest"

it "the human-readable form names the destination and counts its artifacts"
assert_contains "$(OMABACKUP_REPO_OVERRIDE="$RR" _art_env "$RH" artifacts)" "1 artifact"

# ── three destination-level states, kept visibly distinct ──────────────────
SH="$(mktemp -d)"
SNAS="$SH/nas-empty"; mkdir -p "$SNAS"
SUSB="$SH/usb-unplugged"   # never created: simulates an unmounted drive
cat >"$SH/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[
 {"id":"empty","type":"dir","path":"$SNAS","keep":3},
 {"id":"gone","type":"dir","path":"$SUSB","keep":3}]}
JSON
SOUT="$(_art_env "$SH" artifacts --json)"

it "an existing but empty directory is state empty, not an error"
assert_eq "$(jq -r '.destinations[] | select(.id=="empty") | .state' <<<"$SOUT")" "empty"

it "an empty destination carries no error"
assert_eq "$(jq -r '.destinations[] | select(.id=="empty") | .error' <<<"$SOUT")" "null"

it "a directory that does not exist is state unreachable, not empty"
assert_eq "$(jq -r '.destinations[] | select(.id=="gone") | .state' <<<"$SOUT")" "unreachable"

it "and it says why"
assert_contains "$(jq -r '.destinations[] | select(.id=="gone") | .error' <<<"$SOUT")" "mounted"

it "unreachable is visibly different from empty in the human-readable form -- never the same shape"
OUT_HUMAN="$(_art_env "$SH" artifacts)"
assert_contains "$OUT_HUMAN" "unreachable"

# ── a file that looks like a bundle but is not one -- per-file, not fatal ──
GH="$(mktemp -d)"
GNAS="$GH/nas"; mkdir -p "$GNAS"
printf 'not a real archive\n' >"$GNAS/omabackup-otherhost-20200101-000000-aaaaaaaaaaaa.tar.zst"
cat >"$GH/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"nas","type":"dir","path":"$GNAS","keep":3}]}
JSON
GOUT="$(_art_env "$GH" artifacts --json)"

it "the destination itself is still state ok -- one bad file does not hide the others"
assert_eq "$(jq -r '.destinations[0].state' <<<"$GOUT")" "ok"

it "but the file itself is marked invalid, not silently given empty fields"
assert_eq "$(jq -r '.destinations[0].artifacts[0].valid' <<<"$GOUT")" "false"

it "and says why, rather than presenting it as an artifact with no metadata"
# Not valid zstd at all, so this fails at the pipeline stage -- "does not
# extract cleanly" -- rather than at the manifest.json stage. The two
# messages are deliberately distinct (see the corrupt-archive spec below);
# this one just isn't a real archive to begin with.
assert_contains "$(jq -r '.destinations[0].artifacts[0].error' <<<"$GOUT")" "extract cleanly"

# ── a destination whose own listing cannot be trusted ───────────────────────
# Same reasoning prune_bundles' own listing already applies to deletion:
# a `find` that stops partway must not be reported as "these are all the
# artifacts here."
LH="$(mktemp -d)"
LNAS="$LH/nas"; mkdir -p "$LNAS"
cat >"$LH/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"nas","type":"dir","path":"$LNAS","keep":3}]}
JSON
LSTUB="$(mktemp -d)"
printf '#!/bin/bash\nexit 1\n' >"$LSTUB/find"; chmod +x "$LSTUB/find"
LOUT="$(PATH="$LSTUB:$PATH" HOME="$LH" OMABACKUP_GROUPS="$PWD/groups.default.json" \
    OMABACKUP_STATE="$LH/.state" OMABACKUP_REPO=/nonexistent \
    OMABACKUP_DESTINATIONS="$LH/destinations.json" XDG_RUNTIME_DIR=/nonexistent \
    "$OB" artifacts --json 2>&1)"

it "a find that fails is reported as list-failed, never as an empty list"
assert_eq "$(jq -r '.destinations[0].state' <<<"$LOUT")" "list-failed"

it "empty and list-failed must never be the same state"
[[ "$(jq -r '.destinations[0].state' <<<"$LOUT")" != "empty" ]] && ok \
    || fail "a listing failure read exactly like a genuinely empty destination"

# ── newest first, and a github destination is not a source of artifacts ────
MH="$(mktemp -d)"; MR="$MH/repo"; _art_repo "$MR"
MNAS="$MH/nas"
cat >"$MH/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"nas","type":"dir","path":"$MNAS","keep":5}]}
JSON
mkdir -p "$MNAS"
touch -d "2020-01-01 00:00:00" "$MNAS/omabackup-old-20200101-000000-aaaaaaaaaaaa.tar.zst"
touch -d "2026-01-01 00:00:00" "$MNAS/omabackup-new-20260101-000000-bbbbbbbbbbbb.tar.zst"
MOUT="$(_art_env "$MH" artifacts --json)"

it "artifacts within a destination are sorted newest first"
assert_eq "$(jq -r '.destinations[0].artifacts[0].file' <<<"$MOUT")" \
    "omabackup-new-20260101-000000-bbbbbbbbbbbb.tar.zst"

it "github is never listed -- it never had a bundle to begin with"
GH2="$(mktemp -d)"; GR2="$GH2/repo"; _art_repo "$GR2"
GREMOTE="$GH2/remote.git"; git init -q --bare "$GREMOTE"
git -C "$GR2" remote add origin "$GREMOTE"
cat >"$GH2/destinations.json" <<'JSON'
{"schemaVersion":1,"destinations":[]}
JSON
G2OUT="$(OMABACKUP_REPO_OVERRIDE="$GR2" _art_env "$GH2" artifacts --json)"
assert_eq "$(jq -r '.destinations | length' <<<"$G2OUT")" "0"

# ── unknown flags are refused, same as every other verb ────────────────────
it "artifacts refuses an unknown flag rather than silently ignoring it"
assert_contains "$(_art_env "$NH" artifacts --apply)" "unknown flag"

# ── review round: a pipeline that extracted fine and THEN failed ───────────
# _artifact_manifest sets pipefail specifically so a zstd failure downstream
# of tar is observed -- but the caller was not reading that status, only the
# bytes. A valid zstd frame with garbage appended extracts manifest.json in
# full and only afterward fails: `restore` itself refuses this exact file as
# unextractable, so reporting it here as valid:true would be the worst
# possible order for a restore-picking list.
CH="$(mktemp -d)"; CR="$CH/repo"; _art_repo "$CR"
CNAS="$CH/nas"
cat >"$CH/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"nas","type":"dir","path":"$CNAS","keep":3}]}
JSON
OMABACKUP_REPO_OVERRIDE="$CR" _art_env "$CH" push nas >/dev/null
CFILE="$(command find "$CNAS" -name '*.tar.zst')"
printf 'trailing garbage appended after a valid zstd frame\n' >>"$CFILE"
COUT="$(OMABACKUP_REPO_OVERRIDE="$CR" _art_env "$CH" artifacts --json)"

it "a valid frame with trailing garbage is marked invalid, not valid:true"
assert_eq "$(jq -r '.destinations[0].artifacts[0].valid' <<<"$COUT")" "false"

it "and the message names it as a corrupt archive, distinct from an unreadable manifest"
assert_contains "$(jq -r '.destinations[0].artifacts[0].error' <<<"$COUT")" "extract cleanly"

# ── review round: a filename holding the TSV's own delimiter ───────────────
# A `dir` destination is a mount shared with other processes by this
# project's own threat model; a tab in a filename here used to make ONE
# artifact vanish from the list while the destination still reported
# state:"ok" -- worse than an honest list-failed, because it looked clean.
TBH="$(mktemp -d)"
TBNAS="$TBH/nas"; mkdir -p "$TBNAS"
TBNAME=$'omabackup-ta\tb-20200101-000000-aaaaaaaaaaaa.tar.zst'
touch "$TBNAS/$TBNAME"
cat >"$TBH/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"nas","type":"dir","path":"$TBNAS","keep":5}]}
JSON
TBOUT="$(_art_env "$TBH" artifacts --json)"

it "a filename containing a tab is not silently dropped from the listing"
assert_eq "$(jq -r '.destinations[0].artifacts | length' <<<"$TBOUT")" "1"

it "and the destination is still state ok, not a degraded read pretending to be clean"
assert_eq "$(jq -r '.destinations[0].state' <<<"$TBOUT")" "ok"

# ── review round: a filename holding a newline ──────────────────────────────
# One file with an embedded newline in its name used to become THREE bogus
# records in the list (the newline read as if it ended the row).
NLH="$(mktemp -d)"
NLNAS="$NLH/nas"; mkdir -p "$NLNAS"
NLNAME=$'omabackup-a\nb-20200101-000000-cccccccccccc.tar.zst'
touch "$NLNAS/$NLNAME"
cat >"$NLH/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"nas","type":"dir","path":"$NLNAS","keep":5}]}
JSON
NLOUT="$(_art_env "$NLH" artifacts --json)"

it "a filename containing a newline produces exactly one record, not several"
assert_eq "$(jq -r '.destinations[0].artifacts | length' <<<"$NLOUT")" "1"

# ── review round: an unparseable destinations.json must not look like "none" ─
# dest_ids degrades to an empty read when destinations.json fails to parse at
# all -- so "no dir destinations configured" and "could not read
# destinations.json" used to produce the exact same {"destinations":[]}.
BJH="$(mktemp -d)"
printf '{not-json' >"$BJH/destinations.json"
BJOUT="$(_art_env "$BJH" artifacts --json)"; BJRC=$?

it "an unparseable destinations.json makes artifacts fail loudly, not return an empty list"
[[ $BJRC -ne 0 ]] && ok || fail "exited 0 against unparseable destinations.json"

it "and the message says so, distinct from a genuinely empty configuration"
assert_contains "$BJOUT" "could not be read as JSON"

# ── review round: the human-readable form must show what it counts ─────────
# The count above the listing already includes invalid artifacts (a manifest
# that cannot be read does not remove the file from the destination), but the
# listing itself filtered them out -- "(2 artifacts)" over a single visible
# row.
IH="$(mktemp -d)"
INAS="$IH/nas"; mkdir -p "$INAS"
printf 'garbage\n' >"$INAS/omabackup-bad-20200101-000000-dddddddddddd.tar.zst"
cat >"$IH/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"nas","type":"dir","path":"$INAS","keep":3}]}
JSON
IOUT="$(_art_env "$IH" artifacts)"

it "the human-readable listing shows an invalid artifact, not just a count that includes it"
assert_contains "$IOUT" "omabackup-bad-20200101-000000-dddddddddddd.tar.zst"

it "and marks it as invalid rather than presenting it like a normal entry"
assert_contains "$IOUT" "invalid:"

# ── review round: a manifest.json that is valid JSON but the wrong shape ───
# `jq -e .` alone accepts `[]` as valid JSON; the field-projection jq call
# then fails indexing an array with a string, and the entry used to vanish
# from the array silently (jq -s reads a blank array element as whitespace,
# not a parse error) -- the destination stayed "ok" and simply never
# mentioned the file.
WSH="$(mktemp -d)"
WSNAS="$WSH/nas"; mkdir -p "$WSNAS"
WSSTAGE="$(mktemp -d)"
printf '[]' >"$WSSTAGE/manifest.json"
tar -C "$WSSTAGE" -cf - . 2>/dev/null \
    | zstd -q -o "$WSNAS/omabackup-shape-20200101-000000-eeeeeeeeeeee.tar.zst" 2>/dev/null
cat >"$WSH/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"nas","type":"dir","path":"$WSNAS","keep":3}]}
JSON
WSOUT="$(_art_env "$WSH" artifacts --json)"

it "a manifest.json that is valid JSON but the wrong shape does not vanish from the count"
assert_eq "$(jq -r '.destinations[0].artifacts | length' <<<"$WSOUT")" "1"

it "the destination is still ok -- one wrongly-shaped file does not hide the others"
assert_eq "$(jq -r '.destinations[0].state' <<<"$WSOUT")" "ok"

it "and the file itself is explicitly invalid, not silently absent"
assert_eq "$(jq -r '.destinations[0].artifacts[0].valid' <<<"$WSOUT")" "false"

# ── review round: a raw NUL byte inside manifest.json ───────────────────────
# Routed through a bash variable, bash's command substitution silently drops
# everything from the first NUL byte onward -- jq then validated and served
# the TRUNCATED text as valid:true. Reading straight from a file closes this:
# a raw NUL makes the JSON syntactically invalid and jq correctly refuses it.
NUH="$(mktemp -d)"
NUNAS="$NUH/nas"; mkdir -p "$NUNAS"
NUSTAGE="$(mktemp -d)"
printf '{"host":"nul' >"$NUSTAGE/manifest.json"
printf '\0' >>"$NUSTAGE/manifest.json"
printf '"}' >>"$NUSTAGE/manifest.json"
tar -C "$NUSTAGE" -cf - . 2>/dev/null \
    | zstd -q -o "$NUNAS/omabackup-nul-20200101-000000-ffffffffffff.tar.zst" 2>/dev/null
cat >"$NUH/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"nas","type":"dir","path":"$NUNAS","keep":3}]}
JSON
NUOUT="$(_art_env "$NUH" artifacts --json)"

it "a manifest.json containing a raw NUL byte is rejected, not silently truncated and accepted"
assert_eq "$(jq -r '.destinations[0].artifacts[0].valid' <<<"$NUOUT")" "false"

# ── review round: an unmounted drive's empty mountpoint is not "empty" ─────
# A destination that succeeded before (its state file has lastSuccess) but
# whose directory now carries no ownership stamp is very likely the empty
# mountpoint left behind after the real backing device unmounted -- the stamp
# lived on that device, not on the parent filesystem's mountpoint directory.
MPH="$(mktemp -d)"; MPR="$MPH/repo"; _art_repo "$MPR"
MPNAS="$MPH/nas"
cat >"$MPH/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"nas","type":"dir","path":"$MPNAS","keep":3}]}
JSON
OMABACKUP_REPO_OVERRIDE="$MPR" _art_env "$MPH" push nas >/dev/null
rm -rf "$MPNAS"; mkdir -p "$MPNAS"   # simulates: drive unmounted, bare mountpoint left behind
MPOUT="$(OMABACKUP_REPO_OVERRIDE="$MPR" _art_env "$MPH" artifacts --json)"

it "an empty directory with a prior recorded success but no ownership stamp is unreachable, not empty"
assert_eq "$(jq -r '.destinations[0].state' <<<"$MPOUT")" "unreachable"

it "and says why"
assert_contains "$(jq -r '.destinations[0].error' <<<"$MPOUT")" "unmounted"

it "while a destination that was never pushed to is still a genuine empty, not flagged unreachable"
assert_eq "$(jq -r '.destinations[] | select(.id=="empty") | .state' <<<"$SOUT")" "empty"

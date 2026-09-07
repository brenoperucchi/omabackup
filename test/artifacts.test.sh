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

# ── review round omabackup-41 (`omabackup-rev`): timeout/head were never
# declared as required tools, even though _artifact_manifest_file (this same
# round's own byte-cap/timeout fix) depends on both -- a system missing
# either made every manifest read look like a corrupt archive instead of the
# CLI naming the actual missing dependency ─────────────────────────────────
DEPH="$(mktemp -d)"
DEPPATH="$(mktemp -d)"
for t in bash jq find zstd tar sh env cat printf mktemp grep sed cut basename dirname date wc stat rm mkdir cp mv chmod ls sort id readlink getent hostname; do
    p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$DEPPATH/$(basename "$p")" 2>/dev/null
done
DEPOUT="$(PATH="$DEPPATH" HOME="$DEPH" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$PWD/groups.default.json" \
    OMABACKUP_STATE="$DEPH/.state" XDG_RUNTIME_DIR=/nonexistent "$OB" artifacts 2>&1)"

it "artifacts reports missing timeout/head as a dependency error, not a corrupt-archive symptom"
assert_contains "$DEPOUT" "missing required tool"
assert_contains "$DEPOUT" "timeout"
assert_contains "$DEPOUT" "head"

# Found by review (round omabackup-42, `omabackup-rev-2`): timeout/head are
# coreutils, not packages under their own binary name -- `_pkg_for`'s
# fallback echoed the bare tool name, so the install hint above would have
# read "pacman -S timeout", a package that does not exist.
it "and names the real installable package (coreutils), not the bare binary name"
assert_contains "$DEPOUT" "coreutils"
assert_not_contains "$DEPOUT" "pacman -S timeout head"

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

# ── marketplace security review, 2026-09-06: a decompression bomb in the
# LISTING path, not just restore's own extraction ──────────────────────────
# https://github.com/omacom/omarchy-plugin-marketplace/issues/3968#issuecomment-5560428690:
# _artifact_manifest_file ran `zstd -dc | tar -xO` over every matching file in
# a `dir` destination -- a mount this tool shares with other processes by
# design -- with no bound of its own. _zstd_extract (lib/bundle.sh) already
# closed the identical shape for restore's own extraction; this proves the
# listing path is now bounded the same way. A real bomb: 50MB of a repeated
# byte named exactly `manifest.json` compresses to a few KB. Note this is NOT
# proven by "valid:false" alone -- non-JSON content fails jq's own shape check
# regardless of whether the byte cap did anything, so that alone cannot tell
# a bounded read from an unbounded one that happened to reject the content
# for an unrelated reason. The real proof is direct, same shape as
# lib/bundle.sh's own bomb test: call _artifact_manifest_file itself and
# measure what it actually wrote.
BOMBASTAGE="$(mktemp -d)"
head -c 50000000 /dev/zero | tr '\0' 'a' >"$BOMBASTAGE/manifest.json"
BOMBARCHIVE="$(mktemp -d)/bomb.tar.zst"
tar -C "$BOMBASTAGE" -cf - . 2>/dev/null | zstd -q -19 -o "$BOMBARCHIVE" 2>/dev/null

it "a manifest.json decompression bomb really does compress to far less than it expands to"
BOMBAFULLSIZE="$(zstd -dc "$BOMBARCHIVE" 2>/dev/null | tar -xO ./manifest.json 2>/dev/null | wc -c)"
(( $(stat -c %s "$BOMBARCHIVE") < 10000 && BOMBAFULLSIZE > 40000000 )) \
    && ok || fail "bomb fixture is not actually lopsided: archive=$(stat -c %s "$BOMBARCHIVE") decompressed=$BOMBAFULLSIZE"

# ARTIFACT_MANIFEST_MAX_BYTES is computed once when lib/artifacts.sh is
# sourced -- same pattern lib/bundle.sh's own BUNDLE_EXTRACT_MAX_BYTES test
# already establishes -- so the override has to be in the environment BEFORE
# that source line, not prefixed onto the function call after it.
BOMBAOUTFILE="$(mktemp -d)/manifest.json"
BOMBARC="$(OMABACKUP_ARTIFACT_MANIFEST_MAX_BYTES=1000000 bash -c '
    source lib/artifacts.sh
    _artifact_manifest_file "$1" "$2"
    printf %s $?
' _ "$BOMBARCHIVE" "$BOMBAOUTFILE")"

it "_artifact_manifest_file refuses to let the decompressed stream exceed OMABACKUP_ARTIFACT_MANIFEST_MAX_BYTES"
[[ "$BOMBARC" != 0 ]] && ok || fail "expected a non-zero return for an oversized decompressed stream"

it "and the written file stays bounded near the cap, not the archive's full 50MB payload"
BOMBAWRITTEN="$(stat -c %s "$BOMBAOUTFILE" 2>/dev/null || echo 0)"
(( BOMBAWRITTEN < 2000000 )) \
    && ok || fail "expected well under 2MB written for a 1MB cap, got $BOMBAWRITTEN bytes"

# End-to-end: the same bomb, at the DEFAULT 1 MiB cap, through the real CLI --
# proves the bound is actually wired into the listing path a user hits, not
# just reachable by calling the internal function directly.
BOMBAH="$(mktemp -d)"
BOMBANAS="$BOMBAH/nas"; mkdir -p "$BOMBANAS"
cp "$BOMBARCHIVE" "$BOMBANAS/omabackup-bomb-20200101-000000-bbbbbbbbbbbb.tar.zst"
cat >"$BOMBAH/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"nas","type":"dir","path":"$BOMBANAS","keep":3}]}
JSON
BOMBAOUT="$(_art_env "$BOMBAH" artifacts --json)"

it "artifacts --json marks the bomb artifact invalid through the real CLI, at the default cap"
assert_eq "$(jq -r '.destinations[0].artifacts[0].valid' <<<"$BOMBAOUT")" "false"

# ── review round omabackup-41 (both reviewers, independently): the first fix
# above put the byte cap on the WRONG side of tar, rejecting a perfectly
# legitimate large bundle whose own manifest.json happens to sit past 1 MiB
# in the decompressed tar stream ──────────────────────────────────────────
# A real bundle's own total size is unbounded on purpose (lib/bundle.sh's
# build_bundle includes the whole repo.bundle -- the dotfiles repo's full git
# history, which only grows) and `tar -C stage -cf - .` has no `--sort`, so
# manifest.json's own position is whatever readdir happens to return, not
# something this project controls. Neither prior test caught this: the bomb
# fixture's own manifest.json IS the oversized content, at offset 0 -- this
# fixture is a genuinely small, valid manifest sitting AFTER 2MB of unrelated
# content, well past the 1 MiB default cap, proving the cap bounds what tar
# extracts, not how far it may read to find the member.
LATEH="$(mktemp -d)"
LATESTAGE="$(mktemp -d)"
head -c 2000000 /dev/urandom >"$LATESTAGE/aaa-bigfile.bin"
printf '{"host":"late-manifest","createdAt":"2026-09-06T00:00:00Z"}' >"$LATESTAGE/zzz-manifest.json"
mv "$LATESTAGE/zzz-manifest.json" "$LATESTAGE/manifest.json"
LATEARCHIVE="$(mktemp -d)/late.tar.zst"
tar -C "$LATESTAGE" -cf - . 2>/dev/null | zstd -q -o "$LATEARCHIVE" 2>/dev/null

it "a legitimate bundle whose own total size exceeds the cap still extracts its (small) manifest"
LATEOUTFILE="$(mktemp -d)/manifest.json"
LATERC="$(bash -c '
    source lib/artifacts.sh
    _artifact_manifest_file "$1" "$2"
    printf %s $?
' _ "$LATEARCHIVE" "$LATEOUTFILE")"
[[ "$LATERC" == 0 ]] && ok || fail "expected rc=0 for a legitimate bundle with a late manifest, got $LATERC"
jq -e . "$LATEOUTFILE" >/dev/null 2>&1 && ok || fail "expected valid JSON in the extracted manifest"

LATEH_NAS="$LATEH/nas"; mkdir -p "$LATEH_NAS"
cp "$LATEARCHIVE" "$LATEH_NAS/omabackup-late-20200101-000000-cccccccccccc.tar.zst"
cat >"$LATEH/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"nas","type":"dir","path":"$LATEH_NAS","keep":3}]}
JSON
LATEOUT="$(_art_env "$LATEH" artifacts --json)"

it "and artifacts --json reports it valid:true through the real CLI, not vanished from the list"
assert_eq "$(jq -r '.destinations[0].artifacts[0].valid' <<<"$LATEOUT")" "true"
assert_eq "$(jq -r '.destinations[0].artifacts[0].host' <<<"$LATEOUT")" "late-manifest"

# ── review round: a valid frame with trailing garbage must still be rejected
# even without --occurrence=1 (the addition considered and rejected above) --
# zstd runs to completion regardless of where in the archive tar's own
# target member sits, so it still independently reports the corruption it
# finds on its own. Not a new scenario -- the existing "trailing garbage"
# test earlier in this file already covers it end to end; this is a direct,
# low-level confirmation that the reordered pipe didn't quietly break it.
it "trailing garbage after a valid frame is still rejected by the reordered pipe"
GARBAGEH="$(mktemp -d)"
printf '{"host":"x"}' >"$GARBAGEH/manifest.json"
GARBAGEARCHIVE="$(mktemp -d)/garbage.tar.zst"
tar -C "$GARBAGEH" -cf - . 2>/dev/null | zstd -q -o "$GARBAGEARCHIVE" 2>/dev/null
printf 'trailing garbage' >>"$GARBAGEARCHIVE"
GARBAGERC="$(bash -c '
    source lib/artifacts.sh
    _artifact_manifest_file "$1" "$2"
    printf %s $?
' _ "$GARBAGEARCHIVE" "$(mktemp -d)/manifest.json")"
[[ "$GARBAGERC" != 0 ]] && ok || fail "expected a non-zero return for trailing garbage after a valid frame, got $GARBAGERC"

# ── review round omabackup-42 (`omabackup-rev`): the pipe's own exit status
# cannot detect truncation right at the cap boundary ────────────────────────
# Whether `head -c` cutting the stream reaches back as a SIGPIPE through
# tar/zstd depends on pipe-buffer timing, not just on whether the content
# truly exceeds the cap -- confirmed live: a manifest exactly cap+1 bytes
# long, whose truncated cap-byte PREFIX happens to still read as complete,
# valid JSON on its own, produced pipestatus 0 0 0 (no SIGPIPE anywhere) and
# was accepted as valid despite genuinely exceeding the configured limit.
# This is a small cap deliberately, not the real 1 MiB default, so the test
# fixture stays cheap.
EDGEOUTFILE="$(mktemp -d)/manifest.json"
EDGEARCHIVE="$(mktemp -d)/edge.tar.zst"
EDGESTAGE="$(mktemp -d)"
python3 -c "
import json
cap = 1000
obj = json.dumps({'host': 'x'})
pad = 'a' * (cap - len(obj))
content = obj[:-1] + pad + obj[-1] + 'X'  # exactly cap+1 bytes; first cap bytes alone are valid JSON
assert len(content) == cap + 1
open('$EDGESTAGE/manifest.json', 'w').write(content)
"
tar -C "$EDGESTAGE" -cf - . 2>/dev/null | zstd -q -o "$EDGEARCHIVE" 2>/dev/null
EDGERC="$(OMABACKUP_ARTIFACT_MANIFEST_MAX_BYTES=1000 bash -c '
    source lib/artifacts.sh
    _artifact_manifest_file "$1" "$2"
    printf %s $?
' _ "$EDGEARCHIVE" "$EDGEOUTFILE")"

it "a manifest exactly one byte past the cap is rejected, even when no SIGPIPE ever fires"
[[ "$EDGERC" != 0 ]] && ok || fail "expected a non-zero return for content exactly cap+1 bytes long, got $EDGERC"

it "and a manifest exactly AT the cap (not one byte over) is still accepted"
AT_CAP_OUTFILE="$(mktemp -d)/manifest.json"
AT_CAP_ARCHIVE="$(mktemp -d)/atcap.tar.zst"
AT_CAP_STAGE="$(mktemp -d)"
python3 -c "
import json
cap = 1000
obj = json.dumps({'host': 'x'})
content = obj[:-1] + 'a' * (cap - len(obj)) + obj[-1]  # exactly cap bytes, valid JSON
assert len(content) == cap
open('$AT_CAP_STAGE/manifest.json', 'w').write(content)
"
tar -C "$AT_CAP_STAGE" -cf - . 2>/dev/null | zstd -q -o "$AT_CAP_ARCHIVE" 2>/dev/null
AT_CAP_RC="$(OMABACKUP_ARTIFACT_MANIFEST_MAX_BYTES=1000 bash -c '
    source lib/artifacts.sh
    _artifact_manifest_file "$1" "$2"
    printf %s $?
' _ "$AT_CAP_ARCHIVE" "$AT_CAP_OUTFILE")"
[[ "$AT_CAP_RC" == 0 ]] && ok || fail "expected rc=0 for content exactly at the cap (not over it), got $AT_CAP_RC"

# ── review round omabackup-43 (`omabackup-rev`): unvalidated arithmetic on
# a user-supplied cap can silently reproduce the exact head-c-negative-count
# bug this project already closed once for OMABACKUP_RESTORE_MAX_BYTES --
# `$(( CAP + 1 ))` on a CAP near bash's signed 64-bit boundary wraps negative,
# and GNU `head -c` treats a negative count as "all but the last N bytes" ──
AM_OVERFLOW_VAL="$(OMABACKUP_ARTIFACT_MANIFEST_MAX_BYTES=18446744073709551614 bash -c '
    source lib/artifacts.sh
    printf %s "$ARTIFACT_MANIFEST_MAX_BYTES"
')"

it "an OMABACKUP_ARTIFACT_MANIFEST_MAX_BYTES near the 64-bit boundary falls back to the safe default instead of wrapping negative"
assert_eq "$AM_OVERFLOW_VAL" "1048576"

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

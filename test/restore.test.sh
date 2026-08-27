# Restore -- the verb the whole product exists for, and the one that was
# missing until now. Everything else moves data off this machine; this is what
# brings it back, and DESIGN.md §12.2 is why it is not a plain extraction.

OB="$PWD/bin/omabackup"

# A repo in the layout publish writes, and a manifest describing where each
# piece came from. Restore reads the manifest the ARTIFACT carries, so the one
# named here is the one that will drive it.
_res_repo() {
    local r="$1"
    mkdir -p "$r/configs/alacritty" "$r/configs/hypr" "$r/state/omarchy"
    git init -q "$r"
    git -C "$r" config user.email t@t
    git -C "$r" config user.name t
    printf 'font = "berkeley"\n' >"$r/configs/alacritty/alacritty.toml"
    printf 'bind = SUPER, Q\n'   >"$r/configs/hypr/bindings.conf"
    printf 'tokyo-night\n'       >"$r/state/omarchy/theme"
    git -C "$r" add -A && git -C "$r" commit -qm one
}

_res_manifest() {  # _res_manifest <file> <targets-json>
    cat >"$1" <<JSON
{"schemaVersion":1,"supportedTargets":$2,"groups":[
 {"id":"terminal","label":"Terminal","mode":"copy","coupled":false,"critical":false,
  "paths":["~/.config/alacritty"]},
 {"id":"compositor","label":"Compositor","mode":"copy","coupled":true,"critical":true,
  "paths":["~/.config/hypr"]},
 {"id":"state","label":"State","mode":"copy","coupled":true,"critical":false,
  "paths":["~/.local/state/omarchy"]}]}
JSON
}

_res_build() {  # _res_build <dir> <targets-json> -> prints the artifact path
    local d="$1" t="$2"
    _res_repo "$d/repo" >/dev/null 2>&1
    _res_manifest "$d/g.json" "$t"
    mkdir -p "$d/home"
    HOME="$d/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$d/g.json" \
        OMABACKUP_STATE="$d/home/.state" OMABACKUP_REPO="$d/repo" \
        XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
    ls -t "$d/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1
}

_res_run() {  # _res_run <target-home> <state> <args...>
    local h="$1" st="$2"; shift 2
    HOME="$h" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$st" \
        XDG_RUNTIME_DIR=/nonexistent "$OB" restore "$@" 2>&1
}

RH="$(mktemp -d)"
RART="$(_res_build "$RH" '["3.*","4.*"]')"

it "the fixture produced a real artifact"
[[ -n "$RART" && -f "$RART" ]] && ok || fail "no artifact was built"

# ── a plan writes nothing ───────────────────────────────────────────────────
RTGT="$(mktemp -d)"
RPLAN="$(_res_run "$RTGT" "$RH/rstate" "$RART")"

it "a plan says what it would restore"
assert_contains "$RPLAN" "would be restored"

it "and names the files, not just a count"
assert_contains "$RPLAN" "alacritty.toml"

it "and having said it, has written nothing"
assert_eq "$(find "$RTGT" -type f 2>/dev/null | wc -l)" "0"

it "and points at the flag that would do it"
assert_contains "$RPLAN" "restore"

# ── apply ───────────────────────────────────────────────────────────────────
_res_run "$RTGT" "$RH/rstate" "$RART" --apply >/dev/null 2>&1

it "--apply puts an uncoupled file back where it came from"
assert_eq "$(cat "$RTGT/.config/alacritty/alacritty.toml" 2>/dev/null)" 'font = "berkeley"'

it "and the coupled one too, this machine being in range"
assert_eq "$(cat "$RTGT/.config/hypr/bindings.conf" 2>/dev/null)" 'bind = SUPER, Q'

it "including the state group, which lives outside .config"
assert_eq "$(cat "$RTGT/.local/state/omarchy/theme" 2>/dev/null)" 'tokyo-night'

# ── what it replaces, it keeps ──────────────────────────────────────────────
printf 'my own edit\n' >"$RTGT/.config/alacritty/alacritty.toml"
_res_run "$RTGT" "$RH/kept" "$RART" --apply >/dev/null 2>&1
RKEPT="$(find "$RH/kept/restore" -path '*replaced*' -name 'alacritty.toml' 2>/dev/null | head -1)"

it "a file it overwrites is kept first"
[[ -n "$RKEPT" ]] && ok || fail "nothing was kept"

it "and what was kept is what was there, not what replaced it"
assert_eq "$(cat "$RKEPT" 2>/dev/null)" "my own edit"

it "two restores do not share one place to keep originals"
_res_run "$RTGT" "$RH/twice" "$RART" --apply >/dev/null 2>&1
_res_run "$RTGT" "$RH/twice" "$RART" --apply >/dev/null 2>&1
assert_eq "$(ls "$RH/twice/restore" 2>/dev/null | wc -l)" "2"

# ── the quarantine, which is the reason §12 reorganised the product ─────────
# An artifact that declares it can only be restored onto Omarchy 3 has nothing
# to say about a machine running 4: its coupled groups are held, not applied.
# August's failure -- a .conf config restored onto an Omarchy that reads .lua
# -- becomes impossible here rather than merely unlikely.
QH="$(mktemp -d)"
QART="$(_res_build "$QH" '["3.*"]')"
QTGT="$(mktemp -d)"
QPLAN="$(_res_run "$QTGT" "$QH/rstate" "$QART")"

it "an out-of-range artifact says so, with the range in the sentence"
assert_contains "$QPLAN" "3.*"

it "and quarantines rather than restores the coupled groups"
assert_contains "$QPLAN" "quarantined"

_res_run "$QTGT" "$QH/rstate" "$QART" --apply >/dev/null 2>&1

it "applying it still restores the uncoupled group"
assert_eq "$(cat "$QTGT/.config/alacritty/alacritty.toml" 2>/dev/null)" 'font = "berkeley"'

it "but the coupled one is not placed"
[[ ! -e "$QTGT/.config/hypr/bindings.conf" ]] \
    && ok || fail "applied a coupled group onto a machine outside the declared range"

it "it is held somewhere the human can find it"
[[ -n "$(find "$QH/rstate/restore" -path '*quarantine*' -name 'bindings.conf' 2>/dev/null)" ]] \
    && ok || fail "quarantined it into nowhere"

# ── the artifact has to answer for itself first ─────────────────────────────
# Corrupted inside the checksummed content, not truncated: a truncated .tar.zst
# breaks zstd's own frame and fails at EXTRACTION, one refusal earlier than the
# one this spec means to exercise. Decompressed, one byte flipped inside a
# checksummed file, recompressed -- SHA256SUMS then disagrees with what is on
# disk, which is what "does not verify" actually means.
RBAD="$RH/broken.tar.zst"
RBADX="$(mktemp -d)"
tar -C "$RBADX" -xf <(zstd -dc "$RART")
printf 'tampered\n' >>"$RBADX/RESTORE.md"
tar -C "$RBADX" -cf - . | zstd -q -19 -T0 -o "$RBAD"

it "an artifact that fails its own checks is refused"
_res_run "$RTGT" "$RH/rstate" "$RBAD" >/dev/null 2>&1 \
    && fail "restored from an artifact that does not verify" || ok

it "and says the artifact is why, not something vague"
assert_contains "$(_res_run "$RTGT" "$RH/rstate" "$RBAD")" "does not verify"

it "an artifact that is not there is named as missing"
assert_contains "$(_res_run "$RTGT" "$RH/rstate" "$RH/nothing.tar.zst")" "no such artifact"

it "two artifacts are refused, one of them would be silently lost"
assert_contains "$(_res_run "$RTGT" "$RH/rstate" "$RART" "$RART")" "not two"

it "an unknown flag is refused rather than ignored"
assert_contains "$(_res_run "$RTGT" "$RH/rstate" "$RART" --force)" "unknown flag"

# ── a declared path that reads past $HOME ────────────────────────────────────
# `~/../<mark>/evil.conf` expands to a sibling of $HOME rather than anything
# inside it. The case that recurses at *) in _restore_repo_prefix runs on the
# REPO-side prefix, not on this -- the escape only shows up once the live path
# is expanded and joined, which is where it is now caught.
#
# The escaped-to name is unique to this run (derived from the mktemp
# directory), not a fixed name like "etc": every `..` from a /tmp/tmp.XXXX
# home collapses to the SAME /tmp, so a fixed name is shared across every run
# of this suite and every parallel one. Run once against the pre-fix code, a
# fixed name leaves a REAL file at that fixed path forever after -- which is
# exactly what happened proving this defect exists.
ESCH="$(mktemp -d)"; ESCR="$ESCH/repo"
ESCMARK="restore-escape-$(basename "$ESCH")"
mkdir -p "$ESCR/$ESCMARK" "$ESCR/dotfiles"
git init -q "$ESCR"; git -C "$ESCR" config user.email t@t; git -C "$ESCR" config user.name t
printf 'PWNED\n' >"$ESCR/$ESCMARK/evil.conf"
# The prefix _restore_repo_prefix computes for "~/../<mark>" with no
# trackedRepoPath is "dotfiles/../<mark>" -- git tracks no empty directories,
# so without a file in dotfiles/ the extracted worktree would not even HAVE
# that directory, and `dotfiles/../<mark>` could not resolve at all.
printf 'unrelated\n' >"$ESCR/dotfiles/placeholder"
git -C "$ESCR" add -A && git -C "$ESCR" commit -qm one
cat >"$ESCH/g.json" <<JSON
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"esc","label":"Escape","mode":"copy","coupled":false,"critical":false,
  "paths":["~/../$ESCMARK"]}]}
JSON
mkdir -p "$ESCH/home"
HOME="$ESCH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$ESCH/g.json" \
    OMABACKUP_STATE="$ESCH/home/.state" OMABACKUP_REPO="$ESCR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
ESCART="$(ls -t "$ESCH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
ESCTGT="$(mktemp -d)"
ESCPLAN="$(_res_run "$ESCTGT" "$ESCH/rstate" "$ESCART")"

it "an escaping path is refused in the plan, not silently placed"
assert_contains "$ESCPLAN" "refused"

it "and it is not counted as something that would be restored"
assert_contains "$ESCPLAN" "0 files would be restored"

_res_run "$ESCTGT" "$ESCH/rstate" "$ESCART" --apply >/dev/null 2>&1
ESCAPPLYRC=$?

it "and --apply writes nothing for it, inside the target"
[[ ! -e "$ESCTGT/../$ESCMARK/evil.conf" ]] && ok || fail "wrote past the target home"

it "and --apply's own exit status says so -- an all-escape restore is not success"
[[ $ESCAPPLYRC -ne 0 ]] && ok || fail "exited 0 on a restore where everything was refused"

it "nor anywhere else on the machine"
[[ ! -f "/tmp/$ESCMARK/evil.conf" && ! -f "$(dirname "$ESCTGT")/$ESCMARK/evil.conf" ]] \
    && ok || fail "the escape landed somewhere real"
rm -rf "$(dirname "$ESCTGT")/$ESCMARK" "/tmp/$ESCMARK" 2>/dev/null

# ── a symlinked parent directory escapes --into the same way `..` does ──────
# --into only reassigns $HOME; it never inspects what is already on disk at the
# target. A directory inside it that is itself a symlink to somewhere else is
# followed by mkdir -p and by cp exactly like it would be for the real HOME.
SYMH="$(mktemp -d)"
SYMART="$(_res_build "$SYMH" '["3.*","4.*"]')"
SYMTGT="$(mktemp -d)/target"; mkdir -p "$SYMTGT"
SYMOUTSIDE="$(mktemp -d)/outside"; mkdir -p "$SYMOUTSIDE"
ln -s "$SYMOUTSIDE" "$SYMTGT/.config"
_res_run "$SYMTGT" "$SYMH/rstate" "$SYMART" --apply >/dev/null 2>&1

it "restoring through a symlinked parent does not write outside the target"
[[ ! -e "$SYMOUTSIDE/alacritty/alacritty.toml" ]] \
    && ok || fail "wrote through the symlink into $SYMOUTSIDE"

# ── two different groups sharing one flat repo destination ──────────────────
# The collision map used to be rebuilt per group and reset between them, so it
# only ever saw one group's own declared paths -- never noticing that two
# DIFFERENT groups both named the same trackedRepoPath.
COLH="$(mktemp -d)"; COLR="$COLH/repo"
mkdir -p "$COLR/shared"
git init -q "$COLR"; git -C "$COLR" config user.email t@t; git -C "$COLR" config user.name t
printf 'one\n' >"$COLR/shared/a.txt"
git -C "$COLR" add -A && git -C "$COLR" commit -qm one
cat >"$COLH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"g1","label":"G1","mode":"copy","coupled":false,"critical":false,
  "paths":[{"live":"~/.config/one","trackedRepoPath":"shared"}]},
 {"id":"g2","label":"G2","mode":"copy","coupled":false,"critical":false,
  "paths":[{"live":"~/.config/two","trackedRepoPath":"shared"}]}]}
JSON
mkdir -p "$COLH/home"
HOME="$COLH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$COLH/g.json" \
    OMABACKUP_STATE="$COLH/home/.state" OMABACKUP_REPO="$COLR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
COLART="$(ls -t "$COLH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
COLTGT="$(mktemp -d)"
COLPLAN="$(_res_run "$COLTGT" "$COLH/rstate" "$COLART")"

it "a destination two different groups both claim is flagged ambiguous"
assert_contains "$COLPLAN" "ambiguous"

it "and it is not restored to either group's directory"
_res_run "$COLTGT" "$COLH/rstate" "$COLART" --apply >/dev/null 2>&1
[[ ! -e "$COLTGT/.config/one/a.txt" && ! -e "$COLTGT/.config/two/a.txt" ]] \
    && ok || fail "an ambiguous file was placed somewhere anyway"

# ── the migration markers, on a forward restore ──────────────────────────────
# _restore_verdict said "the markers do not apply" while restore_rows applied
# every file in the coupled `state` group regardless -- comment and code
# disagreeing, in the one command that writes to the home directory.
FWH="$(mktemp -d)"; FWR="$FWH/repo"
mkdir -p "$FWR/state/omarchy/migrations"
git init -q "$FWR"; git -C "$FWR" config user.email t@t; git -C "$FWR" config user.name t
printf 'old\n' >"$FWR/state/omarchy/migrations/1700000000.sh"
printf 'x\n' >"$FWR/state/omarchy/theme"
git -C "$FWR" add -A && git -C "$FWR" commit -qm one
cat >"$FWH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"state","label":"State","mode":"copy","coupled":true,"critical":false,
  "paths":["~/.local/state/omarchy"]}]}
JSON
mkdir -p "$FWH/home"
HOME="$FWH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$FWH/g.json" \
    OMABACKUP_STATE="$FWH/home/.state" OMABACKUP_REPO="$FWR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
FWART="$(ls -t "$FWH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
FWTGT="$(mktemp -d)"
mkdir -p "$FWTGT/.local/state/omarchy/migrations"
touch "$FWTGT/.local/state/omarchy/migrations/1800000000.sh"
FWPLAN="$(_res_run "$FWTGT" "$FWH/rstate" "$FWART")"

it "on a forward restore, the plan says the marker is held"
assert_contains "$FWPLAN" "held"

_res_run "$FWTGT" "$FWH/rstate" "$FWART" --apply >/dev/null 2>&1

it "and --apply really does not write the old marker back"
[[ ! -e "$FWTGT/.local/state/omarchy/migrations/1700000000.sh" ]] \
    && ok || fail "restored a migration marker on a forward move, contradicting the plan's own claim"

it "while the rest of the coupled group still applies"
assert_eq "$(cat "$FWTGT/.local/state/omarchy/theme" 2>/dev/null)" 'x'

# ── behind: fewer migrations than the backup, still in range ────────────────
# The first version quarantined this -- an analogy to a downgrade -- and that
# quarantined the primary recovery scenario: a fresh machine (watermark 0,
# because the migrations directory does not exist yet) restoring a valid,
# same-version backup. The markers that would fix the watermark lived inside
# the very block that got quarantined, so a second run gave the same verdict
# forever.
BHH="$(mktemp -d)"; BHRAW="$(_res_build "$BHH" '["4.*"]')"
# This test machine's own watermark is 0 (no real migrations directory here),
# so a backup built on it also carries 0 -- the tm<bm branch never triggers
# without a backup that genuinely claims to be ahead. The manifest is edited
# after the fact to say so, and SHA256SUMS is recomputed over the edit.
BHX="$(mktemp -d)"; tar -C "$BHX" -xf <(zstd -dc "$BHRAW")
jq '.omarchy.migrationWatermark = "1700000000"' "$BHX/manifest.json" >"$BHX/manifest.json.new"
mv "$BHX/manifest.json.new" "$BHX/manifest.json"
( cd "$BHX" && find . -type f ! -name SHA256SUMS -print0 | xargs -0 sha256sum >SHA256SUMS )
BHART="$BHH/ahead.tar.zst"
tar -C "$BHX" -cf - . | zstd -q -19 -T0 -o "$BHART"
BHTGT="$(mktemp -d)"
BHPLAN="$(_res_run "$BHTGT" "$BHH/rstate" "$BHART")"

it "a fresh machine behind the backup's watermark is not quarantined"
[[ "$BHPLAN" != *"quarantined"* ]] && ok || fail "quarantined the primary recovery scenario: $BHPLAN"

it "the coupled group is offered for restore instead"
assert_contains "$BHPLAN" "would be restored"

_res_run "$BHTGT" "$BHH/rstate" "$BHART" --apply >/dev/null 2>&1

it "and applying it restores the coupled group, markers included"
assert_eq "$(cat "$BHTGT/.config/hypr/bindings.conf" 2>/dev/null)" 'bind = SUPER, Q'

# ── an unreadable manifest mid-plan is a refusal, not a quiet default ───────
# group_field's status was never checked. Its jq degrades to an empty string
# on a query that finds nothing, which is correct for a normal group -- but on
# a manifest jq cannot read at all, the SAME empty string used to mean "not
# coupled", and a quarantine verdict silently restored a coupled group instead
# of holding it.
GFH="$(mktemp -d)"; GFART="$(_res_build "$GFH" '["3.*"]')"
# A manifest that fails to PARSE used to be refused one gate earlier, by
# _verify_extracted's own bundled status --json self-check reading the exact
# same file -- but that self-check no longer runs on the restore path at all
# (restore always passes run-embedded=0, see lib/bundle.sh), so a genuinely
# unparseable tool/groups.default.json now DOES reach restore_rows directly;
# see the "a manifest restore_rows cannot even PARSE" block below for that
# exact shape. What THIS fixture needs is narrower: one QUERY failing (a
# transient jq crash, a read hiccup) while the file itself is fine and every
# other query on it succeeds -- which a stub jq that fails only on the exact
# `coupled` query reproduces without touching the file at all.
mkdir -p "$GFH/stub"
{ printf '#!/bin/bash\n'
  printf 'for a in "$@"; do [[ "$a" == coupled ]] && exit 9; done\n'
  printf 'exec %s "$@"\n' "$(command -v jq)"
} >"$GFH/stub/jq"; chmod +x "$GFH/stub/jq"

it "a manifest restore_rows cannot query refuses to plan, rather than defaulting"
GFTGT="$(mktemp -d)"
HOME="$GFTGT" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$GFH/rstate" \
    PATH="$GFH/stub:$PATH" XDG_RUNTIME_DIR=/nonexistent "$OB" restore "$GFART" --apply >/dev/null 2>&1 \
    && fail "restored using coupled/quarantine defaults from a query it could not answer" || ok

it "and specifically: nothing from the coupled group is written"
[[ ! -e "$GFTGT/.config/hypr/bindings.conf" ]] \
    && ok || fail "a coupled file was written despite the coupled query failing"

# ── a manifest restore_rows cannot even PARSE refuses, not "0 files" ────────
# groups_ids/group_paths fed a process substitution directly -- `while read
# ... done < <(groups_ids)` -- and a process substitution's exit status is
# not observable at the `done` that closes it: jq failing on a genuinely
# malformed tool/groups.default.json produced no output, the while loop ran
# zero times, restore_rows returned 0 with zero rows, and "0 files would be
# restored" was printed as fact about an artifact whose manifest could not be
# read at all. Reproduced exactly as found: the artifact's OWN bundled
# groups.default.json replaced with invalid JSON, SHA256SUMS recomputed so it
# stays self-consistent.
PJH="$(mktemp -d)"; PJRAW="$(_res_build "$PJH" '["3.*"]')"
PJX="$(mktemp -d)"; tar -C "$PJX" -xf <(zstd -dc "$PJRAW")
printf '{not valid json' >"$PJX/tool/groups.default.json"
( cd "$PJX" && find . -type f ! -name SHA256SUMS -print0 | xargs -0 sha256sum >SHA256SUMS )
PJART="$PJH/badmanifest.tar.zst"
tar -C "$PJX" -cf - . | zstd -q -19 -T0 -o "$PJART"

it "restore refuses when the artifact's own groups manifest cannot be parsed"
PJTGT="$(mktemp -d)"
HOME="$PJTGT" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$PJH/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore --apply "$PJART" >/dev/null 2>&1 \
    && fail "planned or applied against a manifest it could not parse" || ok

it "and not one byte of the coupled group was written"
[[ ! -e "$PJTGT/.config/hypr/bindings.conf" ]] \
    && ok || fail "a coupled file was written from an unparseable manifest"

# ── plugins: the list and the patches, not just the local plugin trees ──────
# publish also writes an enabled-plugins list and per-plugin patches that no
# declared path points at; nothing here ever looked for them, and a restore
# of an artifact holding only those reported "0 files" and exit 0 with no
# mention that anything existed to act on.
PLH="$(mktemp -d)"; PLR="$PLH/repo"
mkdir -p "$PLR/patches/omarchy-plugins"
git init -q "$PLR"; git -C "$PLR" config user.email t@t; git -C "$PLR" config user.name t
printf 'plugin-a\nplugin-b\n' >"$PLR/lists/omarchy-plugins.txt" 2>/dev/null \
    || { mkdir -p "$PLR/lists"; printf 'plugin-a\nplugin-b\n' >"$PLR/lists/omarchy-plugins.txt"; }
printf 'diff --git a/x b/x\n' >"$PLR/patches/omarchy-plugins/plugin-a.patch"
git -C "$PLR" add -A && git -C "$PLR" commit -qm one
cat >"$PLH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"plugins","label":"Plugins","mode":"triple","coupled":true,"critical":true,
  "paths":["~/.config/omarchy/plugins"]}]}
JSON
mkdir -p "$PLH/home"
HOME="$PLH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$PLH/g.json" \
    OMABACKUP_STATE="$PLH/home/.state" OMABACKUP_REPO="$PLR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
PLART="$(ls -t "$PLH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
PLTGT="$(mktemp -d)"
PLPLAN="$(_res_run "$PLTGT" "$PLH/rstate" "$PLART")"

it "the enabled-plugins list is named, not silently skipped"
assert_contains "$PLPLAN" "omarchy-plugins.txt"

it "and the patch against it is named too"
assert_contains "$PLPLAN" "plugin-a.patch"

# ── restore_rows' own walks discard find's status, same class as scan_files ──
# find's status is checked in scan_files and prune_bundles; the walks inside
# restore_rows (flat, tree, and the plugin-patches listing) still ran through a
# process substitution with nothing reading what find returned. A walk that
# stops partway produces fewer rows, and "N files would be restored" is
# printed as fact about a directory this never finished reading. A real
# permission failure here is caught one gate earlier by _verify_extracted's own
# checksum and diff, which is exactly the shape 4g/4j/4k/5's group_field defect
# took -- so this is reproduced the same way, with a stub that fails on one
# specific call and leaves everything verify touches alone.
mkdir -p "$PLH/stub"
{ printf '#!/bin/bash\n'
  printf 'for a in "$@"; do [[ "$a" == *patches/omarchy-plugins* ]] && exit 1; done\n'
  printf 'exec %s "$@"\n' "$(command -v find)"
} >"$PLH/stub/find"; chmod +x "$PLH/stub/find"

it "a find that fails inside restore_rows refuses to plan, rather than under-reporting"
PLTGT2="$(mktemp -d)"
PATH="$PLH/stub:$PATH" HOME="$PLTGT2" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$PLH/rstate2" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore "$PLART" >/dev/null 2>&1 \
    && fail "planned successfully despite a walk that could not finish" || ok

# ── a plan does not create the state it later writes into ───────────────────
DRH="$(mktemp -d)"; DRART="$(_res_build "$DRH" '["4.*"]')"
DRTGT="$(mktemp -d)"
_res_run "$DRTGT" "$DRH/rstate" "$DRART" >/dev/null 2>&1

it "a plan run creates no restore-state directory"
[[ ! -d "$DRH/rstate/restore" ]] && ok || fail "a plan already wrote $(ls "$DRH/rstate/restore" 2>/dev/null)"

# ── --groups filters by exact id, not by substring ───────────────────────────
GRH="$(mktemp -d)"; GRART="$(_res_build "$GRH" '["3.*","4.*"]')"
GRTGT="$(mktemp -d)"
GROUT="$(HOME="$GRTGT" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$GRH/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore --groups terminal "$GRART" 2>&1)"

it "--groups reaches restore at all -- it used to be silently unreachable"
assert_contains "$GROUT" "terminal"

it "and does not also pull in a differently-named group"
[[ "$GROUT" != *"compositor"* ]] && ok || fail "an unrelated group leaked through the filter"

# ── --json is a real branch, not silently ignored ────────────────────────────
JSH="$(mktemp -d)"; JSART="$(_res_build "$JSH" '["4.*"]')"
JSTGT="$(mktemp -d)"
JSOUT="$(HOME="$JSTGT" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$JSH/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore --json "$JSART" 2>/dev/null)"

it "--json produces parseable JSON, not the human report"
printf '%s' "$JSOUT" | jq -e . >/dev/null 2>&1 && ok || fail "not valid JSON: $JSOUT"

it "and it carries the verdict"
assert_eq "$(printf '%s' "$JSOUT" | jq -r '.verdict')" "same"

# ── two groups sharing a TREE destination lose the real original ────────────
# The collision map was built once, across every group -- the right fix for
# flat. But only the flat branch consulted it. Two groups are free to declare
# the same live directory (nothing stops two ids both naming ~/.config/hypr),
# and for `tree` that means both enumerate the exact same $wt/$prefix and each
# emit a `restore` row for every file in it. The second _restore_one to run
# backs up what the FIRST one just wrote -- not the real original -- and the
# real original is gone from both the destination and the one place kept to
# protect it. Reported by omabackup-rev-2 against a build that had already
# fixed the flat case, which is exactly why this needed its own repro rather
# than reusing the flat one.
TRH="$(mktemp -d)"; TRR="$TRH/repo"
mkdir -p "$TRR/configs/hypr"
git init -q "$TRR"; git -C "$TRR" config user.email t@t; git -C "$TRR" config user.name t
printf 'from the artifact\n' >"$TRR/configs/hypr/bindings.conf"
git -C "$TRR" add -A && git -C "$TRR" commit -qm one
cat >"$TRH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"compositor","label":"Compositor","mode":"copy","coupled":false,"critical":false,
  "paths":["~/.config/hypr"]},
 {"id":"wm","label":"WM","mode":"copy","coupled":false,"critical":false,
  "paths":["~/.config/hypr"]}]}
JSON
mkdir -p "$TRH/home"
HOME="$TRH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$TRH/g.json" \
    OMABACKUP_STATE="$TRH/home/.state" OMABACKUP_REPO="$TRR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
TRART="$(ls -t "$TRH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
TRTGT="$(mktemp -d)"
mkdir -p "$TRTGT/.config/hypr"
printf 'my own irreplaceable original\n' >"$TRTGT/.config/hypr/bindings.conf"
TRPLAN="$(_res_run "$TRTGT" "$TRH/rstate" "$TRART")"

it "two groups naming the same tree destination are flagged ambiguous"
assert_contains "$TRPLAN" "ambiguous"

it "and NOT counted as something that would be restored"
assert_contains "$TRPLAN" "0 files would be restored"

_res_run "$TRTGT" "$TRH/rstate" "$TRART" --apply >/dev/null 2>&1

it "the live file is left exactly as it was"
assert_eq "$(cat "$TRTGT/.config/hypr/bindings.conf" 2>/dev/null)" "my own irreplaceable original"

it "and the original is not lost to a backup-of-a-backup"
TRKEPT="$(find "$TRH/rstate/restore" -path '*replaced*' -name 'bindings.conf' 2>/dev/null | head -1)"
[[ -z "$TRKEPT" ]] || assert_eq "$(cat "$TRKEPT" 2>/dev/null)" "my own irreplaceable original"

# ── the verdict is printed on --apply too, not only on the plan ─────────────
# It used to live inside the plan-only branch, so the run that actually
# changes the machine reported how many files it touched and never why.
R2H="$(mktemp -d)"; R2ART="$(_res_build "$R2H" '["3.*"]')"
R2TGT="$(mktemp -d)"
R2OUT="$(_res_run "$R2TGT" "$R2H/rstate" "$R2ART" --apply)"

it "an --apply run still explains the verdict it acted on"
assert_contains "$R2OUT" "3.*"

# ── escape and ambiguous are visible on --apply, not swallowed ──────────────
# Built as a real repo through `bundle`, not by hand-editing an already-built
# artifact's worktree afterward -- files added post-hoc exist in the worktree
# half but never in the git history half, and _verify_extracted's own diff
# between the two catches exactly that mismatch before restore ever runs.
R3H="$(mktemp -d)"; R3R="$R3H/repo"
R3MARK="restore-escape-apply-$(basename "$R3H")"
mkdir -p "$R3R/dotfiles" "$R3R/$R3MARK"
git init -q "$R3R"; git -C "$R3R" config user.email t@t; git -C "$R3R" config user.name t
printf 'anchor\n' >"$R3R/dotfiles/.anchor"
printf 'x\n' >"$R3R/$R3MARK/f.txt"
git -C "$R3R" add -A && git -C "$R3R" commit -qm one
cat >"$R3H/g.json" <<JSON
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"esc2","label":"Esc2","mode":"copy","coupled":false,"critical":false,
  "paths":["~/../$R3MARK"]}]}
JSON
mkdir -p "$R3H/home"
HOME="$R3H/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$R3H/g.json" \
    OMABACKUP_STATE="$R3H/home/.state" OMABACKUP_REPO="$R3R" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
R3ART="$(ls -t "$R3H/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
R3TGT="$(mktemp -d)"
R3OUT="$(_res_run "$R3TGT" "$R3H/rstate" "$R3ART" --apply)"

it "--apply reports how many rows were refused as escapes"
assert_contains "$R3OUT" "refused"
rm -rf "/tmp/$R3MARK" "$(dirname "$R3TGT")/$R3MARK" 2>/dev/null

# ── realpath is required up front, not discovered as a silent no-op ─────────
R4H="$(mktemp -d)"; R4ART="$(_res_build "$R4H" '["4.*"]')"
R4TGT="$(mktemp -d)"
mkdir -p "$R4H/norealpath"
for t in bash jq git tar zstd sh cat mkdir rm cp find date sed grep basename dirname \
         mv chmod ls sort head tail wc cut tr; do
    ln -sf "$(command -v "$t" 2>/dev/null)" "$R4H/norealpath/$t" 2>/dev/null
done

it "restore refuses up front when realpath is not available"
PATH="$R4H/norealpath" HOME="$R4TGT" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$R4H/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore "$R4ART" >/dev/null 2>&1 \
    && fail "proceeded without realpath, indistinguishable from an empty backup" || ok

# ── a watermark that is not a bare integer does not crash --json ────────────
R5H="$(mktemp -d)"; R5RAW="$(_res_build "$R5H" '["4.*"]')"
R5X="$(mktemp -d)"; tar -C "$R5X" -xf <(zstd -dc "$R5RAW")
jq '.omarchy.migrationWatermark = "2026-08-13"' "$R5X/manifest.json" >"$R5X/manifest.json.new"
mv "$R5X/manifest.json.new" "$R5X/manifest.json"
( cd "$R5X" && find . -type f ! -name SHA256SUMS -print0 | xargs -0 sha256sum >SHA256SUMS )
R5ART="$R5H/badwatermark.tar.zst"
tar -C "$R5X" -cf - . | zstd -q -19 -T0 -o "$R5ART"
R5TGT="$(mktemp -d)"
it "a non-integer watermark is refused, not silently read as 0"
HOME="$R5TGT" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$R5H/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore --json "$R5ART" >/dev/null 2>&1 \
    && fail "proceeded with a compatibility verdict computed from a watermark that was never an integer" \
    || ok

# The regex fallback used to read "2026-08-13" as 0 -- the most PERMISSIVE
# watermark there is -- and 0 against this machine's own real watermark
# (nonzero on any machine with real migration history) read as "forward":
# coupled groups apply, only the markers are held back. A PoC on the real
# machine this was fixed on: a manifest saying "2026-08-13" was accepted, the
# verdict came back forward, and --apply wrote the coupled compositor config.
it "and the refusal names the artifact's own migration state, not this machine's"
R5OUT2="$(HOME="$R5TGT" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$R5H/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore --json "$R5ART" 2>&1)"
assert_contains "$R5OUT2" "artifact's own migration state"

it "and nothing -- coupled or otherwise -- was written from it"
R5TGT2="$(mktemp -d)"
HOME="$R5TGT2" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$R5H/rstate2" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore --apply "$R5ART" >/dev/null 2>&1
[[ -z "$(find "$R5TGT2" -type f 2>/dev/null)" ]] \
    && ok || fail "files were written despite the watermark never having been an integer"

# ── a trailing slash on a declared path does not leak a temp dir into the report ─
R9H="$(mktemp -d)"; R9RAW="$(_res_build "$R9H" '["4.*"]')"
R9X="$(mktemp -d)"; tar -C "$R9X" -xf <(zstd -dc "$R9RAW")
R9G="$(jq '(.groups[] | select(.id=="terminal") | .paths) = ["~/.config/alacritty/"]' "$R9X/tool/groups.default.json")"
printf '%s' "$R9G" >"$R9X/tool/groups.default.json"
( cd "$R9X" && find . -type f ! -name SHA256SUMS -print0 | xargs -0 sha256sum >SHA256SUMS )
R9ART="$R9H/trailingslash.tar.zst"
tar -C "$R9X" -cf - . | zstd -q -19 -T0 -o "$R9ART"
R9TGT="$(mktemp -d)"
R9PLAN="$(_res_run "$R9TGT" "$R9H/rstate" "$R9ART")"

it "a trailing slash on a declared path still restores the file"
assert_contains "$R9PLAN" "alacritty.toml"

it "and no row names a bare temp directory as the destination"
[[ "$R9PLAN" != *"//tmp/"* ]] && ok || fail "leaked a temp path: $R9PLAN"

# ── --groups on restore refuses a typo against the ARTIFACT's manifest ──────
R7H="$(mktemp -d)"; R7ART="$(_res_build "$R7H" '["4.*"]')"
R7TGT="$(mktemp -d)"

it "a typo'd --groups on restore is refused, not silently selecting nothing"
assert_contains "$(_res_run "$R7TGT" "$R7H/rstate" "$R7ART" --groups termnal)" \
    "this artifact's manifest does not have"

it "and the correctly spelled id still works"
assert_contains "$(_res_run "$R7TGT" "$R7H/rstate" "$R7ART" --groups terminal)" \
    "alacritty.toml"

R7ONLY="$(mktemp -d)"
cat >"$R7ONLY/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"only-on-this-machine","label":"X","mode":"copy","coupled":false,"critical":false,
  "paths":["~/.config/nothere"]}]}
JSON
R7ONLYOUT="$(HOME="$(mktemp -d)" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$R7ONLY/g.json" \
    OMABACKUP_STATE="$(mktemp -d)" XDG_RUNTIME_DIR=/nonexistent \
    "$OB" restore --groups terminal "$R7ART" 2>&1)"

it "restore --groups is validated against the ARTIFACT's manifest, not this machine's"
assert_contains "$R7ONLYOUT" "alacritty.toml"

# ── the common case: a plugins group with no dirty plugin, ever ─────────────
# patches/omarchy-plugins only exists once some plugin has been patched --
# most repos never have one. Without a directory-existence guard matching the
# other two find call sites, find on a directory that legitimately does not
# exist exits 1 exactly like one it could not read, and the fix above for a
# real find failure could not tell the two apart: it killed restore's plan for
# every artifact that never had a dirty plugin, blaming the manifest for a
# directory that was never supposed to exist. This is what the fail-closed
# spec above could not catch on its own -- a missing directory is the SAME
# input as the stub that simulates a broken one, so a spec proving the refusal
# without also proving the ordinary case passes cannot tell which one it
# actually pinned.
PLNH="$(mktemp -d)"; PLNR="$PLNH/repo"
mkdir -p "$PLNR/configs/omarchy/plugins/some-plugin"
git init -q "$PLNR"; git -C "$PLNR" config user.email t@t; git -C "$PLNR" config user.name t
printf 'x\n' >"$PLNR/configs/omarchy/plugins/some-plugin/init.lua"
git -C "$PLNR" add -A && git -C "$PLNR" commit -qm one
cat >"$PLNH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"plugins","label":"Plugins","mode":"triple","coupled":true,"critical":true,
  "paths":["~/.config/omarchy/plugins"]}]}
JSON
mkdir -p "$PLNH/home"
HOME="$PLNH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$PLNH/g.json" \
    OMABACKUP_STATE="$PLNH/home/.state" OMABACKUP_REPO="$PLNR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
PLNART="$(ls -t "$PLNH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
PLNTGT="$(mktemp -d)"
PLNPLAN="$(_res_run "$PLNTGT" "$PLNH/rstate" "$PLNART")"

it "a plugins group with no patches directory at all still plans normally"
assert_contains "$PLNPLAN" "would be restored"

it "and does not die claiming the manifest is unreadable"
[[ "$PLNPLAN" != *"could not plan"* ]] \
    && ok || fail "refused to plan over a directory that was never supposed to exist: $PLNPLAN"

it "the local plugin tree itself is still offered"
assert_contains "$PLNPLAN" "init.lua"

# ── the quarantine path is built from a group id, and it was never checked ──
# $g came straight from the artifact's manifest and was concatenated into
# $quar/$g/... with no validation at all -- unlike a live destination, which
# _restore_contained checks before it is ever written to. An artifact naming
# a group "../../../../../<mark>" wrote there directly, outside $quar
# entirely, with rc=0 and no escape row anywhere to have caught it: escape
# only ever guarded the live-write path a `restore` row computes.
TVMARK="restore-traversal-$(basename "$(mktemp -u)")"
TVH="$(mktemp -d)"; TVR="$TVH/repo"
mkdir -p "$TVR/configs/hypr"
git init -q "$TVR"; git -C "$TVR" config user.email t@t; git -C "$TVR" config user.name t
printf 'x\n' >"$TVR/configs/hypr/bindings.conf"
git -C "$TVR" add -A && git -C "$TVR" commit -qm one
cat >"$TVH/g.json" <<JSON
{"schemaVersion":1,"supportedTargets":["3.*"],"groups":[
 {"id":"../../../../../../tmp/$TVMARK","label":"Evil","mode":"copy","coupled":true,"critical":true,
  "paths":["~/.config/hypr"]}]}
JSON
mkdir -p "$TVH/home"
HOME="$TVH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$TVH/g.json" \
    OMABACKUP_STATE="$TVH/home/.state" OMABACKUP_REPO="$TVR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
TVART="$(ls -t "$TVH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
TVTGT="$(mktemp -d)"
_res_run "$TVTGT" "$TVH/rstate" "$TVART" --apply >/dev/null 2>&1

it "a group id crafted to traverse out of the quarantine directory is refused"
[[ ! -e "/tmp/$TVMARK" ]] && ok || fail "wrote outside the quarantine directory"
rm -rf "/tmp/$TVMARK" 2>/dev/null

it "and the target home has nothing from that group either"
[[ ! -e "$TVTGT/.config/hypr/bindings.conf" ]] \
    && ok || fail "a coupled file from a hostile group id was still applied"

# ── a trackedRepoPath lookup that fails must not fall back to the wrong file ─
# group_tracked_repo_path's jq call had its status discarded, so a failed
# lookup and "no override declared" were the same empty string -- and this
# fell through to the generic .config/* mapping either way. For a group whose
# override exists precisely because its content does NOT belong wherever that
# generic mapping would look, that is not a missed override: it is a
# DIFFERENT group's content restored under this group's name, silently.
TRPH="$(mktemp -d)"; TRPR="$TRPH/repo"
mkdir -p "$TRPR/special" "$TRPR/configs/a"
git init -q "$TRPR"; git -C "$TRPR" config user.email t@t; git -C "$TRPR" config user.name t
printf 'correct content\n' >"$TRPR/special/thing.conf"
printf 'WRONG content, from an unrelated group\n' >"$TRPR/configs/a/thing.conf"
git -C "$TRPR" add -A && git -C "$TRPR" commit -qm one
cat >"$TRPH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"special","label":"Special","mode":"copy","coupled":false,"critical":false,
  "paths":[{"live":"~/.config/a","trackedRepoPath":"special"}]},
 {"id":"a","label":"A","mode":"copy","coupled":false,"critical":false,
  "paths":["~/.config/a"]}]}
JSON
mkdir -p "$TRPH/home"
HOME="$TRPH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$TRPH/g.json" \
    OMABACKUP_STATE="$TRPH/home/.state" OMABACKUP_REPO="$TRPR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
TRPART="$(ls -t "$TRPH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
mkdir -p "$TRPH/stub"
{ printf '#!/bin/bash\n'
  printf 'for a in "$@"; do [[ "$a" == *trackedRepoPath* ]] && exit 3; done\n'
  printf 'exec %s "$@"\n' "$(command -v jq)"
} >"$TRPH/stub/jq"; chmod +x "$TRPH/stub/jq"
TRPTGT="$(mktemp -d)"

it "a trackedRepoPath query that fails refuses to plan, not falls back wrong"
PATH="$TRPH/stub:$PATH" HOME="$TRPTGT" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$TRPH/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore "$TRPART" --apply >/dev/null 2>&1 \
    && fail "restored something despite a trackedRepoPath lookup it could not answer" || ok

it "and specifically: the wrong file's content never lands"
[[ ! -e "$TRPTGT/.config/a/thing.conf" ]] && ok || fail "the wrong group's content was restored"

# ── two DIFFERENT repo prefixes agreeing on the same live destination ───────
# The collision map was keyed by repo-side prefix alone, which catches two
# groups naming the SAME trackedRepoPath -- but not two DIFFERENT prefixes
# that both declared the same `live` directory. Two distinct repo locations
# ("prefix-one", "prefix-two"), same $HOME/.config/shared destination, both
# printed as an ordinary `restore` row for the same file: the second
# _restore_one to run would have backed up what the first had just written.
DCH="$(mktemp -d)"; DCR="$DCH/repo"
mkdir -p "$DCR/prefix-one" "$DCR/prefix-two"
git init -q "$DCR"; git -C "$DCR" config user.email t@t; git -C "$DCR" config user.name t
printf 'from prefix one\n' >"$DCR/prefix-one/shared.conf"
printf 'from prefix two\n' >"$DCR/prefix-two/shared.conf"
git -C "$DCR" add -A && git -C "$DCR" commit -qm one
cat >"$DCH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"g1","label":"G1","mode":"copy","coupled":false,"critical":false,
  "paths":[{"live":"~/.config/shared","trackedRepoPath":"prefix-one"}]},
 {"id":"g2","label":"G2","mode":"copy","coupled":false,"critical":false,
  "paths":[{"live":"~/.config/shared","trackedRepoPath":"prefix-two"}]}]}
JSON
mkdir -p "$DCH/home"
HOME="$DCH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$DCH/g.json" \
    OMABACKUP_STATE="$DCH/home/.state" OMABACKUP_REPO="$DCR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
DCART="$(ls -t "$DCH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
DCTGT="$(mktemp -d)"
mkdir -p "$DCTGT/.config/shared"
printf 'my irreplaceable original\n' >"$DCTGT/.config/shared/shared.conf"
DCPLAN="$(_res_run "$DCTGT" "$DCH/rstate" "$DCART")"

it "two different prefixes agreeing on one live destination are flagged ambiguous"
assert_contains "$DCPLAN" "ambiguous"

it "and NOT counted as something that would be restored"
assert_contains "$DCPLAN" "0 files would be restored"

_res_run "$DCTGT" "$DCH/rstate" "$DCART" --apply >/dev/null 2>&1

it "the live file is left exactly as it was"
assert_eq "$(cat "$DCTGT/.config/shared/shared.conf" 2>/dev/null)" "my irreplaceable original"

# ── the verdict stays with the operator's real machine, --into or not ───────
# version and channel are unavoidably the real machine's -- system commands,
# not $HOME-relative -- so an earlier version computed the watermark from
# --into's target to match them, reasoning the verdict is "about wherever the
# restore lands." That broke the far more common use of --into worse than the
# bug it fixed: --into pointed at an empty sandbox (no Omarchy footprint at
# all, hence no migrations directory) read as watermark 0, the PERMISSIVE
# "behind" case -- so previewing --apply against a scratch directory applied
# MORE than a real restore onto the operator's own machine would have.
# Reverted: all three -- version, channel, watermark -- come from the same
# real machine regardless of --into, which is at least one consistent
# identity instead of two machines' worth spliced together.
IVH="$(mktemp -d)"; IVR="$IVH/repo"
mkdir -p "$IVR/state/omarchy/migrations"
git init -q "$IVR"; git -C "$IVR" config user.email t@t; git -C "$IVR" config user.name t
printf 'old\n' >"$IVR/state/omarchy/migrations/1700000000.sh"
printf 'x\n' >"$IVR/state/omarchy/theme"
git -C "$IVR" add -A && git -C "$IVR" commit -qm one
cat >"$IVH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"state","label":"State","mode":"copy","coupled":true,"critical":false,
  "paths":["~/.local/state/omarchy"]}]}
JSON
mkdir -p "$IVH/home"
HOME="$IVH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$IVH/g.json" \
    OMABACKUP_STATE="$IVH/home/.state" OMABACKUP_REPO="$IVR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
IVART="$(ls -t "$IVH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"

# The OPERATOR's own $HOME has a LATER watermark than the backup (forward,
# markers held). --into's target has a watermark that would read "same" if it
# were consulted instead -- if the verdict or the write followed --into's
# state, this would diverge from the operator-only expectation below.
IVOP="$(mktemp -d)"
mkdir -p "$IVOP/.local/state/omarchy/migrations"
touch "$IVOP/.local/state/omarchy/migrations/1800000000.sh"
IVINTO="$(mktemp -d)"
mkdir -p "$IVINTO/.local/state/omarchy/migrations"
touch "$IVINTO/.local/state/omarchy/migrations/1700000000.sh"
IVOUT="$(HOME="$IVOP" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$IVH/rstate" XDG_RUNTIME_DIR=/nonexistent \
    "$OB" restore "$IVART" --into "$IVINTO" 2>&1)"

it "the verdict reflects the operator's own watermark, not --into's target"
assert_contains "$IVOUT" "2027-01-15"

it "and the migration markers are held, matching the OPERATOR's forward state"
assert_contains "$IVOUT" "held"

it "the file still lands inside --into's target, not the operator's real home"
HOME="$IVOP" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$IVH/rstate2" XDG_RUNTIME_DIR=/nonexistent \
    "$OB" restore "$IVART" --into "$IVINTO" --apply >/dev/null 2>&1
[[ -f "$IVINTO/.local/state/omarchy/theme" && ! -f "$IVOP/.local/state/omarchy/theme" ]] \
    && ok || fail "the write followed the wrong home"

# ── a find that fails reading migrations is not a fresh install ─────────────
# `| tail -1` on that pipe, without pipefail, exits 0 whether find succeeded
# or not -- tail on empty input is still success. A migrations directory that
# EXISTS but could not be read defaulted to watermark 0, same as one that
# never existed, and restore's compatibility gate read that as "fresh
# install" and proceeded to apply coupled config against a state it could not
# actually confirm.
MRH="$(mktemp -d)"; MRRAW="$(_res_build "$MRH" '["4.*"]')"
mkdir -p "$MRH/stub"
{ printf '#!/bin/bash\n'
  printf 'for a in "$@"; do [[ "$a" == *migrations* ]] && exit 1; done\n'
  printf 'exec %s "$@"\n' "$(command -v find)"
} >"$MRH/stub/find"; chmod +x "$MRH/stub/find"
MRTGT="$(mktemp -d)"; mkdir -p "$MRTGT/.local/state/omarchy/migrations"
touch "$MRTGT/.local/state/omarchy/migrations/1900000000.sh"

it "restore refuses rather than guess when it cannot read its own migrations"
PATH="$MRH/stub:$PATH" HOME="$MRTGT" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$MRH/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore "$MRRAW" >/dev/null 2>&1 \
    && fail "proceeded with a compatibility verdict it could not actually confirm" || ok

# The absent-directory case -- a genuinely fresh install -- must still work.
MRTGT2="$(mktemp -d)"

it "a directory that legitimately does not exist yet still reads as watermark 0"
PATH="$MRH/stub:$PATH" HOME="$MRTGT2" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$MRH/rstate2" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore "$MRRAW" >/dev/null 2>&1 \
    && ok || fail "refused a restore onto a machine that has simply never migrated"

# ── the forward-verdict marker exclusion applies to flat too, not tree alone ─
# A manifest is free to declare a trackedRepoPath override for the migrations
# directory itself, routing it through `flat` instead of `tree`. The shipped
# manifest never does this, but nothing stops one from declaring it, and the
# forward verdict's own promise -- "the markers do not apply" -- held for tree
# and did not for flat.
HFH="$(mktemp -d)"; HFR="$HFH/repo"
mkdir -p "$HFR/mig-flat"
git init -q "$HFR"; git -C "$HFR" config user.email t@t; git -C "$HFR" config user.name t
printf 'old marker\n' >"$HFR/mig-flat/1700000000.sh"
git -C "$HFR" add -A && git -C "$HFR" commit -qm one
cat >"$HFH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"state","label":"State","mode":"copy","coupled":true,"critical":false,
  "paths":[{"live":"~/.local/state/omarchy/migrations","trackedRepoPath":"mig-flat"}]}]}
JSON
mkdir -p "$HFH/home"
HOME="$HFH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$HFH/g.json" \
    OMABACKUP_STATE="$HFH/home/.state" OMABACKUP_REPO="$HFR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
HFART="$(ls -t "$HFH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
HFTGT="$(mktemp -d)"; mkdir -p "$HFTGT/.local/state/omarchy/migrations"
touch "$HFTGT/.local/state/omarchy/migrations/1900000000.sh"
HFPLAN="$(_res_run "$HFTGT" "$HFH/rstate" "$HFART")"

it "a migrations marker routed through a flat mapping is held too, on forward"
assert_contains "$HFPLAN" "held"

it "and not counted as something that would be restored"
assert_contains "$HFPLAN" "0 files would be restored"

_res_run "$HFTGT" "$HFH/rstate" "$HFART" --apply >/dev/null 2>&1

it "and --apply really does not write the old marker back, through flat either"
[[ ! -e "$HFTGT/.local/state/omarchy/migrations/1700000000.sh" ]] \
    && ok || fail "restored an old migration marker through a flat mapping on a forward move"

# ── a bundle built while unreadable ships with the sentinel baked in ────────
# _restore_verdict checked the sentinel on tm (this machine, live) but not on
# bm (the backup's recorded value, static) -- so a bundle built by a machine
# that could not confirm its own migration state shipped with
# migrationWatermark: "unreadable," and a later restore's [[ "$bm" =~
# ^[0-9]+$ ]] || bm=0 defaulted it exactly like an old bundle predating the
# field, applying coupled config against a backup whose migration state was
# never known to anyone. build_bundle now refuses to build one in the first
# place; this proves the read-time half for an artifact that predates that.
UBH="$(mktemp -d)"; UBRAW="$(_res_build "$UBH" '["4.*"]')"
UBX="$(mktemp -d)"; tar -C "$UBX" -xf <(zstd -dc "$UBRAW")
jq '.omarchy.migrationWatermark = "unreadable"' "$UBX/manifest.json" >"$UBX/manifest.json.new"
mv "$UBX/manifest.json.new" "$UBX/manifest.json"
( cd "$UBX" && find . -type f ! -name SHA256SUMS -print0 | xargs -0 sha256sum >SHA256SUMS )
UBART="$UBH/unreadable-watermark.tar.zst"
tar -C "$UBX" -cf - . | zstd -q -19 -T0 -o "$UBART"
UBTGT="$(mktemp -d)"

it "a backup whose own watermark was unreadable at build time is refused"
_res_run "$UBTGT" "$UBH/rstate" "$UBART" >/dev/null 2>&1 \
    && fail "proceeded with a compatibility verdict the backup itself never had" || ok

# _restore_verdict returns 1 for THIS machine's state, 2 for the ARTIFACT's --
# the same distinction _restore_repo_prefix already draws for a different
# question. One shared message named only the machine, so a perfectly healthy
# machine restoring an old, tainted artifact was told to go investigate
# itself.
it "and the refusal names the artifact, not a healthy machine"
assert_contains "$(_res_run "$UBTGT" "$UBH/rstate" "$UBART")" "artifact's own migration state"

# ── and build_bundle refuses to produce one in the first place ──────────────
BUH="$(mktemp -d)"; BUR="$BUH/repo"
mkdir -p "$BUR/configs/app"
git init -q "$BUR"; git -C "$BUR" config user.email t@t; git -C "$BUR" config user.name t
printf 'x\n' >"$BUR/configs/app/f.txt"
git -C "$BUR" add -A && git -C "$BUR" commit -qm one
mkdir -p "$BUH/home/.local/state/omarchy/migrations"
mkdir -p "$BUH/stub"
{ printf '#!/bin/bash\n'
  printf 'for a in "$@"; do [[ "$a" == *migrations* ]] && exit 1; done\n'
  printf 'exec %s "$@"\n' "$(command -v find)"
} >"$BUH/stub/find"; chmod +x "$BUH/stub/find"

it "build_bundle refuses to build while this machine's watermark is unreadable"
PATH="$BUH/stub:$PATH" HOME="$BUH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$PWD/groups.default.json" \
    OMABACKUP_STATE="$BUH/home/.state" OMABACKUP_REPO="$BUR" XDG_RUNTIME_DIR=/nonexistent \
    "$OB" bundle >/dev/null 2>&1 \
    && fail "built a bundle nobody could ever restore with confidence" || ok

# ── restore never executes the artifact's own embedded tool ─────────────────
# _verify_extracted used to run tool/bin/omabackup status --json as part of
# proving an artifact restorable -- including on restore, where the artifact
# is not necessarily this machine's own trusted output. A PoC confirmed that
# an artifact whose SHA256SUMS is self-consistent (trivial: the attacker who
# builds the artifact also computes its checksums) can replace that binary
# with anything and have it run with the operator's full privileges, even in
# plan mode, before --apply and before any consent. This proves the specific
# fix: restore no longer runs that binary at all, signed or not, apply or
# plan -- it only checks data (SHA256SUMS, the git-bundle-vs-worktree diff).
MXH="$(mktemp -d)"; MXRAW="$(_res_build "$MXH" '["4.*"]')"
MXX="$(mktemp -d)"; tar -C "$MXX" -xf <(zstd -dc "$MXRAW")
MXMARK="$MXH/pwned"
cat >"$MXX/tool/bin/omabackup" <<EOF
#!/bin/bash
echo pwned >"$MXMARK"
echo '{}'
EOF
chmod +x "$MXX/tool/bin/omabackup"
( cd "$MXX" && find . -type f ! -name SHA256SUMS -print0 | xargs -0 sha256sum >SHA256SUMS )
MXART="$MXH/malicious.tar.zst"
tar -C "$MXX" -cf - . | zstd -q -19 -T0 -o "$MXART"

it "a malicious embedded tool does not run during a restore plan"
MXTGT="$(mktemp -d)"
_res_run "$MXTGT" "$MXH/rstate" "$MXART" >/dev/null 2>&1
[[ ! -e "$MXMARK" ]] && ok || fail "the artifact's own binary ran during plan mode"

it "and does not run during --apply either"
_res_run "$MXTGT" "$MXH/rstate2" "$MXART" --apply >/dev/null 2>&1
[[ ! -e "$MXMARK" ]] && ok || fail "the artifact's own binary ran during --apply"

# ── build_bundle still self-checks its own freshly-built output ─────────────
# The embedded-tool self-check stays for build_bundle's fresh-build path: it
# verifies output it JUST built, on this machine, from this machine's own
# repo -- there is no untrusted party in that path, and it is the one place
# actually proving the embedded copy runs. This spec does not discriminate
# this commit from before it -- that path's run_embedded value was 1 before
# this change and still is -- it is a regression guard for a property this
# commit must NOT touch, not evidence of what it fixed. The cache-hit path,
# which this commit DID change, has its own PoC-based spec in
# test/bundle.test.sh ("a tampered CACHED bundle's embedded tool does not run
# on the next cache hit").
#
# A tool broken in a way SHA256SUMS cannot see (it is computed from the very
# files being checked, so a break introduced before publish is
# self-consistent too) must still fail the build.
BEH="$(mktemp -d)"; BER="$BEH/repo"
mkdir -p "$BER/configs/app"
git init -q "$BER"; git -C "$BER" config user.email t@t; git -C "$BER" config user.name t
printf 'x\n' >"$BER/configs/app/f.txt"
git -C "$BER" add -A && git -C "$BER" commit -qm one
mkdir -p "$BEH/stub"
{ printf '#!/bin/bash\n'
  printf 'for a in "$@"; do [[ "$a" == status ]] && exit 1; done\n'
  printf 'exec %s "$@"\n' "$OB"
} >"$BEH/stub/omabackup"; chmod +x "$BEH/stub/omabackup"
BESTAGE="$(mktemp -d)"
mkdir -p "$BESTAGE/bin" "$BESTAGE/lib"
cp -r "$PWD/lib/." "$BESTAGE/lib/"
cp "$PWD/groups.default.json" "$PWD/secrets.deny.json" "$BESTAGE/" 2>/dev/null
cp "$BEH/stub/omabackup" "$BESTAGE/bin/omabackup"
chmod +x "$BESTAGE/bin/omabackup"

it "build_bundle still fails when its own embedded tool is broken"
mkdir -p "$BEH/home"
HOME="$BEH/home" OMABACKUP_ROOT="$BESTAGE" OMABACKUP_GROUPS="$BESTAGE/groups.default.json" \
    OMABACKUP_STATE="$BEH/home/.state" OMABACKUP_REPO="$BER" XDG_RUNTIME_DIR=/nonexistent \
    "$BESTAGE/bin/omabackup" bundle >/dev/null 2>&1 \
    && fail "built and accepted a bundle whose own embedded tool cannot run" || ok

# ── run-embedded's contract is a closed domain, not "anything truthy" ───────
# ${2?...} refuses an OMITTED argument but not an empty or malformed one, and
# (( run_embedded )) is arithmetic -- "2", "1+1", and other non-0/1 values all
# evaluate truthy there. Both real callers pass literals today, so this is
# not a live bypass, but the function's own stated contract ("0 or 1") was
# not actually enforced.
#
# Run against an EMPTY directory first, these specs proved nothing: a bare
# `mktemp -d` fails _verify_extracted's SHA256SUMS/git-clone checks on its
# own, for every run-embedded value, valid or not -- so a refusal there is
# not evidence the domain check did anything. Run instead against a
# genuinely valid, freshly-built-and-extracted artifact -- one this SAME spec
# proves passes with run-embedded=1 -- so a value outside {0,1} has nothing
# else left to blame the refusal on.
RDH="$(mktemp -d)"; RDRAW="$(_res_build "$RDH" '["4.*"]')"
RDX="$(mktemp -d)"; tar -C "$RDX" -xf <(zstd -dc "$RDRAW")

it "a genuinely valid extraction verifies with run-embedded=1"
bash -c 'source lib/bundle.sh; _verify_extracted "$1" 1' _ "$RDX" >/dev/null 2>&1 \
    && ok || fail "the fixture itself does not verify -- the domain specs below would prove nothing"

it "an out-of-domain run-embedded value is refused on that SAME valid extraction"
bash -c 'source lib/bundle.sh; _verify_extracted "$1" 2' _ "$RDX" >/dev/null 2>&1 \
    && fail "run-embedded=2 was accepted on a fixture that verifies fine at 0 and 1" || ok

it "and an empty run-embedded value is refused there too, not silently treated as 0"
bash -c 'source lib/bundle.sh; _verify_extracted "$1" ""' _ "$RDX" >/dev/null 2>&1 \
    && fail "an empty run-embedded value was accepted on a fixture that verifies fine at 0 and 1" || ok

# ── a zstd stream with trailing garbage after a valid frame is not accepted ─
# tar -xf <(zstd -dc ...) discards zstd's own exit status: the process
# substitution runs zstd separately, and $? after tar reflects only tar's
# exit. A PoC confirmed a .tar.zst holding one complete, valid frame followed
# by garbage bytes extracted every file successfully anyway -- tar reads
# exactly what it needs and exits 0 before zstd's later failure on the
# trailing bytes is ever seen by the calling shell. restore used to accept
# such a file as verified and, with --apply, write from it.
ZGH="$(mktemp -d)"; ZGRAW="$(_res_build "$ZGH" '["4.*"]')"
ZGART="$ZGH/trailing-garbage.tar.zst"
cp "$ZGRAW" "$ZGART"
printf 'GARBAGEGARBAGEGARBAGE' >>"$ZGART"

it "a valid artifact with trailing garbage after the zstd frame is refused"
ZGTGT="$(mktemp -d)"
_res_run "$ZGTGT" "$ZGH/rstate" "$ZGART" --apply >/dev/null 2>&1 \
    && fail "restored from a stream zstd itself considered corrupt" || ok

it "and nothing from it was written"
[[ -z "$(find "$ZGTGT" -type f 2>/dev/null)" ]] \
    && ok || fail "files were written despite the extraction being refused"

# ── an artifact-supplied filename cannot inject a phantom TSV row ───────────
# find -print0/read -d '' carries a name with an embedded tab or newline
# through correctly -- the plan row restore_rows printed for it did not: one
# line of TSV, and the name rode straight into it unescaped. A file
# literally named "x<newline>restore<tab>coupled<tab>hijacked.conf" split the
# printf'd row at the embedded newline; everything after it read back as a
# SECOND, well-formed row when re-parsed line by line -- action "restore",
# an entirely different (attacker-chosen) repo path, ending in the SAME
# destination the first (correctly quarantined) row was headed for. The
# destination stayed inside $HOME either way -- this is not a path-traversal
# bypass -- but the ACTION attached to it was forged.
TIH="$(mktemp -d)"; TIR="$TIH/repo"
mkdir -p "$TIR/configs/hypr"
git init -q "$TIR"; git -C "$TIR" config user.email t@t; git -C "$TIR" config user.name t
printf 'bind = SUPER, Q\n' >"$TIR/configs/hypr/bindings.conf"
# The dangerous name itself: a real newline, then text shaped exactly like a
# second TSV row whose action is "restore" and whose repo-relative path is
# one this same commit also carries real content for.
TINAME=$'x\nrestore\tcompositor\tbindings.conf'
printf 'hijacked\n' >"$TIR/configs/hypr/$TINAME"
git -C "$TIR" add -A && git -C "$TIR" commit -qm one
cat >"$TIH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["3.*"],"groups":[
 {"id":"compositor","label":"Compositor","mode":"copy","coupled":true,"critical":true,
  "paths":["~/.config/hypr"]}]}
JSON
mkdir -p "$TIH/home"
HOME="$TIH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$TIH/g.json" \
    OMABACKUP_STATE="$TIH/home/.state" OMABACKUP_REPO="$TIR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
TIART="$(ls -t "$TIH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
TITGT="$(mktemp -d)"

it "a filename with an embedded newline/tab does not inject a restore row"
TIPLAN="$(_res_run "$TITGT" "$TIH/rstate" "$TIART")"
assert_not_contains "$TIPLAN" $'restore\tcompositor\tbindings.conf'

it "and --apply writes nothing at all from the quarantined, tampered group"
_res_run "$TITGT" "$TIH/rstate2" "$TIART" --apply >/dev/null 2>&1
[[ -z "$(find "$TITGT" -type f 2>/dev/null)" ]] \
    && ok || fail "something was written from a quarantined group via the injected name"

# ── the artifact cannot talk a group's coupling down below what the operator's ─
# ── own installed schema already says it is ──────────────────────────────────
# group_field returns success with EMPTY output when a field genuinely does
# not exist in the JSON -- correct for an ordinary uncoupled group, since
# most of them never declare `coupled` at all. But GROUPS_FILE, for the whole
# of cmd_restore, is the ARTIFACT's own bundled groups.default.json (by
# design -- an old artifact can carry groups this machine's current schema
# does not), and manifest.json's own recorded `coupled` value is computed
# FROM that same file at build time, so the two are not independent sources
# for an artifact an attacker built: a crafted artifact can simply omit
# `coupled` for a group its own manifest.json claims is coupled, and nothing
# inside the artifact will ever disagree with itself. A PoC confirmed the
# result: an out-of-range artifact (verdict quarantine) whose bundled schema
# quietly drops `coupled` for `compositor` restored ~/.config/hypr anyway.
CFH="$(mktemp -d)"; CFRAW="$(_res_build "$CFH" '["3.*"]')"
CFX="$(mktemp -d)"; tar -C "$CFX" -xf <(zstd -dc "$CFRAW")
CFG="$(jq '(.groups[] | select(.id=="compositor")) |= del(.coupled)' "$CFX/tool/groups.default.json")"
printf '%s' "$CFG" >"$CFX/tool/groups.default.json"
( cd "$CFX" && find . -type f ! -name SHA256SUMS -print0 | xargs -0 sha256sum >SHA256SUMS )
CFART="$CFH/uncoupled-lie.tar.zst"
tar -C "$CFX" -cf - . | zstd -q -19 -T0 -o "$CFART"
CFTGT="$(mktemp -d)"

it "the artifact's own lie about coupled is not enough to escape quarantine"
_res_run "$CFTGT" "$CFH/rstate" "$CFART" --apply >/dev/null 2>&1
[[ ! -e "$CFTGT/.config/hypr/bindings.conf" ]] \
    && ok || fail "compositor config was restored despite this machine's own schema saying compositor is coupled"

it "and the plan names it quarantined, not restored"
CFPLAN="$(_res_run "$CFTGT" "$CFH/rstate2" "$CFART")"
assert_contains "$CFPLAN" "quarantined"

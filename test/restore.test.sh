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

it "and --apply writes nothing for it, inside the target"
[[ ! -e "$ESCTGT/../$ESCMARK/evil.conf" ]] && ok || fail "wrote past the target home"

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
# A manifest that fails to PARSE would already be refused one gate earlier, by
# _verify_extracted's own bundled status --json self-check reading the exact
# same file -- so that shape can never reach restore_rows to prove anything
# about IT specifically. What group_field actually needs to survive is one
# QUERY failing (a transient jq crash, a read hiccup) while the file itself is
# fine and every other query on it succeeds -- which a stub jq that fails only
# on the exact `coupled` query reproduces without touching the file at all.
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

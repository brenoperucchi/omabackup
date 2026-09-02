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

_res_status() {  # _res_status <target-home> <state>
    local h="$1" st="$2"
    HOME="$h" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$st" \
        XDG_RUNTIME_DIR=/nonexistent "$OB" status --json 2>&1
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

# ── the durable restore journal ─────────────────────────────────────────────
# The panel never runs --apply itself (the restore-panel design settled on a
# terminal handoff), so this file is the only way it can ever learn what an
# --apply run someone launched from a terminal actually did.
it "an --apply run leaves a durable record behind"
[[ -f "$RH/rstate/restore-last.json" ]] && ok || fail "no durable restore record was written"

it "and the record's own restored count matches what actually happened"
assert_eq "$(jq -r '.restored' "$RH/rstate/restore-last.json")" "3"

it "status --json surfaces it as lastRestore"
RSTATUS="$(_res_status "$RTGT" "$RH/rstate")"
assert_eq "$(printf '%s' "$RSTATUS" | jq -r '.lastRestore.restored')" "3"

it "lastRestore carries the target actually used, not just a count"
assert_eq "$(printf '%s' "$RSTATUS" | jq -r '.lastRestore.target.path')" "$(realpath "$RTGT")"

it "and lastRestore.target.mode is home -- no --into was given"
assert_eq "$(printf '%s' "$RSTATUS" | jq -r '.lastRestore.target.mode')" "home"

it "a clean run is marked ok"
assert_eq "$(printf '%s' "$RSTATUS" | jq -r '.lastRestore.ok')" "true"

it "a plan-only run never writes a durable record"
NRSTATE="$(mktemp -d)"
_res_run "$RTGT" "$NRSTATE" "$RART" >/dev/null 2>&1
[[ ! -f "$NRSTATE/restore-last.json" ]] && ok || fail "a plan-only run wrote a durable record"

it "before any --apply has ever run, status --json reports lastRestore as null, not missing or false"
NULLSTATE="$(mktemp -d)"
NULLSTATUS="$(_res_status "$RTGT" "$NULLSTATE")"
assert_eq "$(printf '%s' "$NULLSTATUS" | jq -r '.lastRestore')" "null"

# ── review round: a corrupted journal must not collapse into the same null ─
# jq -e alone used to PRINT a truncated/garbage-suffixed value and only THEN
# fail -- the printed fragment went straight into --argjson with no
# validation, and status --json died with nothing reaching the panel at all.
UNH="$(mktemp -d)"
printf 'not json at all' >"$UNH/restore-last.json"
UNOUT="$(_res_status "$(mktemp -d)" "$UNH")"

it "an unreadable restore record is reported distinctly, not as null"
assert_eq "$(printf '%s' "$UNOUT" | jq -r '.lastRestore.unreadable')" "true"

it "and status --json itself still produces a valid, complete document"
printf '%s' "$UNOUT" | jq -e . >/dev/null 2>&1 && ok || fail "status --json broke over a corrupted journal"

GJH="$(mktemp -d)"
printf '{"ok":true}\ngarbage-after-a-valid-value' >"$GJH/restore-last.json"
GJOUT="$(_res_status "$(mktemp -d)" "$GJH")"

it "valid JSON followed by trailing garbage is rejected as unreadable, not silently accepted"
assert_eq "$(printf '%s' "$GJOUT" | jq -r '.lastRestore.unreadable')" "true"

it "and does not crash status --json either"
printf '%s' "$GJOUT" | jq -e . >/dev/null 2>&1 && ok || fail "status --json died on a corrupted journal"

NLH="$(mktemp -d)"
printf 'null' >"$NLH/restore-last.json"
NLOUT="$(_res_status "$(mktemp -d)" "$NLH")"

it "a record file that is literally the word null on disk is unreadable, not 'never ran'"
assert_eq "$(printf '%s' "$NLOUT" | jq -r '.lastRestore.unreadable')" "true"

# ── review round: restore_record must not write through a pre-planted symlink ─
SLH="$(mktemp -d)"
mkdir -p "$SLH/state" "$SLH/outside"
printf 'sensitive\n' >"$SLH/outside/victim.json"
ln -s "$SLH/outside/victim.json" "$SLH/state/restore-last.json.tmp"
OMABACKUP_STATE="$SLH/state" bash -c 'source lib/restore.sh; restore_record "{\"ok\":true}"' >/dev/null 2>&1

it "restore_record does not write through a symlink planted at its temp path"
assert_eq "$(cat "$SLH/outside/victim.json")" "sensitive"

it "and the real record still lands at the real path"
assert_contains "$(cat "$SLH/state/restore-last.json" 2>/dev/null)" 'ok'

# ── review round: a journal that cannot be saved warns, rather than staying silent ─
RESTUB="$(mktemp -d)/locked"; mkdir -p "$RESTUB"; chmod 000 "$RESTUB" 2>/dev/null
RERR="$(OMABACKUP_STATE="$RESTUB/nested" bash -c 'source lib/restore.sh; restore_record "{}"' 2>&1 >/dev/null)"
chmod 755 "$RESTUB" 2>/dev/null

it "restore_record warns on stderr when it cannot save, rather than failing silently"
assert_contains "$RERR" "could not"

# ── review round: every jq call building the plan JSON is now checked ──────
# A wrapper failing just ONE of them (rows_json here) used to make
# `restore --json` print nothing and still exit 0 -- a consumer trusting exit
# status over content would read that as a trivially empty, successful plan.
JFSTUB="$(mktemp -d)"
cat >"$JFSTUB/jq" <<'SH'
#!/bin/bash
for a in "$@"; do [[ "$a" == "-R" ]] && exit 9; done
exec /usr/bin/jq "$@"
SH
chmod +x "$JFSTUB/jq"
JFTGT="$(mktemp -d)"
JFOUT="$(PATH="$JFSTUB:$PATH" HOME="$JFTGT" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$(mktemp -d)" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore --json "$RART" 2>&1)"
JFRC=$?

it "a jq failure while serializing the plan's rows fails the command, not a silent empty success"
[[ $JFRC -ne 0 ]] && ok || fail "restore --json exited 0 despite failing to serialize its own rows"

it "and says what happened"
assert_contains "$JFOUT" "could not serialize"

# ── review round: a failed read of the artifact's own version/watermark ────
# is refused, not silently reported as if it had succeeded.
JBSTUB="$(mktemp -d)"
cat >"$JBSTUB/jq" <<'SH'
#!/bin/bash
for a in "$@"; do [[ "$a" == *"omarchy.version"* ]] && exit 9; done
exec /usr/bin/jq "$@"
SH
chmod +x "$JBSTUB/jq"
JBTGT="$(mktemp -d)"
JBRC=0
PATH="$JBSTUB:$PATH" HOME="$JBTGT" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$(mktemp -d)" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore "$RART" >/dev/null 2>&1 || JBRC=$?

it "a failed query for the artifact's own Omarchy version fails the plan"
[[ $JBRC -ne 0 ]] && ok || fail "restore exited 0 despite failing to read the artifact's own version"

# ── review round: a preflight failure during --apply still leaves a record ─
# Every die() between the verdict being computed and the write loop starting
# used to leave NOTHING in the journal -- indistinguishable from an attempt
# that never happened, or worse, from whatever a PREVIOUS --apply had left.
JPSTUB="$(mktemp -d)"
cat >"$JPSTUB/jq" <<'SH'
#!/bin/bash
for a in "$@"; do [[ "$a" == *'select(.mode as $x | $m | index($x) | not)'* ]] && exit 9; done
exec /usr/bin/jq "$@"
SH
chmod +x "$JPSTUB/jq"
JPTGT="$(mktemp -d)"; JPSTATE="$(mktemp -d)"
PATH="$JPSTUB:$PATH" HOME="$JPTGT" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$JPSTATE" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore --apply "$RART" >/dev/null 2>&1

it "a preflight failure during --apply still leaves a pending journal record, not nothing"
[[ -f "$JPSTATE/restore-last.json" ]] && ok || fail "no journal record at all after a preflight failure"

it "and the pending record is honest about not having finished"
assert_eq "$(jq -r '.finishedAt' "$JPSTATE/restore-last.json")" "null"

it "and does not claim ok:true or ok:false -- it never got that far"
assert_eq "$(jq -r '.ok' "$JPSTATE/restore-last.json")" "null"

it "but it does carry the artifact and the verdict already computed by that point"
assert_eq "$(jq -r '.verdict' "$JPSTATE/restore-last.json")" "same"

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

# ── review round: two groups sharing one id, one of them disabled ──────────
# group_field/group_paths matched BOTH objects and merged their output
# (jq -r prints one line per match) -- a disabled duplicate's own paths ended
# up restored as part of the enabled group's plan. This is the artifact's
# OWN tool/groups.default.json that restore_rows actually consults, not
# manifest.json's separate `groups` summary field -- tampering the wrong one
# leaves the vulnerable path untouched, which is what a first version of
# this fixture did.
DUPH="$(mktemp -d)"; DUPR="$DUPH/repo"
mkdir -p "$DUPR/configs/a" "$DUPR/configs/b"
git init -q "$DUPR"; git -C "$DUPR" config user.email t@t; git -C "$DUPR" config user.name t
printf 'ok\n' >"$DUPR/configs/a/f.txt"
printf 'should never leak\n' >"$DUPR/configs/b/f.txt"
git -C "$DUPR" add -A && git -C "$DUPR" commit -qm one -q
cat >"$DUPH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"g","label":"G","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/a"]}]}
JSON
mkdir -p "$DUPH/home"
HOME="$DUPH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$DUPH/g.json" OMABACKUP_STATE="$DUPH/home/.state" \
    OMABACKUP_REPO="$DUPR" XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
DUPART="$(ls -t "$DUPH/home/.state/bundles"/*.tar.zst | head -1)"
DUPX="$(mktemp -d)"
tar -C "$DUPX" -xf <(zstd -dc "$DUPART")
jq '.groups += [{"id":"g","label":"G2","mode":"copy","coupled":false,"critical":false,
                 "enabled":false,"paths":["~/.config/b"]}]' \
    "$DUPX/tool/groups.default.json" >"$DUPX/tool/groups.default.json.new" \
    && mv "$DUPX/tool/groups.default.json.new" "$DUPX/tool/groups.default.json"
( cd "$DUPX" && find . -type f ! -name SHA256SUMS -print0 | xargs -0 sha256sum >SHA256SUMS )
DUPTAMPERED="$DUPH/tampered.tar.zst"
( cd "$DUPX" && tar -cf - . | zstd -q -19 -T0 -o "$DUPTAMPERED" )
DUPTGT="$(mktemp -d)"
DUPOUT="$(_res_run "$DUPTGT" "$DUPH/rstate" "$DUPTAMPERED" --apply)"
DUPRC=$?

it "restore refuses an artifact whose own manifest declares a duplicate group id"
[[ $DUPRC -ne 0 ]] && ok || fail "restore succeeded against a duplicate-id artifact"

it "and says which id, rather than failing some other, unrelated way"
assert_contains "$DUPOUT" "declares the same group id more than once: g"

it "the disabled duplicate's content never reached the target"
[[ ! -e "$DUPTGT/.config/b/f.txt" ]] && ok || fail "a disabled group's file leaked through a duplicate id"

# ── review round: a live path with an embedded tab/newline in an artifact ──
# Same reasoning as the manifest-level check above, exercised here against
# the artifact's own tool/groups.default.json -- the file restore_rows
# actually reads group definitions from.
TNH="$(mktemp -d)"; TNR="$TNH/repo"
mkdir -p "$TNR/configs/app"
git init -q "$TNR"; git -C "$TNR" config user.email t@t; git -C "$TNR" config user.name t
printf 'x\n' >"$TNR/configs/app/f.txt"
git -C "$TNR" add -A && git -C "$TNR" commit -qm one -q
cat >"$TNH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/app"]}]}
JSON
mkdir -p "$TNH/home"
HOME="$TNH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$TNH/g.json" OMABACKUP_STATE="$TNH/home/.state" \
    OMABACKUP_REPO="$TNR" XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
TNART="$(ls -t "$TNH/home/.state/bundles"/*.tar.zst | head -1)"
TNX="$(mktemp -d)"
tar -C "$TNX" -xf <(zstd -dc "$TNART")
jq '.groups[0].paths = ["~/.config/app\n~/.config/evil"]' \
    "$TNX/tool/groups.default.json" >"$TNX/tool/groups.default.json.new" \
    && mv "$TNX/tool/groups.default.json.new" "$TNX/tool/groups.default.json"
( cd "$TNX" && find . -type f ! -name SHA256SUMS -print0 | xargs -0 sha256sum >SHA256SUMS )
TNTAMPERED="$TNH/tampered.tar.zst"
( cd "$TNX" && tar -cf - . | zstd -q -19 -T0 -o "$TNTAMPERED" )
TNTGT="$(mktemp -d)"
TNOUT="$(_res_run "$TNTGT" "$TNH/rstate" "$TNTAMPERED")"
TNRC=$?

it "restore refuses an artifact whose manifest declares a path with an embedded newline"
[[ $TNRC -ne 0 ]] && ok || fail "restore succeeded against a newline-in-path artifact"

it "and names the group"
assert_contains "$TNOUT" "app"

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

it "and the plan JSON reports blocked:true -- a UI can gate a handoff on this alone"
COLJSON="$(HOME="$COLTGT" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$COLH/rstate2" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore --json "$COLART" 2>/dev/null)"
assert_eq "$(printf '%s' "$COLJSON" | jq -r '.blocked')" "true"

it "and the durable journal from the earlier --apply marks the run NOT ok"
# rstate (not rstate2) is where the --apply two specs up actually wrote --
# the ambiguous rows it hit make this the case a UI needs to render as
# incomplete/failed, not indistinguishable from a clean restore.
assert_eq "$(jq -r '.ok' "$COLH/rstate/restore-last.json")" "false"

it "and its ambiguous count matches what the apply run actually reported"
# Both colliding groups produce their own ambiguous row -- one destination
# but two declarations that both claim it -- so this is 2, not 1.
assert_eq "$(jq -r '.ambiguous' "$COLH/rstate/restore-last.json")" "2"

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

# ── the plan JSON carries the target, structured, always ────────────────────
# The restore-panel mockup round's own reasoning: a picker showing this MUST
# say which machine's real home a handoff command is about to touch, not
# leave it implicit in the absence of an `--into` flag.
it "target.mode is home when --into was not given"
assert_eq "$(printf '%s' "$JSOUT" | jq -r '.target.mode')" "home"

it "and target.path is the real target home, absolute"
assert_eq "$(printf '%s' "$JSOUT" | jq -r '.target.path')" "$(realpath "$JSTGT")"

it "target.mode is into when --into was given"
INTOTGT="$(mktemp -d)"
INTOOUT="$(HOME="$(mktemp -d)" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$JSH/rstate2" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore --json "$JSART" --into "$INTOTGT" 2>/dev/null)"
assert_eq "$(printf '%s' "$INTOOUT" | jq -r '.target.mode')" "into"

it "and target.path is the --into directory, not the real HOME"
assert_eq "$(printf '%s' "$INTOOUT" | jq -r '.target.path')" "$(realpath "$INTOTGT")"

# ── blocked is a single signal, not something a UI must derive itself ──────
it "blocked is false on a clean, compatible plan"
assert_eq "$(printf '%s' "$JSOUT" | jq -r '.blocked')" "false"

# ── the plan lists a per-group breakdown, not only a flat row list ─────────
it "groups lists every group the plan actually touched"
assert_eq "$(printf '%s' "$JSOUT" | jq -r '[.groups[].id] | sort | join(",")')" \
    "compositor,state,terminal"

it "and a group's restore count matches its own rows, not the whole plan's"
assert_eq "$(printf '%s' "$JSOUT" | jq -r '.groups[] | select(.id=="terminal") | .restore')" \
    "$(printf '%s' "$JSOUT" | jq -r '[.rows[] | select(.group=="terminal" and .action=="restore")] | length')"

# ── new vs replaced: a plan already knows this without writing anything ────
NRH="$(mktemp -d)"; NRART="$(_res_build "$NRH" '["4.*"]')"
NRTGT="$(mktemp -d)"
mkdir -p "$NRTGT/.config/alacritty"
printf 'pre-existing\n' >"$NRTGT/.config/alacritty/alacritty.toml"
NROUT="$(HOME="$NRTGT" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$NRH/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore --json "$NRART" 2>/dev/null)"

it "a file already at the target is counted as replaced, not new"
assert_eq "$(printf '%s' "$NROUT" | jq -r '.counts.replaced')" "1"

it "new + replaced equals the restore count exactly"
assert_eq "$(printf '%s' "$NROUT" | jq -r '.counts.new + .counts.replaced')" \
    "$(printf '%s' "$NROUT" | jq -r '.counts.restore')"

it "a plan run still writes nothing -- computing new/replaced does not touch the target"
assert_eq "$(cat "$NRTGT/.config/alacritty/alacritty.toml")" "pre-existing"

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

# ── trackedRepoPath cannot read from outside the artifact's own worktree ────
# _restore_repo_prefix's `flat` answer is trackedRepoPath, taken verbatim from
# the ARTIFACT's own bundled groups.default.json -- nothing validated it
# stays inside the worktree before restore_rows read from $wt/$prefix. A PoC
# confirmed the result: trackedRepoPath "../../../../etc" made that resolve
# to the real /etc on the machine running restore, and the plan listed real
# host files (arch-release, fstab, machine-id, ...) as things it would
# restore -- with --apply, it copied them under $HOME. Every other
# containment check in this codebase guards the destination; this is the
# read side, unguarded until now.
TPH="$(mktemp -d)"; TPR="$TPH/repo"
mkdir -p "$TPR/configs/app"
git init -q "$TPR"; git -C "$TPR" config user.email t@t; git -C "$TPR" config user.name t
printf 'x\n' >"$TPR/configs/app/f.txt"
git -C "$TPR" add -A && git -C "$TPR" commit -qm one
cat >"$TPH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"evil","label":"Evil","mode":"copy","coupled":false,"critical":false,
  "paths":[{"live":"~/.config/app","trackedRepoPath":"../../../../etc"}]}]}
JSON
mkdir -p "$TPH/home"
HOME="$TPH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$TPH/g.json" \
    OMABACKUP_STATE="$TPH/home/.state" OMABACKUP_REPO="$TPR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
TPART="$(ls -t "$TPH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
TPTGT="$(mktemp -d)"

it "a trackedRepoPath escaping the worktree is refused, not read from"
TPPLAN="$(HOME="$TPTGT" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$TPH/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore "$TPART" 2>&1)"
assert_contains "$TPPLAN" "0 files would be restored"

it "and specifically names it refused, not silently skipped"
assert_contains "$TPPLAN" "refused"

it "and --apply writes nothing at all from a filesystem outside the artifact"
HOME="$TPTGT" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$TPH/rstate2" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore --apply "$TPART" >/dev/null 2>&1
[[ -z "$(find "$TPTGT" -type f 2>/dev/null)" ]] \
    && ok || fail "files from outside the artifact's own worktree were written"

# ── a trailing slash in a declared path does not defeat the held check ──────
# migdir vs $dest used to be a raw string compare -- _expand does nothing but
# substitute a leading ~, so a group declaring its live path WITH a trailing
# slash ("~/.local/state/omarchy/" instead of without) made $dest carry a
# double slash the comparison no longer matched. A PoC confirmed the result:
# on a genuine `forward` verdict, an old migration marker that should have
# been held was offered as an ordinary restore instead. Nothing malicious --
# just an accidental trailing slash, in either this machine's own manifest or
# an artifact's.
TSH="$(mktemp -d)"; TSR="$TSH/repo"
mkdir -p "$TSR/state/omarchy/migrations"
git init -q "$TSR"; git -C "$TSR" config user.email t@t; git -C "$TSR" config user.name t
printf 'old\n' >"$TSR/state/omarchy/migrations/1700000000.sh"
git -C "$TSR" add -A && git -C "$TSR" commit -qm one
cat >"$TSH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"state","label":"State","mode":"copy","coupled":true,"critical":false,
  "paths":["~/.local/state/omarchy/"]}]}
JSON
mkdir -p "$TSH/home/.local/state/omarchy/migrations"
printf 'artifact-own\n' >"$TSH/home/.local/state/omarchy/migrations/1700000000.sh"
HOME="$TSH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$TSH/g.json" \
    OMABACKUP_STATE="$TSH/home/.state" OMABACKUP_REPO="$TSR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
TSART="$(ls -t "$TSH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
TSTGT="$(mktemp -d)"
mkdir -p "$TSTGT/.local/state/omarchy/migrations"
printf 'newer\n' >"$TSTGT/.local/state/omarchy/migrations/1900000000.sh"

it "an old marker is held on forward, even through a trailing-slash declared path"
TSPLAN="$(HOME="$TSTGT" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$TSH/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore "$TSART" 2>&1)"
assert_contains "$TSPLAN" "held"

it "and 0 files would be restored, not 1"
assert_contains "$TSPLAN" "0 files would be restored"

it "and --apply really does not write the old marker back"
HOME="$TSTGT" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$TSH/rstate2" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore --apply "$TSART" >/dev/null 2>&1
[[ ! -e "$TSTGT/.local/state/omarchy/migrations/1700000000.sh" ]] \
    && ok || fail "the old marker was written despite the forward verdict"

# ── the coupled floor itself must not be fail-open ───────────────────────────
# The floor's own jq query against the operator's local schema was consumed
# via 2>/dev/null, so "the operator's file genuinely doesn't mention this
# group" and "the operator's file exists but cannot be PARSED" looked
# identical: empty output either way, and the artifact's own (less
# restrictive) coupled:false answer stood unchallenged. A PoC confirmed the
# result: an artifact declaring compositor coupled:true in manifest.json but
# omitting coupled in its own bundled groups.default.json, restored against
# an operator whose LOCAL groups.default.json was simply invalid JSON,
# restored the compositor config anyway -- exactly the case the floor exists
# to hold back, defeated by making the floor itself unable to answer.
CFLH="$(mktemp -d)"; CFLR="$CFLH/repo"
mkdir -p "$CFLR/configs/hypr"
git init -q "$CFLR"; git -C "$CFLR" config user.email t@t; git -C "$CFLR" config user.name t
printf 'bind = SUPER, Q\n' >"$CFLR/configs/hypr/bindings.conf"
git -C "$CFLR" add -A && git -C "$CFLR" commit -qm one
cat >"$CFLH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["3.*"],"groups":[
 {"id":"compositor","label":"Compositor","mode":"copy","coupled":true,"critical":true,
  "paths":["~/.config/hypr"]}]}
JSON
mkdir -p "$CFLH/home"
HOME="$CFLH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$CFLH/g.json" \
    OMABACKUP_STATE="$CFLH/home/.state" OMABACKUP_REPO="$CFLR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
CFLX="$(mktemp -d)"; CFLRAW="$(ls -t "$CFLH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
tar -C "$CFLX" -xf <(zstd -dc "$CFLRAW")
CFLG="$(jq '(.groups[] | select(.id=="compositor")) |= del(.coupled)' "$CFLX/tool/groups.default.json")"
printf '%s' "$CFLG" >"$CFLX/tool/groups.default.json"
( cd "$CFLX" && find . -type f ! -name SHA256SUMS -print0 | xargs -0 sha256sum >SHA256SUMS )
CFLART="$CFLH/lied.tar.zst"
tar -C "$CFLX" -cf - . | zstd -q -19 -T0 -o "$CFLART"
CFLTGT="$(mktemp -d)"
printf 'not valid json' >"$CFLH/local-broken.json"

it "restore refuses when the floor's own local manifest cannot be parsed"
HOME="$CFLTGT" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$CFLH/local-broken.json" \
    OMABACKUP_STATE="$CFLH/rstate" XDG_RUNTIME_DIR=/nonexistent \
    "$OB" restore --apply "$CFLART" >/dev/null 2>&1 \
    && fail "restored using the artifact's own answer while the local floor could not be checked" || ok

it "and nothing from the coupled group was written"
[[ ! -e "$CFLTGT/.config/hypr/bindings.conf" ]] \
    && ok || fail "compositor config was restored despite the floor being unreadable"

# ── manifest.json and the artifact's own groups.default.json can disagree --
# ── the less restrictive one must not win ────────────────────────────────
# The decision above only ever queried tool/groups.default.json; manifest.json
# records its OWN copy of coupled per group (computed from the SAME file at
# build time), and nothing cross-checked the two for an artifact assembled by
# hand rather than built honestly. A PoC confirmed the result: manifest.json
# claiming coupled:true for compositor while tool/groups.default.json quietly
# says false restored the group anyway, on an operator machine whose own
# local schema does not recognize this artifact's group id at all (so the
# floor above has nothing to add either).
MDH="$(mktemp -d)"; MDR="$MDH/repo"
mkdir -p "$MDR/configs/hypr"
git init -q "$MDR"; git -C "$MDR" config user.email t@t; git -C "$MDR" config user.name t
printf 'bind = SUPER, Q\n' >"$MDR/configs/hypr/bindings.conf"
git -C "$MDR" add -A && git -C "$MDR" commit -qm one
cat >"$MDH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["3.*"],"groups":[
 {"id":"compositor","label":"Compositor","mode":"copy","coupled":true,"critical":true,
  "paths":["~/.config/hypr"]}]}
JSON
mkdir -p "$MDH/home"
HOME="$MDH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$MDH/g.json" \
    OMABACKUP_STATE="$MDH/home/.state" OMABACKUP_REPO="$MDR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
MDX="$(mktemp -d)"; MDRAW="$(ls -t "$MDH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
tar -C "$MDX" -xf <(zstd -dc "$MDRAW")
MDG="$(jq '(.groups[] | select(.id=="compositor") | .coupled) = false' "$MDX/tool/groups.default.json")"
printf '%s' "$MDG" >"$MDX/tool/groups.default.json"
( cd "$MDX" && find . -type f ! -name SHA256SUMS -print0 | xargs -0 sha256sum >SHA256SUMS )
MDART="$MDH/mismatched.tar.zst"
tar -C "$MDX" -cf - . | zstd -q -19 -T0 -o "$MDART"
MDTGT="$(mktemp -d)"

it "manifest.json's coupled:true is not overridden by a lower groups.default.json value"
HOME="$MDTGT" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$MDH/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore --apply "$MDART" >/dev/null 2>&1
[[ ! -e "$MDTGT/.config/hypr/bindings.conf" ]] \
    && ok || fail "compositor config restored despite manifest.json saying it is coupled"

# ── a plan run does not create --into's target directory either ─────────────
# mkdir -p "$into" ran before the plan/apply split, unconditionally --
# needed either way, since _restore_contained resolves $HOME with realpath -e
# and a plan has to answer containment the same way apply would. But a plan
# naming a --into target that did not exist yet still created it: an
# observable write from the one command that promises "nothing was written."
IOH="$(mktemp -d)"; IOART="$(_res_build "$IOH" '["3.*","4.*"]')"
IOINTO="$IOH/does-not-exist-yet"

it "a plan run with --into does not create the target directory"
HOME="$IOH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$IOH/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore --into "$IOINTO" "$IOART" >/dev/null 2>&1
[[ ! -e "$IOINTO" ]] && ok || fail "the plan created $(_tilde "$IOINTO" 2>/dev/null || echo "$IOINTO") despite writing nothing else"

it "and --apply with --into does create it, same as before"
HOME="$IOH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$IOH/rstate2" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore --into "$IOINTO" --apply "$IOART" >/dev/null 2>&1
[[ -d "$IOINTO" ]] && ok || fail "--apply did not create the --into target"

# ── a --into target created for a plan that then fails to plan is cleaned up ─
# mkdir -p "$into" happens before restore_rows is ever called; every die
# between the two used to skip the rmdir cleanup entirely -- that only ran
# once the plan branch reached its own normal end. A PoC (a --into target
# that did not exist yet, restore_rows made to fail by a broken realpath)
# confirmed the result: this command returned 1, but the target directory
# it had just created was left behind -- an observable write from a run
# that made none.
IFH="$(mktemp -d)"; IFART="$(_res_build "$IFH" '["3.*","4.*"]')"
IFINTO="$IFH/does-not-exist-yet"
mkdir -p "$IFH/stub"
printf '#!/bin/bash\nexit 1\n' >"$IFH/stub/realpath"; chmod +x "$IFH/stub/realpath"

it "a --into target is removed when the plan itself fails, not left behind"
PATH="$IFH/stub:$PATH" HOME="$IFH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$IFH/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore --into "$IFINTO" "$IFART" >/dev/null 2>&1
[[ ! -e "$IFINTO" ]] \
    && ok || fail "the --into target was left behind after the plan itself failed"

# ── and when mkdir -p "$into" itself is the thing that fails ────────────────
# The cleanup above covers every die AFTER $into is created; mkdir -p
# "$into" failing was a fourth site with the same gap, and mkdir -p can
# fail partway (an intermediate component created, a later one refused)
# and still leave something behind. A PoC (a wrapper that runs the real
# mkdir -- so the directory genuinely exists afterward -- then reports
# failure anyway) confirmed the result: rc=1, and the target directory
# stayed behind.
MDIH="$(mktemp -d)"; MDIART="$(_res_build "$MDIH" '["3.*","4.*"]')"
MDIINTO="$MDIH/into-target"
mkdir -p "$MDIH/stub"
cat >"$MDIH/stub/mkdir" <<STUB
#!/bin/bash
/usr/bin/mkdir "\$@"
if [[ "\$*" == *"$MDIINTO"* ]]; then exit 1; fi
exit 0
STUB
chmod +x "$MDIH/stub/mkdir"

it "a --into target is removed even when mkdir -p itself is what failed"
PATH="$MDIH/stub:$PATH" HOME="$MDIH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$MDIH/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore --into "$MDIINTO" "$MDIART" >/dev/null 2>&1
[[ ! -e "$MDIINTO" ]] \
    && ok || fail "the --into target was left behind after mkdir -p itself failed"

# ── the backup of a replaced file must land inside replaced/, not beside it ─
# `local keep="$backup/${dest#"$HOME"/}"` stripped $HOME's literal string
# from $dest -- not the normalized path _restore_contained had just checked
# containment against. A $dest holding a literal ".." that still resolves
# back inside $HOME (legal containment, unusual spelling -- e.g. a declared
# path routing through "$HOME/../$(basename $HOME)/...") strips to a suffix
# that still carries the "..", and mkdir -p "$(dirname "$keep")" then creates
# a directory OUTSIDE $backup entirely, a sibling of replaced/. Confirmed
# directly against _restore_one, since routing this exact shape through the
# full restore_rows path-mapping case statement is not the point being
# tested here -- what matters is what THIS function does with a $dest that
# already passed containment.
RUH="$(mktemp -d)"; RUHOME="$RUH/home"
mkdir -p "$RUHOME"
RUBASENAME="$(basename "$RUHOME")"
RUDEST="$RUHOME/../$RUBASENAME/victim.txt"
printf 'original\n' >"$RUHOME/victim.txt"
RUX="$RUH/extracted"; mkdir -p "$RUX/worktree"
printf 'new-content\n' >"$RUX/worktree/rel.txt"
RUBACKUP="$RUH/base/replaced"; mkdir -p "$RUBACKUP"

it "a dest reaching back through .. and into HOME backs up inside replaced/"
HOME="$RUHOME" bash -c 'source lib/restore.sh; _restore_one "$1" "$2" "$3" "$4"' \
    _ "$RUX" "rel.txt" "$RUDEST" "$RUBACKUP" >/dev/null 2>&1
[[ -f "$RUBACKUP/victim.txt" ]] && ok || fail "the backup did not land inside replaced/"

it "and nothing was backed up outside it"
[[ -z "$(find "$RUH/base" -type f ! -path "$RUBACKUP/*" 2>/dev/null)" ]] \
    && ok || fail "a backup file escaped replaced/: $(find "$RUH/base" -type f ! -path "$RUBACKUP/*")"

# ── an ancestor declared path and a descendant one collide, and must be ─────
# ── flagged ambiguous, not silently written twice ───────────────────────────
# destcount/prefixcount key by exact string equality -- ~/.config/foo and
# ~/.config/foo/bar never collide as strings, but the FIRST group's tree walk
# already recurses into bar/ on its own, and the SECOND group's separate walk
# over the same files produces a second row for the same destination. A PoC
# confirmed the result: two rows, one destination, neither flagged ambiguous;
# --apply wrote the file twice, and the SECOND write's backup overwrote the
# first's in replaced/ -- the operator's real original was gone from both the
# live destination and the one place kept to protect it.
ADH="$(mktemp -d)"; ADR="$ADH/repo"
mkdir -p "$ADR/configs/foo/bar"
git init -q "$ADR"; git -C "$ADR" config user.email t@t; git -C "$ADR" config user.name t
printf 'from-the-backup\n' >"$ADR/configs/foo/bar/f.txt"
git -C "$ADR" add -A && git -C "$ADR" commit -qm one
cat >"$ADH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"outer","label":"Outer","mode":"copy","coupled":false,"critical":false,
  "paths":["~/.config/foo"]},
 {"id":"inner","label":"Inner","mode":"copy","coupled":false,"critical":false,
  "paths":["~/.config/foo/bar"]}]}
JSON
mkdir -p "$ADH/home"
HOME="$ADH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$ADH/g.json" \
    OMABACKUP_STATE="$ADH/home/.state" OMABACKUP_REPO="$ADR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
ADART="$(ls -t "$ADH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
ADTGT="$(mktemp -d)"
mkdir -p "$ADTGT/.config/foo/bar"
printf 'operators-original\n' >"$ADTGT/.config/foo/bar/f.txt"

it "an ancestor and a descendant declared path collide, flagged ambiguous"
ADPLAN="$(HOME="$ADTGT" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$ADH/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore "$ADART" 2>&1)"
assert_contains "$ADPLAN" "ambiguous"

it "and 0 files would be restored, not 1"
assert_contains "$ADPLAN" "0 files would be restored"

it "and --apply does not touch the operator's original at all"
HOME="$ADTGT" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$ADH/rstate2" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore --apply "$ADART" >/dev/null 2>&1
assert_eq "$(cat "$ADTGT/.config/foo/bar/f.txt")" "operators-original"

# ── the ancestor/descendant collision is caught through a trailing slash ────
# ── and through a symlink alias, not just an identical literal spelling ─────
# poisoned_e/destcount used to key on $e's raw spelling. Two independent PoCs
# went straight through that: a trailing slash on one of two otherwise-
# identical declared paths, and two declared paths that are not textually
# related at all but are the SAME real location because one is a symlink to
# the other. Both reproduced the exact replaced/-overwritten data loss the
# collision map exists to prevent. Fixed by keying on realpath -m instead --
# it resolves the trailing slash lexically and the symlink by actually
# following it.
TS1H="$(mktemp -d)"; TS1R="$TS1H/repo"
mkdir -p "$TS1R/configs/foo"
git init -q "$TS1R"; git -C "$TS1R" config user.email t@t; git -C "$TS1R" config user.name t
printf 'from-backup\n' >"$TS1R/configs/foo/f.txt"
git -C "$TS1R" add -A && git -C "$TS1R" commit -qm one
cat >"$TS1H/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"a","label":"A","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/foo/"]},
 {"id":"b","label":"B","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/foo"]}]}
JSON
mkdir -p "$TS1H/home/.config/foo"
printf 'operator-original\n' >"$TS1H/home/.config/foo/f.txt"
HOME="$TS1H/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$TS1H/g.json" \
    OMABACKUP_STATE="$TS1H/home/.state" OMABACKUP_REPO="$TS1R" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
TS1ART="$(ls -t "$TS1H/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"

it "a trailing slash on one of two identical declared paths is still caught"
TS1PLAN="$(HOME="$TS1H/home" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$TS1H/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore "$TS1ART" 2>&1)"
assert_contains "$TS1PLAN" "0 files would be restored"

SAH="$(mktemp -d)"; SAR="$SAH/repo"
mkdir -p "$SAR/configs/foo"
git init -q "$SAR"; git -C "$SAR" config user.email t@t; git -C "$SAR" config user.name t
printf 'from-backup\n' >"$SAR/configs/foo/f.txt"
git -C "$SAR" add -A && git -C "$SAR" commit -qm one
cat >"$SAH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"a","label":"A","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/alias"]},
 {"id":"b","label":"B","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/foo"]}]}
JSON
mkdir -p "$SAH/home/.config/foo"
printf 'operator-original\n' >"$SAH/home/.config/foo/f.txt"
ln -s "$SAH/home/.config/foo" "$SAH/home/.config/alias"
HOME="$SAH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$SAH/g.json" \
    OMABACKUP_STATE="$SAH/home/.state" OMABACKUP_REPO="$SAR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
SAART="$(ls -t "$SAH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"

it "two declared paths aliased by a real symlink are caught, apply writes nothing"
HOME="$SAH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$SAH/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore --apply "$SAART" >/dev/null 2>&1
assert_eq "$(cat "$SAH/home/.config/foo/f.txt")" "operator-original"

# ── the coupled floor refuses on a local schema it cannot READ, not just ────
# ── one it cannot PARSE ──────────────────────────────────────────────────────
# The floor used to be gated by `-r` alone: a local groups.default.json that
# EXISTS but cannot be read (permissions, ownership drift) failed -r the same
# way a path that was never given at all does, and the floor skipped itself
# silently either way -- indistinguishable from "this operator has no opinion
# on this group." A PoC confirmed the result: a local schema at mode 000,
# artifact claiming compositor coupled:false, restored anyway even though the
# unreadable local file would have said coupled:true had anyone been able to
# check it.
CFRH="$(mktemp -d)"; CFRR="$CFRH/repo"
mkdir -p "$CFRR/configs/hypr"
git init -q "$CFRR"; git -C "$CFRR" config user.email t@t; git -C "$CFRR" config user.name t
printf 'bind = SUPER, Q\n' >"$CFRR/configs/hypr/bindings.conf"
git -C "$CFRR" add -A && git -C "$CFRR" commit -qm one
cat >"$CFRH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["3.*"],"groups":[
 {"id":"compositor","label":"Compositor","mode":"copy","coupled":false,"critical":true,
  "paths":["~/.config/hypr"]}]}
JSON
mkdir -p "$CFRH/home"
HOME="$CFRH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$CFRH/g.json" \
    OMABACKUP_STATE="$CFRH/home/.state" OMABACKUP_REPO="$CFRR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
CFRART="$(ls -t "$CFRH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
CFRTGT="$(mktemp -d)"
cat >"$CFRH/local-unreadable.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["3.*"],"groups":[
 {"id":"compositor","label":"Compositor","mode":"copy","coupled":true,"critical":true,
  "paths":["~/.config/hypr"]}]}
JSON
chmod 000 "$CFRH/local-unreadable.json"

it "restore refuses when the floor's own local manifest cannot be read"
HOME="$CFRTGT" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$CFRH/local-unreadable.json" \
    OMABACKUP_STATE="$CFRH/rstate" XDG_RUNTIME_DIR=/nonexistent \
    "$OB" restore --apply "$CFRART" >/dev/null 2>&1 \
    && fail "restored using the artifact's own answer while the local floor could not be read" || ok

it "and nothing from the coupled group was written"
[[ ! -e "$CFRTGT/.config/hypr/bindings.conf" ]] \
    && ok || fail "compositor config was restored despite the unreadable local floor"
chmod 644 "$CFRH/local-unreadable.json"

# ── a broken realpath refuses to plan, not silently falls back to raw ───────
# ── string comparison for the ancestor/descendant collision check ──────────
# The canonicalization added to close the ancestor/descendant collision fell
# back to the RAW path on its own failure (`ec="$e"` if realpath came back
# empty) -- a broken or missing realpath quietly reopened the exact
# string-comparison bug the canonicalization exists to close, rather than
# refusing. A stub that fails everywhere also trips OTHER, already-hardened
# realpath call sites (e.g. _restore_one's own dest_rp, which already
# refuses on failure) for an unrelated reason, so the earlier version of
# this spec passed even against the pre-fix code -- it never isolated the
# ONE call site being tested. Narrowed to fail on exactly one declared
# path's realpath call, reusing the alias/foo symlink-collision fixture:
# with the raw-string fallback, the aliased entry keeps its RAW,
# un-resolved spelling while its twin resolves normally, the two no longer
# look identical, and the collision this pair exists to prove goes
# undetected.
RPH="$(mktemp -d)"; RPR="$RPH/repo"
mkdir -p "$RPR/configs/foo"
git init -q "$RPR"; git -C "$RPR" config user.email t@t; git -C "$RPR" config user.name t
printf 'from-backup\n' >"$RPR/configs/foo/f.txt"
git -C "$RPR" add -A && git -C "$RPR" commit -qm one
cat >"$RPH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"a","label":"A","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/alias"]},
 {"id":"b","label":"B","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/foo"]}]}
JSON
mkdir -p "$RPH/home/.config/foo"
printf 'operator-original\n' >"$RPH/home/.config/foo/f.txt"
ln -s "$RPH/home/.config/foo" "$RPH/home/.config/alias"
HOME="$RPH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$RPH/g.json" \
    OMABACKUP_STATE="$RPH/home/.state" OMABACKUP_REPO="$RPR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
RPART="$(ls -t "$RPH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
mkdir -p "$RPH/stub"
cat >"$RPH/stub/realpath" <<STUB
#!/bin/bash
for a in "\$@"; do
    [[ "\$a" == "$RPH/home/.config/alias" ]] && exit 1
done
exec /usr/bin/realpath "\$@"
STUB
chmod +x "$RPH/stub/realpath"

it "restore refuses to plan when realpath fails on just one declared path"
PATH="$RPH/stub:$PATH" HOME="$RPH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$RPH/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore --apply "$RPART" >/dev/null 2>&1 \
    && fail "restore proceeded despite realpath being unusable for one of the two aliased paths" || ok

it "and the operator's original file is untouched"
assert_eq "$(cat "$RPH/home/.config/foo/f.txt")" "operator-original"

# ── a symlink partway INSIDE a tree, not just at a declared path, is caught ──
# prefixcount/destcount/poisoned_e only ever compared the DECLARED bases of
# two groups against each other. Two groups declaring genuinely unrelated
# paths (~/.config/foo and ~/.config/bar, tree mode) never collide there --
# but if the artifact's own "foo/link/" is an ordinary tracked directory,
# and the TARGET machine already has ~/.config/foo/link as a live symlink
# to ~/.config/bar, restoring `foo`'s tree writes through that link into
# bar/ while `bar`'s own declared path writes there directly. A PoC
# confirmed the result: "restored 2 files", bar/file left holding whichever
# group wrote last, and the ONE backup slot meant to protect the operator's
# real original holding the OTHER group's content instead -- the real
# original gone from both places at once, permanently. Every per-file
# destination is now canonicalized and checked against every other group's,
# not just each group's own declared base.
MTH="$(mktemp -d)"; MTR="$MTH/repo"
mkdir -p "$MTR/configs/foo/link" "$MTR/configs/bar"
git init -q "$MTR"; git -C "$MTR" config user.email t@t; git -C "$MTR" config user.name t
printf 'A\n' >"$MTR/configs/foo/link/file"
printf 'B\n' >"$MTR/configs/bar/file"
git -C "$MTR" add -A && git -C "$MTR" commit -qm one
cat >"$MTH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"foo","label":"Foo","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/foo"]},
 {"id":"bar","label":"Bar","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/bar"]}]}
JSON
mkdir -p "$MTH/home/.config/foo/link" "$MTH/home/.config/bar"
printf 'A\n' >"$MTH/home/.config/foo/link/file"
printf 'B\n' >"$MTH/home/.config/bar/file"
HOME="$MTH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$MTH/g.json" \
    OMABACKUP_STATE="$MTH/home/.state" OMABACKUP_REPO="$MTR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
MTART="$(ls -t "$MTH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
MTTGT="$(mktemp -d)"
mkdir -p "$MTTGT/.config/foo" "$MTTGT/.config/bar"
printf 'ORIGINAL\n' >"$MTTGT/.config/bar/file"
ln -s "$MTTGT/.config/bar" "$MTTGT/.config/foo/link"

it "restore --apply does not lose the original through a mid-tree symlink alias"
HOME="$MTTGT" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$MTH/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore --apply "$MTART" >/dev/null 2>&1
assert_eq "$(cat "$MTTGT/.config/bar/file")" "ORIGINAL"

# ── a group id with an embedded tab or newline is refused, not printed raw ──
# restore_rows prints $id unescaped as one field of a tab-separated row, and
# bin/omabackup's own apply loop parses that row back with a fixed 4-field
# `read`. A PoC confirmed the result: an id of "base<TAB>../../../../etc/
# hostname<TAB>x/victim" shifted a row's fields so the attacker-chosen
# "../../../../etc/hostname" landed in the field _restore_one uses to build
# its READ path, and the host's own /etc/hostname was copied into the
# target under an unrelated name. groups_ids() now refuses any id
# containing a tab or newline before any row is ever built.
TIH="$(mktemp -d)"; TIR="$TIH/repo"
mkdir -p "$TIR/configs/hypr"
git init -q "$TIR"; git -C "$TIR" config user.email t@t; git -C "$TIR" config user.name t
printf 'bind = SUPER, Q\n' >"$TIR/configs/hypr/bindings.conf"
git -C "$TIR" add -A && git -C "$TIR" commit -qm one
cat >"$TIH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"compositor","label":"Compositor","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/hypr"]}]}
JSON
mkdir -p "$TIH/home"
HOME="$TIH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$TIH/g.json" \
    OMABACKUP_STATE="$TIH/home/.state" OMABACKUP_REPO="$TIR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
TIRAW="$(ls -t "$TIH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
TIX="$(mktemp -d)"; tar -C "$TIX" -xf <(zstd -dc "$TIRAW")
python3 -c "
import json
p = '$TIX/tool/groups.default.json'
g = json.load(open(p))
g['groups'][0]['id'] = 'base\t../../../../etc/hostname\tx/victim'
json.dump(g, open(p,'w'))
"
( cd "$TIX" && find . -type f ! -name SHA256SUMS -print0 | xargs -0 sha256sum >SHA256SUMS )
TIART="$TIH/tampered.tar.zst"
tar -C "$TIX" -cf - . | zstd -q -19 -T0 -o "$TIART"

it "restore refuses a group id containing an embedded tab"
HOME="$TIH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$TIH/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore --apply "$TIART" >/dev/null 2>&1 \
    && fail "restore proceeded despite a tab-embedded group id" || ok

it "and nothing was written at all"
[[ -z "$(find "$TIH/home/.config" -type f 2>/dev/null)" ]] \
    && ok || fail "a file was written despite the tampered group id"

# The two specs above go through the whole restore pipeline, where an
# unrelated containment check on the resulting garbled row happens to also
# fail for this exact crafted id -- confirmed by running them against
# 1523d70-era code: they still refuse, just not because of this fix.
# groups_ids() itself is checked directly here instead, where the only
# thing that can make it refuse is the check this fix added.
GIH="$(mktemp -d)"
cat >"$GIH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"ok","label":"OK","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/ok"]}]}
JSON

it "groups_ids succeeds on an ordinary manifest"
GIOUT="$(OMABACKUP_GROUPS="$GIH/g.json" bash -c 'source bin/omabackup >/dev/null 2>&1; groups_ids')"
assert_eq "$GIOUT" "ok"

python3 -c "
import json
g = json.load(open('$GIH/g.json'))
g['groups'][0]['id'] = 'base\tinjected'
json.dump(g, open('$GIH/g.json', 'w'))
"

it "groups_ids refuses a manifest whose own id has an embedded tab"
OMABACKUP_GROUPS="$GIH/g.json" bash -c 'source bin/omabackup >/dev/null 2>&1; groups_ids' >/dev/null 2>&1 \
    && fail "groups_ids printed the tab-embedded id instead of refusing" || ok

# ── _restore_one refuses a source outside the worktree, defense in depth ────
# Every OTHER containment check in this file guards $dest, the write side;
# nothing guarded $src, the read side. restore_rows is the only real
# caller and only ever hands it a $rel it built from a safe walk, but this
# is checked independently rather than trusted from the plan -- the same
# reasoning _restore_contained is re-checked immediately before the write
# rather than trusted from earlier in the same function.
SOH="$(mktemp -d)"
mkdir -p "$SOH/x/worktree" "$SOH/target/.config/app" "$SOH/backup"
printf 'sensitive-host-file\n' >"$SOH/outside-secret.txt"

it "_restore_one refuses a rel that escapes the worktree via .."
HOME="$SOH/target" bash -c '
    source lib/restore.sh
    _restore_one "$1" "../../outside-secret.txt" "$HOME/.config/app/leaked.txt" "$2"
' _ "$SOH/x" "$SOH/backup" \
    && fail "_restore_one succeeded reading a source outside the worktree" || ok

it "and nothing was written"
[[ ! -e "$SOH/target/.config/app/leaked.txt" ]] \
    && ok || fail "the host file was copied into the target"

# ── a single-file group can be the TARGET of a mid-tree alias too ───────────
# f3cea20's file-level collision map only ever ran inside the flat/tree
# walk -- a single-file group (kind==tree but $wt/$prefix is not a
# directory, dest=$e directly, no walk) was left out entirely. The
# reasoning that skipped it -- "no walk, no alias risk: there is nothing to
# enumerate" -- is true about this branch PRODUCING an alias, but wrong
# about it being the TARGET of one. Two declared bases unrelated by either
# string comparison OR ancestor canonicalization (one a lone file, the
# other a tree whose artifact content includes a path that, only on the
# live target, is reached through a symlink back to the file's own
# directory) went straight through: no ambiguous verdict, "restored 2
# files", and the operator's real original gone -- not just from the live
# destination, but from the ONE backup slot meant to protect it, since
# _restore_one keys that slot on the canonical destination both sides
# alias to.
SFH="$(mktemp -d)"; SFR="$SFH/repo"
mkdir -p "$SFR/configs" "$SFR/configs/bar/alias"
git init -q "$SFR"; git -C "$SFR" config user.email t@t; git -C "$SFR" config user.name t
printf '{"from":"group A - single file"}\n' >"$SFR/configs/a.json"
printf '{"from":"group B - via alias"}\n' >"$SFR/configs/bar/alias/a.json"
git -C "$SFR" add -A && git -C "$SFR" commit -qm one
cat >"$SFH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"ga","label":"GA","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/a.json"]},
 {"id":"gb","label":"GB","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/bar"]}]}
JSON
mkdir -p "$SFH/home/.config/bar/alias"
printf '{"from":"group A - single file"}\n' >"$SFH/home/.config/a.json"
printf '{"from":"group B - via alias"}\n' >"$SFH/home/.config/bar/alias/a.json"
HOME="$SFH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$SFH/g.json" \
    OMABACKUP_STATE="$SFH/home/.state" OMABACKUP_REPO="$SFR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
SFART="$(ls -t "$SFH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
SFTGT="$(mktemp -d)"
mkdir -p "$SFTGT/.config/bar"
printf '{"ORIGINAL":"operator original"}\n' >"$SFTGT/.config/a.json"
ln -s "$SFTGT/.config" "$SFTGT/.config/bar/alias"

it "restore --apply does not lose a single-file group's original through an alias"
HOME="$SFTGT" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$SFH/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore --apply "$SFART" >/dev/null 2>&1
assert_eq "$(cat "$SFTGT/.config/a.json")" '{"ORIGINAL":"operator original"}'

# ── a symlink pointing OUTSIDE $HOME is still legitimate content ────────────
# _restore_one's own source-containment check (added to close the tab-
# injection source escape) used realpath -m on $src's FULL path, which
# follows the final component too -- and $src can legitimately BE a
# symlink whose own target lives outside $HOME (a config symlinked to a
# package-installed default is an ordinary, honest thing to back up). A PoC
# confirmed the regression this introduced: an artifact carrying exactly
# such a symlink, nothing malicious about it, was refused outright by the
# new check -- "restored 0 files, 1 could not be written" -- where the
# pre-f3cea20 _restore_one had correctly restored it as a symlink (-P,
# never followed). Checked against dirname($src) now instead, the same
# distinction _publish_contained already draws for the write side: the
# traversal this exists to catch (an injected $rel with ".." in it) is
# fully caught by the DIRECTORY containing $src resolving outside the
# worktree, without also refusing a symlink whose own target is legitimate
# content.
SLH="$(mktemp -d)"; SLR="$SLH/repo"
mkdir -p "$SLR/configs/app"
git init -q "$SLR"; git -C "$SLR" config user.email t@t; git -C "$SLR" config user.name t
ln -s /etc/hostname "$SLR/configs/app/config.link"
git -C "$SLR" add -A && git -C "$SLR" commit -qm one
cat >"$SLH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/app"]}]}
JSON
mkdir -p "$SLH/home/.config/app"
ln -s /etc/hostname "$SLH/home/.config/app/config.link"
HOME="$SLH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$SLH/g.json" \
    OMABACKUP_STATE="$SLH/home/.state" OMABACKUP_REPO="$SLR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
SLART="$(ls -t "$SLH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
SLTGT="$(mktemp -d)"

it "a symlink whose own target is outside HOME still restores as a symlink"
HOME="$SLTGT" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$SLH/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore --apply "$SLART" >/dev/null 2>&1
assert_eq "$(readlink "$SLTGT/.config/app/config.link" 2>/dev/null)" "/etc/hostname"

# ── a jq failure in _restore_verdict is refused, not taken as a real answer ─
# bv/bm/targets were all captured with their own status discarded --
# `// "0"` only degrades a query that SUCCEEDED against a null/absent
# field, and says nothing about one that never completed. A PoC (a jq stub
# that prints "0" for the watermark query and then exits 1) confirmed the
# result: the fake "0" passed the numeric-format check same as a genuine
# "no migrations" answer would, and a forward verdict was computed and
# offered against an artifact whose own manifest could not actually be
# read.
JVH="$(mktemp -d)"; JVR="$JVH/repo"
mkdir -p "$JVR/configs/hypr"
git init -q "$JVR"; git -C "$JVR" config user.email t@t; git -C "$JVR" config user.name t
printf 'bind = SUPER, Q\n' >"$JVR/configs/hypr/bindings.conf"
git -C "$JVR" add -A && git -C "$JVR" commit -qm one
cat >"$JVH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"compositor","label":"Compositor","mode":"copy","coupled":true,"critical":false,"paths":["~/.config/hypr"]}]}
JSON
mkdir -p "$JVH/home/.local/state/omarchy/migrations"
printf 'old\n' >"$JVH/home/.local/state/omarchy/migrations/123.sh"
HOME="$JVH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$JVH/g.json" \
    OMABACKUP_STATE="$JVH/home/.state" OMABACKUP_REPO="$JVR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
JVART="$(ls -t "$JVH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
JVTGT="$(mktemp -d)"
mkdir -p "$JVTGT/.local/state/omarchy/migrations"
printf 'x\n' >"$JVTGT/.local/state/omarchy/migrations/999999999.sh"
mkdir -p "$JVH/stub"
{ printf '#!/bin/bash\n'
  printf 'for a in "$@"; do [[ "$a" == *"migrationWatermark"* ]] && { echo 0; exit 1; }; done\n'
  printf 'exec %s "$@"\n' "$(command -v jq)"
} >"$JVH/stub/jq"; chmod +x "$JVH/stub/jq"

it "restore refuses when the watermark query fails, even if it printed a valid-looking 0"
PATH="$JVH/stub:$PATH" HOME="$JVTGT" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$JVH/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore "$JVART" >/dev/null 2>&1 \
    && fail "restore planned a verdict from a watermark query that failed" || ok

# ── restore_rows refuses when a generated group's own generator query fails ─
# group_field "$id" generator was nested directly inside
# $(_generated_files "$(...)") -- a failed query produced the same empty
# string _generated_files' own case statement returns for an id it
# genuinely has no entry for, and the for loop over its output ran zero
# times either way. A PoC (jq failing only the .generator query) confirmed
# the result: "0 files would be restored", with no mention at all of the
# generated package list a healthy plan would have pointed the operator at
# to read themselves.
GBH="$(mktemp -d)"; GBR="$GBH/repo"
mkdir -p "$GBR/lists"
git init -q "$GBR"; git -C "$GBR" config user.email t@t; git -C "$GBR" config user.name t
printf 'pkg1\npkg2\n' >"$GBR/lists/pkgs-explicit.txt"
git -C "$GBR" add -A && git -C "$GBR" commit -qm one
cat >"$GBH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"packages","label":"Packages","mode":"gen","coupled":false,"critical":true,"generator":"packages"}]}
JSON
mkdir -p "$GBH/home"
HOME="$GBH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$GBH/g.json" \
    OMABACKUP_STATE="$GBH/home/.state" OMABACKUP_REPO="$GBR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
GBART="$(ls -t "$GBH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
mkdir -p "$GBH/stub"
{ printf '#!/bin/bash\n'
  printf 'for a in "$@"; do [[ "$a" == *"generator"* ]] && exit 9; done\n'
  printf 'exec %s "$@"\n' "$(command -v jq)"
} >"$GBH/stub/jq"; chmod +x "$GBH/stub/jq"

it "restore refuses to plan when a generated group's own generator field cannot be queried"
PATH="$GBH/stub:$PATH" HOME="$GBH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$GBH/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore "$GBART" >/dev/null 2>&1 \
    && fail "restore planned successfully despite the generator field query failing" || ok

# ── the mirror of the source-containment fix: the WRITE side followed the ───
# ── destination's own live symlink too, refusing a file that was actually ──
# ── safe to restore ──────────────────────────────────────────────────────────
# _restore_contained checked realpath -m on the whole $dest, same as $src
# did before its own fix -- and a live destination that is STILL a
# symlink to a package-installed default (the exact file most likely to
# need restoring on a recovery machine: the one the operator never
# customized away from its default) was refused as "resolves outside the
# target home", even though _restore_one's actual write (rm -f, then
# cp -Pp) never follows that symlink -- it unlinks first. A PoC (the
# write mechanism simulated directly, outside restore_rows entirely)
# confirmed the refusal protected nothing: the write always lands a
# regular file inside $HOME regardless of what the pre-existing symlink
# pointed to. Checked against dirname($dest) now, the identical
# distinction the source-side fix already draws.
DSH="$(mktemp -d)"; DSR="$DSH/repo"
mkdir -p "$DSR/configs/alacritty"
git init -q "$DSR"; git -C "$DSR" config user.email t@t; git -C "$DSR" config user.name t
printf 'font = "customized by user"\n' >"$DSR/configs/alacritty/alacritty.toml"
git -C "$DSR" add -A && git -C "$DSR" commit -qm one
cat >"$DSH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"terminal","label":"Terminal","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/alacritty"]}]}
JSON
mkdir -p "$DSH/home/.config/alacritty"
printf 'font = "customized by user"\n' >"$DSH/home/.config/alacritty/alacritty.toml"
HOME="$DSH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$DSH/g.json" \
    OMABACKUP_STATE="$DSH/home/.state" OMABACKUP_REPO="$DSR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
DSART="$(ls -t "$DSH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
DSTGT="$(mktemp -d)"; DSVENDOR="$(mktemp -d)"
mkdir -p "$DSTGT/.config/alacritty"
printf 'font = "package default"\n' >"$DSVENDOR/alacritty.toml"
ln -s "$DSVENDOR/alacritty.toml" "$DSTGT/.config/alacritty/alacritty.toml"

it "a destination that is a live symlink to outside HOME still restores"
DSPLAN="$(HOME="$DSTGT" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$DSH/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore "$DSART" 2>&1)"
assert_contains "$DSPLAN" "1 files would be restored"

it "and --apply writes the real content, not through the symlink"
HOME="$DSTGT" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$DSH/rstate2" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore --apply "$DSART" >/dev/null 2>&1
assert_eq "$(cat "$DSTGT/.config/alacritty/alacritty.toml")" 'font = "customized by user"'

it "and the package default the symlink pointed to is untouched"
assert_eq "$(cat "$DSVENDOR/alacritty.toml")" 'font = "package default"'

# ── the backup slot for that same file is filed under its OWN path, not ─────
# ── under wherever the live symlink used to point ───────────────────────────
# dest_rp was realpath -m on the whole $dest -- the same full-path
# resolution the containment check just stopped doing, still present in
# the backup-slot computation right below it. A live symlink at $dest
# made the backup land under the SYMLINK'S TARGET path instead of under
# $dest's own -- contained inside $backup still (the strip only removes a
# literal $HOME/), but archived under a name nobody restoring by hand
# would think to look for: the real original silently mislaid rather than
# protected. Fixed the same way: dirname($dest) resolved, plus $dest's
# own lexical basename, not realpath -m on the whole path.
it "and the pre-existing content backs up under its own path, not the symlink's target"
[[ -n "$(find "$DSH/rstate2/restore" -path '*/replaced/.config/alacritty/alacritty.toml' 2>/dev/null)" ]] \
    && ok || fail "the backup was not filed at replaced/.config/alacritty/alacritty.toml"

# ── the backup slot's $HOME strip has to match what containment compared ────
# ── against, not $HOME's own raw spelling ────────────────────────────────────
# dest_rp (the backup-slot path) is canonicalized via realpath -m; the strip
# that turns it into a $backup-relative path used the raw $HOME string.
# _restore_contained resolves ITS base with realpath -e "$HOME" a few
# lines up -- when $HOME itself has a symlink component (an ordinary
# /home/user -> /mnt/data/user layout) or --into was given a relative
# path, the canonical $dest_rp never literally starts with the raw $HOME
# string, the `#"$HOME"/` strip removes nothing, and the backup landed at
# replaced/<dest_rp's entire absolute path> instead of the expected
# replaced/.config/.../file -- contained inside $backup still, but filed
# under a name nobody restoring by hand would think to look for. The
# exact same mislaying class the leaf-symlink fix above just closed,
# reopened by the other half of what "$HOME" can mean.
HLH="$(mktemp -d)"; HLREAL="$HLH/real"; mkdir -p "$HLREAL"
ln -s "$HLREAL" "$HLH/link"
HLR="$HLH/repo"
mkdir -p "$HLR/configs/alacritty"
git init -q "$HLR"; git -C "$HLR" config user.email t@t; git -C "$HLR" config user.name t
printf 'font = "customized"\n' >"$HLR/configs/alacritty/alacritty.toml"
git -C "$HLR" add -A && git -C "$HLR" commit -qm one
cat >"$HLH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"terminal","label":"Terminal","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/alacritty"]}]}
JSON
mkdir -p "$HLREAL/.config/alacritty"
printf 'font = "customized"\n' >"$HLREAL/.config/alacritty/alacritty.toml"
HOME="$HLH/link" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$HLH/g.json" \
    OMABACKUP_STATE="$HLREAL/.state" OMABACKUP_REPO="$HLR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
HLART="$(ls -t "$HLREAL/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
printf 'font = "ORIGINAL"\n' >"$HLREAL/.config/alacritty/alacritty.toml"

it "the backup slot lands correctly even when HOME itself has a symlink component"
HOME="$HLH/link" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$HLREAL/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore --apply "$HLART" >/dev/null 2>&1
[[ -n "$(find "$HLREAL/rstate/restore" -path '*/replaced/.config/alacritty/alacritty.toml' 2>/dev/null)" ]] \
    && ok || fail "the backup was not filed at replaced/.config/alacritty/alacritty.toml"

# ── an artifact declaring a mode this build does not understand is refused ──
# restore_rows checks gm=="gen" explicitly and treats everything else as an
# ordinary copy-restore -- no validation that the artifact's own mode is
# one this build actually understands, unlike assert_manifest_understood's
# KNOWN_MODES check at collect time (never run against the ARTIFACT's own
# manifest). A PoC (a group manifest hand-edited to mode:future-mode)
# confirmed the result: restore planned and offered a plain restore row
# for it, exactly as though an unknown mode were simply mode:copy.
UMH="$(mktemp -d)"; UMR="$UMH/repo"
mkdir -p "$UMR/configs/foo"
git init -q "$UMR"; git -C "$UMR" config user.email t@t; git -C "$UMR" config user.name t
printf 'x\n' >"$UMR/configs/foo/file"
git -C "$UMR" add -A && git -C "$UMR" commit -qm one
cat >"$UMH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"g","label":"G","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/foo"]}]}
JSON
mkdir -p "$UMH/home/.config/foo"
printf 'x\n' >"$UMH/home/.config/foo/file"
HOME="$UMH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$UMH/g.json" \
    OMABACKUP_STATE="$UMH/home/.state" OMABACKUP_REPO="$UMR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
UMART="$(ls -t "$UMH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
UMX="$(mktemp -d)"; tar -C "$UMX" -xf <(zstd -dc "$UMART")
python3 -c "
import json
p = '$UMX/tool/groups.default.json'
g = json.load(open(p))
g['groups'][0]['mode'] = 'future-mode'
json.dump(g, open(p,'w'))
"
( cd "$UMX" && find . -type f ! -name SHA256SUMS -print0 | xargs -0 sha256sum >SHA256SUMS )
UMTAMPERED="$UMH/tampered.tar.zst"
tar -C "$UMX" -cf - . | zstd -q -19 -T0 -o "$UMTAMPERED"

it "restore refuses an artifact whose manifest declares an unknown mode"
HOME="$UMH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$UMH/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore "$UMTAMPERED" >/dev/null 2>&1 \
    && fail "restore planned successfully against an unknown mode" || ok

# ── a targets-list parse failure is a distinct refusal, not a quarantine ────
# _restore_in_range's own inner jq parse of $targets had no status a caller
# could check -- a failure there produced the same empty read-loop a
# genuinely out-of-range version does, and _restore_verdict printed a
# `quarantine` verdict citing a real-looking (but never actually checked)
# incompatibility instead of refusing to plan at all.
TPH="$(mktemp -d)"; TPR="$TPH/repo"
mkdir -p "$TPR/configs/hypr"
git init -q "$TPR"; git -C "$TPR" config user.email t@t; git -C "$TPR" config user.name t
printf 'bind = SUPER, Q\n' >"$TPR/configs/hypr/bindings.conf"
git -C "$TPR" add -A && git -C "$TPR" commit -qm one
cat >"$TPH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"compositor","label":"Compositor","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/hypr"]}]}
JSON
mkdir -p "$TPH/home"
HOME="$TPH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$TPH/g.json" \
    OMABACKUP_STATE="$TPH/home/.state" OMABACKUP_REPO="$TPR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
TPART="$(ls -t "$TPH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
mkdir -p "$TPH/stub"
cat >"$TPH/stub/jq" <<STUBEOF
#!/bin/bash
for a in "\$@"; do
    if [[ "\$a" == '.[]?' ]]; then exit 9; fi
done
exec $(command -v jq) "\$@"
STUBEOF
chmod +x "$TPH/stub/jq"

it "restore does not report quarantine when the targets list itself fails to parse"
TPOUT="$(PATH="$TPH/stub:$PATH" HOME="$TPH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$TPH/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore "$TPART" 2>&1)"
[[ "$TPOUT" != *quarantine* ]] \
    && ok || fail "reported quarantine instead of a distinct parse failure: $TPOUT"

it "and refuses to plan instead"
assert_contains "$TPOUT" "could not be confirmed"

# ── a declared tree whose root is itself a symlink in the artifact ──────────
# find does not dereference a symlink given as its OWN starting argument
# unless told to with -L or a trailing slash. A tree-kind $prefix that is
# itself a symlink to a directory (an ordinary, git-trackable "shared
# config" pattern) made find report only the symlink's own path -- never
# descending into it -- and the prefix-strip a line below never matched
# an entry with no "/" after $wt/$prefix at all, since there was none. A
# PoC (worktree/configs/foo -> bar, a real tracked symlink) confirmed the
# result: one garbled row ("~/.config/foo//tmp/.../worktree/configs/foo"),
# and every real file actually inside the symlinked tree invisible to the
# plan entirely -- not applied at all, not even reported, unlike a leaf
# symlink (already correctly preserved as content).
SRH="$(mktemp -d)"; SRR="$SRH/repo"
mkdir -p "$SRR/configs/bar"
git init -q "$SRR"; git -C "$SRR" config user.email t@t; git -C "$SRR" config user.name t
printf 'content1\n' >"$SRR/configs/bar/file1"
printf 'content2\n' >"$SRR/configs/bar/file2"
( cd "$SRR/configs" && ln -s bar foo )
git -C "$SRR" add -A && git -C "$SRR" commit -qm one
cat >"$SRH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"g","label":"G","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/foo"]}]}
JSON
mkdir -p "$SRH/home/.config/bar"
printf 'content1\n' >"$SRH/home/.config/bar/file1"
printf 'content2\n' >"$SRH/home/.config/bar/file2"
( cd "$SRH/home/.config" && ln -s bar foo )
HOME="$SRH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$SRH/g.json" \
    OMABACKUP_STATE="$SRH/home/.state" OMABACKUP_REPO="$SRR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle >/dev/null 2>&1
SRART="$(ls -t "$SRH/home/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"

it "a tree whose declared root is itself a symlink in the artifact restores its real files"
SRPLAN="$(HOME="$SRH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$SRH/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore "$SRART" 2>&1)"
assert_contains "$SRPLAN" "2 files would be restored"

it "and both real files are named cleanly, not a garbled worktree path"
assert_contains "$SRPLAN" "~/.config/foo/file1"

# ── a nested --into target's PARENT directories are cleaned up too ──────────
# Bare `rmdir "$into"` only ever removed the FINAL component mkdir -p
# created -- a --into target nested under parents that did not exist yet
# (--into a/b/target, none of a, a/b, or a/b/target there before) left a/
# and a/b/ behind at every cleanup site, including the ordinary plan-only
# run at the very end of this command, which promises "nothing was
# written." A PoC against a real artifact confirmed the result: rc=0, the
# target itself absent, but its two parent directories left on disk.
NIH="$(mktemp -d)"; NIART="$(_res_build "$NIH" '["3.*","4.*"]')"
NIINTO="$NIH/a/b/target"

it "a plan with a nested --into target cleans up the parents it created too"
HOME="$NIH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$NIH/rstate" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" restore --into "$NIINTO" "$NIART" >/dev/null 2>&1
[[ ! -e "$NIH/a" ]] \
    && ok || fail "the --into target's parent directories were left behind: $(find "$NIH/a" 2>/dev/null)"

# ── the terminal handoff must survive an empty destination list ─────────────
# `omarchy-launch-tui` closes its terminal when the command exits. Before this
# regression, `restore` printed its no-bundle message and returned 1 at the
# first screen, so the user saw a terminal flash and disappear with no way to
# configure a destination or retry. The helper drives a real PTY through a
# FIFO and waits for prompts, rather than relying on sleeps and pre-buffered
# input.
_restore_tui_start() {
    local log="$1" fifo="$2" command="$3"
    mkfifo "$fifo"
    # Capture stdout directly so the driver can observe prompts while the
    # child is alive. `script`'s typescript file is flushed only on exit.
    script -qec "$command" /dev/null <"$fifo" >"$log" 2>&1 &
    RESTORE_TUI_PID=$!
    RESTORE_TUI_DRIVER_FAILED=0
    exec 9>"$fifo"
}

_restore_tui_wait_for() {
    local log="$1" needle="$2" i
    for ((i = 0; i < 200; i++)); do
        [[ -f "$log" ]] && grep -Fq -- "$needle" "$log" && return 0
        sleep 0.05
    done
    RESTORE_TUI_DRIVER_FAILED=1
    return 1
}

_restore_tui_wait_count() {
    local log="$1" needle="$2" wanted="$3" i count
    for ((i = 0; i < 200; i++)); do
        count="$(grep -F -o -- "$needle" "$log" 2>/dev/null | wc -l)"
        (( count >= wanted )) && return 0
        sleep 0.05
    done
    RESTORE_TUI_DRIVER_FAILED=1
    return 1
}

_restore_tui_send() {
    if ! kill -0 "$RESTORE_TUI_PID" 2>/dev/null; then
        RESTORE_TUI_DRIVER_FAILED=1
        return 1
    fi
    # A stale PID can still be a zombie between the prompt poll and this
    # write. Keep a broken FIFO write from delivering SIGPIPE to the spec
    # shell itself; the caller then records the failed interaction normally.
    ( printf '%s' "$1" >&9 ) 2>/dev/null || {
        RESTORE_TUI_DRIVER_FAILED=1
        return 1
    }
}

_restore_tui_finish() {
    exec 9>&-
    local i state
    for ((i = 0; i < 200; i++)); do
        state="$(ps -o stat= -p "$RESTORE_TUI_PID" 2>/dev/null)"
        if [[ -z "$state" || "$state" == *Z* ]]; then
            wait "$RESTORE_TUI_PID"
            local rc=$?
            (( RESTORE_TUI_DRIVER_FAILED )) && return 125
            return "$rc"
        fi
        sleep 0.05
    done
    kill -TERM "$RESTORE_TUI_PID" 2>/dev/null || true
    sleep 0.2
    kill -KILL "$RESTORE_TUI_PID" 2>/dev/null || true
    wait "$RESTORE_TUI_PID" 2>/dev/null
    return 124
}

RTUIH="$(mktemp -d)"
RTUILOG="$RTUIH/restore-tui.log"
RTUIFIFO="$RTUIH/input"
_restore_tui_start "$RTUILOG" "$RTUIFIFO" \
    "env HOME='$RTUIH/home' OMABACKUP_ROOT='$PWD' OMABACKUP_STATE='$RTUIH/state' \
         OMABACKUP_DESTINATIONS='$RTUIH/missing.json' XDG_RUNTIME_DIR=/nonexistent \
         '$OB' restore"
_restore_tui_wait_for "$RTUILOG" 'Choose [1/2/q]:' && _restore_tui_send $'q\n'
_restore_tui_finish; RTUIRC=$?
RTUIOUT="$(cat -- "$RTUILOG")"

it "restore keeps the terminal open when no valid backup bundles exist"
[[ "$RTUIRC" -eq 0 ]] && ok || fail "restore exited $RTUIRC before the user chose to quit"
assert_contains "$RTUIOUT" "No backups found"
it "restore explains the available no-bundle actions"
assert_contains "$RTUIOUT" "Try again"
assert_contains "$RTUIOUT" "Open backup settings"
assert_contains "$RTUIOUT" "q) Cancel"

RTUIESCLOG="$RTUIH/restore-escape.log"
RTUIESCFIFO="$RTUIH/restore-escape.input"
_restore_tui_start "$RTUIESCLOG" "$RTUIESCFIFO" \
    "env HOME='$RTUIH/escape-home' OMABACKUP_ROOT='$PWD' OMABACKUP_STATE='$RTUIH/escape-state' \
         OMABACKUP_DESTINATIONS='$RTUIH/missing.json' XDG_RUNTIME_DIR=/nonexistent '$OB' restore"
_restore_tui_wait_for "$RTUIESCLOG" 'Choose [1/2/q]:' && _restore_tui_send $'\033'
# The reader briefly waits to distinguish a bare Escape from ESC+[...]. Give
# that bounded look-ahead time to expire before closing the driver's fd.
/usr/bin/sleep 0.1
_restore_tui_finish; RTUIESCRC=$?
RTUIESCOUT="$(cat -- "$RTUIESCLOG")"

it "Escape cancels the Restore TUI immediately in a real terminal"
[[ "$RTUIESCRC" -eq 0 ]] && ok || fail "restore did not exit cleanly after the immediate Escape key"
assert_contains "$RTUIESCOUT" "Restore cancelled"

RTUIARROWLOG="$RTUIH/restore-arrow.log"
RTUIARROWFIFO="$RTUIH/restore-arrow.input"
_restore_tui_start "$RTUIARROWLOG" "$RTUIARROWFIFO" \
    "env HOME='$RTUIH/arrow-home' OMABACKUP_ROOT='$PWD' OMABACKUP_STATE='$RTUIH/arrow-state' \
         OMABACKUP_DESTINATIONS='$RTUIH/missing.json' XDG_RUNTIME_DIR=/nonexistent '$OB' restore"
_restore_tui_wait_for "$RTUIARROWLOG" 'Choose [1/2/q]:' && _restore_tui_send $'\033[A'
/usr/bin/sleep 0.1
_restore_tui_send $'x\nq\n' || true
_restore_tui_finish; RTUIARROWRC=$?
RTUIARROWOUT="$(cat -- "$RTUIARROWLOG")"

it "an arrow key does not cancel the Restore TUI"
[[ "$RTUIARROWRC" -eq 0 ]] && assert_contains "$RTUIARROWOUT" "Please choose 1, 2 or q." \
    || fail "Restore treated an arrow-key sequence as Escape"

# Retry must actually re-enter the loop; labels alone are not enough to prove
# that the action is wired.
RTUIRETRYLOG="$RTUIH/restore-retry.log"
RTUIRETRYFIFO="$RTUIH/retry-input"
_restore_tui_start "$RTUIRETRYLOG" "$RTUIRETRYFIFO" \
    "env HOME='$RTUIH/retry-home' OMABACKUP_ROOT='$PWD' OMABACKUP_STATE='$RTUIH/retry-state' \
         OMABACKUP_DESTINATIONS='$RTUIH/missing.json' XDG_RUNTIME_DIR=/nonexistent \
         '$OB' restore"
_restore_tui_wait_for "$RTUIRETRYLOG" 'Choose [1/2/q]:' && _restore_tui_send $'1\n'
_restore_tui_wait_count "$RTUIRETRYLOG" 'No backups found.' 2 && _restore_tui_send $'q\n'
_restore_tui_finish; RTUIRETRYRC=$?
RTUIRETRYOUT="$(cat -- "$RTUIRETRYLOG")"

it "restore executes Try again before accepting quit"
[[ "$RTUIRETRYRC" -eq 0 ]] && ok || fail "retry session exited $RTUIRETRYRC"
it "restore renders the no-bundle screen again after Try again"
[[ "$(grep -F -o 'No backups found.' "$RTUIRETRYLOG" | wc -l)" -ge 2 ]] \
    && ok || fail "Try again did not render a second no-bundle screen"

# Settings is a real recovery action too: it enters the config TUI, then
# returns to the restore recovery menu until the user explicitly quits.
RTUISETTINGLOG="$RTUIH/restore-settings.log"
RTUISETTINGFIFO="$RTUIH/settings-input"
_restore_tui_start "$RTUISETTINGLOG" "$RTUISETTINGFIFO" \
    "env HOME='$RTUIH/settings-home' OMABACKUP_ROOT='$PWD' OMABACKUP_STATE='$RTUIH/settings-state' \
         OMABACKUP_DESTINATIONS='$RTUIH/missing.json' OMABACKUP_SYSTEMCTL=/nonexistent \
         XDG_RUNTIME_DIR=/nonexistent '$OB' restore"
_restore_tui_wait_for "$RTUISETTINGLOG" 'Choose [1/2/q]:' && _restore_tui_send $'2\n'
_restore_tui_wait_for "$RTUISETTINGLOG" 'OmaBackup configuration' && _restore_tui_send $'q\n'
_restore_tui_wait_count "$RTUISETTINGLOG" 'Choose [1/2/q]:' 2 && _restore_tui_send $'q\n'
_restore_tui_finish; RTUISETTINGRC=$?
RTUISETTINGOUT="$(cat -- "$RTUISETTINGLOG")"

it "restore opens Settings from the recovery menu and returns"
[[ "$RTUISETTINGRC" -eq 0 ]] && ok || fail "Settings recovery session exited $RTUISETTINGRC"
assert_contains "$RTUISETTINGOUT" "OmaBackup configuration"
it "restore returns to the recovery menu after Settings"
[[ "$(grep -F -o 'Choose [1/2/q]:' "$RTUISETTINGLOG" | wc -l)" -ge 2 ]] \
    && ok || fail "Settings did not return to the recovery menu"

# An invalid confirmation is not an explicit cancel. It must leave the user at
# the same confirmation step, otherwise one typo closes the terminal and
# discards the restore context.
RTUIC="$(mktemp -d)"
RTUICDEST="$RTUIC/destination"; mkdir -p "$RTUICDEST"
# The artifact cache uses a content hash as its filename. A dir destination
# contains the published, human-facing bundle name, so use that shape here to
# exercise the same discovery path as a real push.
cp -- "$RART" "$RTUICDEST/omabackup-test-20260829-000000.tar.zst"
printf '{"schemaVersion":1,"destinations":[{"id":"local","type":"dir","path":"%s","keep":5,"enabled":true,"note":null}]}\n' \
    "$RTUICDEST" >"$RTUIC/destinations.json"
RTUICLOG="$RTUIC/restore-tui.log"
RTUICFIFO="$RTUIC/input"
_restore_tui_start "$RTUICLOG" "$RTUICFIFO" \
    "env HOME='$RTUIC/home' OMABACKUP_ROOT='$PWD' OMABACKUP_GROUPS='$RH/g.json' \
         OMABACKUP_STATE='$RTUIC/state' OMABACKUP_DESTINATIONS='$RTUIC/destinations.json' \
         XDG_RUNTIME_DIR=/nonexistent '$OB' restore"
_restore_tui_wait_for "$RTUICLOG" 'Choose a backup number' && _restore_tui_send $'1\n'
_restore_tui_wait_for "$RTUICLOG" 'Choose [1/2/3/q]:' && _restore_tui_send $'1\n'
_restore_tui_wait_for "$RTUICLOG" 'Apply this plan to the selected folder?' && _restore_tui_send $'maybe\n'
_restore_tui_wait_for "$RTUICLOG" 'Please answer y to apply or n to cancel.' && _restore_tui_send $'q\n'
_restore_tui_finish; RTUICRC=$?
RTUICOUT="$(cat -- "$RTUICLOG")"

it "restore keeps the confirmation step after invalid input"
[[ "$RTUICRC" -eq 0 ]] && ok || fail "restore exited $RTUICRC after invalid confirmation input"
assert_contains "$RTUICOUT" "Please answer y to apply or n to cancel."
it "restore shows the confirmation prompt again after invalid input"
[[ "$(grep -F -o 'Apply this plan to the selected folder?' "$RTUICLOG" | wc -l)" -ge 2 ]] \
    && ok || fail "invalid confirmation did not return to the same prompt"

# Choosing a custom path that resolves to HOME must receive the same strong
# guard as the explicit HOME option. The confirmation policy follows the
# resolved target, not the menu key the user happened to press.
RTUIHOMELOG="$RTUIC/restore-home-target.log"
RTUIHOMEFIFO="$RTUIC/home-input"
mkdir -p "$RTUIC/home"
ln -s "$RTUIC/home" "$RTUIC/home-alias"
_restore_tui_start "$RTUIHOMELOG" "$RTUIHOMEFIFO" \
    "env HOME='$RTUIC/home' OMABACKUP_ROOT='$PWD' OMABACKUP_GROUPS='$RH/g.json' \
         OMABACKUP_STATE='$RTUIC/home-state' OMABACKUP_DESTINATIONS='$RTUIC/destinations.json' \
         XDG_RUNTIME_DIR=/nonexistent '$OB' restore"
_restore_tui_wait_for "$RTUIHOMELOG" 'Choose a backup number' && _restore_tui_send $'1\n'
_restore_tui_wait_for "$RTUIHOMELOG" 'Choose [1/2/3/q]:' && _restore_tui_send $'3\n'
_restore_tui_wait_for "$RTUIHOMELOG" 'Absolute target folder:' && _restore_tui_send "$RTUIC/home-alias"$'\n'
_restore_tui_wait_for "$RTUIHOMELOG" 'Type RESTORE to apply' && _restore_tui_send $'maybe\n'
_restore_tui_wait_for "$RTUIHOMELOG" 'Please type RESTORE to apply or N to cancel.' && _restore_tui_send $'q\n'
_restore_tui_finish; RTUIHOMERC=$?
RTUIHOMEOUT="$(cat -- "$RTUIHOMELOG")"

it "restore requires the strong confirmation for a HOME alias"
[[ "$RTUIHOMERC" -eq 0 ]] && ok || fail "restore exited $RTUIHOMERC after the custom HOME target confirmation"
assert_contains "$RTUIHOMEOUT" "Please type RESTORE to apply or N to cancel."

# The explicit HOME option remains a separate branch and must keep the strong
# confirmation after the TUI canonicalizes it as --into HOME.
RTUIEXPLICITLOG="$RTUIC/restore-explicit-home.log"
RTUIEXPLICITFIFO="$RTUIC/explicit-home-input"
_restore_tui_start "$RTUIEXPLICITLOG" "$RTUIEXPLICITFIFO" \
    "env HOME='$RTUIC/home' OMABACKUP_ROOT='$PWD' OMABACKUP_GROUPS='$RH/g.json' \
         OMABACKUP_STATE='$RTUIC/explicit-state' OMABACKUP_DESTINATIONS='$RTUIC/destinations.json' \
         XDG_RUNTIME_DIR=/nonexistent '$OB' restore"
_restore_tui_wait_for "$RTUIEXPLICITLOG" 'Choose a backup number' && _restore_tui_send $'1\n'
_restore_tui_wait_for "$RTUIEXPLICITLOG" 'Choose [1/2/3/q]:' && _restore_tui_send $'2\n'
_restore_tui_wait_for "$RTUIEXPLICITLOG" 'Type RESTORE to apply' && _restore_tui_send $'maybe\n'
_restore_tui_wait_for "$RTUIEXPLICITLOG" 'Please type RESTORE to apply or N to cancel.' && _restore_tui_send $'q\n'
_restore_tui_finish; RTUIEXPLICITRC=$?
RTUIEXPLICITOUT="$(cat -- "$RTUIEXPLICITLOG")"

it "restore keeps the strong confirmation for explicit HOME"
[[ "$RTUIEXPLICITRC" -eq 0 ]] && ok || fail "explicit HOME session exited $RTUIEXPLICITRC"
assert_contains "$RTUIEXPLICITOUT" "Please type RESTORE to apply or N to cancel."

# An overlarge decimal must be rejected before Bash arithmetic can wrap it to
# a valid-looking array index.
RTUIOVERFLOWLOG="$RTUIC/restore-overflow.log"
RTUIOVERFLOWFIFO="$RTUIC/overflow-input"
_restore_tui_start "$RTUIOVERFLOWLOG" "$RTUIOVERFLOWFIFO" \
    "env HOME='$RTUIC/home' OMABACKUP_ROOT='$PWD' OMABACKUP_GROUPS='$RH/g.json' \
         OMABACKUP_STATE='$RTUIC/overflow-state' OMABACKUP_DESTINATIONS='$RTUIC/destinations.json' \
         XDG_RUNTIME_DIR=/nonexistent '$OB' restore"
_restore_tui_wait_for "$RTUIOVERFLOWLOG" 'Choose a backup number' && _restore_tui_send $'18446744073709551617\n'
_restore_tui_wait_for "$RTUIOVERFLOWLOG" 'There is no backup with that number' && _restore_tui_send $'q\n'
_restore_tui_finish; RTUIOVERFLOWRC=$?
RTUIOVERFLOWOUT="$(cat -- "$RTUIOVERFLOWLOG")"

it "restore rejects an overlarge backup number without wrapping"
[[ "$RTUIOVERFLOWRC" -eq 0 ]] && ok || fail "restore exited $RTUIOVERFLOWRC after an overlarge backup number"
assert_contains "$RTUIOVERFLOWOUT" "There is no backup with that number"

# The preview can fail after the artifact was listed if the shared folder
# changes underneath the UI. Prompt synchronization makes the removal happen
# only after the selection screen has definitely rendered.
RTUIPREVLOG="$RTUIC/restore-preview-failure.log"
RTUIPREVFIFO="$RTUIC/preview-input"
_restore_tui_start "$RTUIPREVLOG" "$RTUIPREVFIFO" \
    "env HOME='$RTUIC/home' OMABACKUP_ROOT='$PWD' OMABACKUP_GROUPS='$RH/g.json' \
         OMABACKUP_STATE='$RTUIC/preview-state' OMABACKUP_DESTINATIONS='$RTUIC/destinations.json' \
         XDG_RUNTIME_DIR=/nonexistent '$OB' restore"
_restore_tui_wait_for "$RTUIPREVLOG" 'Choose a backup number' && _restore_tui_send $'1\n'
_restore_tui_wait_for "$RTUIPREVLOG" 'Choose [1/2/3/q]:' && rm -f -- "$RTUICDEST/omabackup-test-20260829-000000.tar.zst" && _restore_tui_send $'1\n'
_restore_tui_wait_for "$RTUIPREVLOG" 'This backup could not be previewed' && _restore_tui_send $'q\n'
_restore_tui_finish; RTUIPREVRC=$?
RTUIPREVOUT="$(cat -- "$RTUIPREVLOG")"

it "restore keeps its recovery menu when the selected artifact disappears"
[[ "$RTUIPREVRC" -eq 0 ]] && ok || fail "restore exited $RTUIPREVRC after the preview artifact disappeared"
assert_contains "$RTUIPREVOUT" "This backup could not be previewed"
assert_contains "$RTUIPREVOUT" "The source may have changed or become unavailable."
assert_contains "$RTUIPREVOUT" "q) Cancel"
assert_not_contains "$RTUIPREVOUT" "?[0;31m"

# The source-copy failure above is distinct from a valid-looking source whose
# private snapshot is unreadable by restore. Corrupt the snapshot in the head
# wrapper so the child restore command, rather than the TUI's copy step, owns
# the preview failure branch.
cp -- "$RART" "$RTUICDEST/omabackup-test-20260829-000009.tar.zst"
mkdir -p "$RTUIC/corrupt-snapshot-stub"
cat >"$RTUIC/corrupt-snapshot-stub/head" <<'STUBEOF'
#!/bin/bash
if [[ "${1:-}" == "-c" ]]; then
    /usr/bin/dd if=/dev/zero bs=1 count="$2" status=none
else
    exec /usr/bin/head "$@"
fi
STUBEOF
chmod +x "$RTUIC/corrupt-snapshot-stub/head"
RTUICORRUPTLOG="$RTUIC/restore-corrupt-snapshot.log"
RTUICORRUPTFIFO="$RTUIC/corrupt-snapshot-input"
_restore_tui_start "$RTUICORRUPTLOG" "$RTUICORRUPTFIFO" \
    "env PATH='$RTUIC/corrupt-snapshot-stub:$PATH' HOME='$RTUIC/home' OMABACKUP_ROOT='$PWD' OMABACKUP_GROUPS='$RH/g.json' \
         OMABACKUP_STATE='$RTUIC/corrupt-snapshot-state' OMABACKUP_DESTINATIONS='$RTUIC/destinations.json' \
         XDG_RUNTIME_DIR=/nonexistent '$OB' restore"
_restore_tui_wait_for "$RTUICORRUPTLOG" 'Choose a backup number' && _restore_tui_send $'1\n'
_restore_tui_wait_for "$RTUICORRUPTLOG" 'Choose [1/2/3/q]:' && _restore_tui_send $'1\n'
_restore_tui_wait_for "$RTUICORRUPTLOG" 'This backup could not be previewed' && _restore_tui_send $'q\n'
_restore_tui_finish; RTUICORRUPTRC=$?
RTUICORRUPTOUT="$(cat -- "$RTUICORRUPTLOG")"

it "restore keeps its recovery menu when the private snapshot cannot be read"
[[ "$RTUICORRUPTRC" -eq 0 ]] && ok || fail "corrupt-snapshot session exited $RTUICORRUPTRC"
assert_contains "$RTUICORRUPTOUT" "This backup could not be previewed."
assert_contains "$RTUICORRUPTOUT" "q) Cancel"

# /proc is an existing, read-only target: preview can describe the writes,
# while apply fails at mkdir. That exercises the post-apply recovery path
# without changing any test or host data.
cp -- "$RART" "$RTUICDEST/omabackup-test-20260829-000001.tar.zst"
RTUIAPPLYLOG="$RTUIC/restore-apply-failure.log"
RTUIAPPLYFIFO="$RTUIC/apply-input"
_restore_tui_start "$RTUIAPPLYLOG" "$RTUIAPPLYFIFO" \
    "env HOME='$RTUIC/home' OMABACKUP_ROOT='$PWD' OMABACKUP_GROUPS='$RH/g.json' \
         OMABACKUP_STATE='$RTUIC/apply-state' OMABACKUP_DESTINATIONS='$RTUIC/destinations.json' \
         XDG_RUNTIME_DIR=/nonexistent '$OB' restore"
_restore_tui_wait_for "$RTUIAPPLYLOG" 'Choose a backup number' && _restore_tui_send $'1\n'
_restore_tui_wait_for "$RTUIAPPLYLOG" 'Choose [1/2/3/q]:' && _restore_tui_send $'3\n'
_restore_tui_wait_for "$RTUIAPPLYLOG" 'Absolute target folder:' && _restore_tui_send $'/proc\n'
_restore_tui_wait_for "$RTUIAPPLYLOG" 'Apply this plan to the selected folder?' && _restore_tui_send $'y\n'
_restore_tui_wait_for "$RTUIAPPLYLOG" 'The restore did not finish successfully' && _restore_tui_send $'maybe\n'
_restore_tui_wait_for "$RTUIAPPLYLOG" 'Please choose 1, 2 or q.' && _restore_tui_send $'q\n'
_restore_tui_finish; RTUIAPPLYRC=$?
RTUIAPPLYOUT="$(cat -- "$RTUIAPPLYLOG")"

it "restore keeps its recovery menu when apply cannot write the target"
[[ "$RTUIAPPLYRC" -eq 0 ]] && ok || fail "restore exited $RTUIAPPLYRC after apply failed"
assert_contains "$RTUIAPPLYOUT" "The restore did not finish successfully"
assert_contains "$RTUIAPPLYOUT" "Please choose 1, 2 or q."

# Force the path's parent to change between the preview and the apply. The
# realpath wrapper swaps it on the second exact -m lookup, which is the TUI's
# revalidation call; no timing race is involved.
RTUISWAPBASE="$RTUIC/swap"
mkdir -p "$RTUISWAPBASE"
mkdir -p "$RTUIC/stub"
cat >"$RTUIC/stub/realpath" <<'STUBEOF'
#!/bin/bash
last="${@: -1}"
if [[ "$1" == "-m" && "$last" == "$OMABACKUP_TEST_SWAP_BASE/target" ]]; then
    count_file="$OMABACKUP_TEST_SWAP_BASE/count"
    count=0
    [[ -f "$count_file" ]] && count="$(cat "$count_file")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    if [[ "$count" == 2 ]]; then
        mv -- "$OMABACKUP_TEST_SWAP_BASE" "$OMABACKUP_TEST_SWAP_BASE-real"
        ln -s -- "$OMABACKUP_TEST_SWAP_HOME" "$OMABACKUP_TEST_SWAP_BASE"
    fi
fi
exec /usr/bin/realpath "$@"
STUBEOF
chmod +x "$RTUIC/stub/realpath"
cp -- "$RART" "$RTUICDEST/omabackup-test-20260829-000002.tar.zst"
RTUISWAPLOG="$RTUIC/restore-target-changed.log"
RTUISWAPFIFO="$RTUIC/target-changed-input"
_restore_tui_start "$RTUISWAPLOG" "$RTUISWAPFIFO" \
    "env PATH='$RTUIC/stub:$PATH' HOME='$RTUIC/home' OMABACKUP_ROOT='$PWD' \
         OMABACKUP_GROUPS='$RH/g.json' OMABACKUP_TEST_SWAP_BASE='$RTUISWAPBASE' \
         OMABACKUP_TEST_SWAP_HOME='$RTUIC/home' OMABACKUP_STATE='$RTUIC/swap-state' \
         OMABACKUP_DESTINATIONS='$RTUIC/destinations.json' XDG_RUNTIME_DIR=/nonexistent \
         '$OB' restore"
_restore_tui_wait_for "$RTUISWAPLOG" 'Choose a backup number' && _restore_tui_send $'1\n'
_restore_tui_wait_for "$RTUISWAPLOG" 'Choose [1/2/3/q]:' && _restore_tui_send $'3\n'
_restore_tui_wait_for "$RTUISWAPLOG" 'Absolute target folder:' && _restore_tui_send "$RTUISWAPBASE/target"$'\n'
_restore_tui_wait_for "$RTUISWAPLOG" 'Apply this plan to the selected folder?' && _restore_tui_send $'y\n'
_restore_tui_wait_for "$RTUISWAPLOG" 'The restore target changed while it was being reviewed.' && _restore_tui_send $'q\n'
_restore_tui_finish; RTUISWAPRC=$?
RTUISWAPOUT="$(cat -- "$RTUISWAPLOG")"

it "restore refuses a target that changes after preview"
[[ "$RTUISWAPRC" -eq 0 ]] && ok || fail "restore exited $RTUISWAPRC after the target changed"
assert_contains "$RTUISWAPOUT" "The restore target changed while it was being reviewed."

# Snapshot the selected bundle before preview. Replacing the shared source
# after the confirmation prompt must not change what the apply step consumes.
RTUISNAPSHOTART="$RTUICDEST/omabackup-test-20260829-000008.tar.zst"
cp -- "$RART" "$RTUISNAPSHOTART"
RTUISNAPSHOTLOG="$RTUIC/restore-bundle-snapshot.log"
RTUISNAPSHOTFIFO="$RTUIC/bundle-snapshot-input"
_restore_tui_start "$RTUISNAPSHOTLOG" "$RTUISNAPSHOTFIFO" \
    "env HOME='$RTUIC/home' OMABACKUP_ROOT='$PWD' OMABACKUP_GROUPS='$RH/g.json' \
         OMABACKUP_STATE='$RTUIC/snapshot-state' OMABACKUP_DESTINATIONS='$RTUIC/destinations.json' \
         XDG_RUNTIME_DIR=/nonexistent '$OB' restore"
_restore_tui_wait_for "$RTUISNAPSHOTLOG" 'Choose a backup number' && _restore_tui_send $'1\n'
_restore_tui_wait_for "$RTUISNAPSHOTLOG" 'Choose [1/2/3/q]:' && _restore_tui_send $'1\n'
_restore_tui_wait_for "$RTUISNAPSHOTLOG" 'Apply this plan to the selected folder?' && \
    printf 'not a backup anymore\n' >"$RTUISNAPSHOTART" && _restore_tui_send $'y\n'
# A successful apply closes restore; there is no second confirmation screen to
# quit from. The wait is still synchronized to prove the private snapshot was
# actually consumed before the child exits.
_restore_tui_wait_for "$RTUISNAPSHOTLOG" 'restored 3 files'
_restore_tui_finish; RTUISNAPSHOTRC=$?
RTUISNAPSHOTOUT="$(cat -- "$RTUISNAPSHOTLOG")"

it "restore applies the bundle that was previewed, not a replaced source"
[[ "$RTUISNAPSHOTRC" -eq 0 ]] && ok || fail "restore exited $RTUISNAPSHOTRC after the source bundle was replaced"
assert_contains "$RTUISNAPSHOTOUT" "restored 3 files"
it "restore journal keeps the shared bundle path after applying its snapshot"
assert_eq "$(jq -r '.artifact' "$RTUIC/snapshot-state/restore-last.json")" "$(realpath "$RTUISNAPSHOTART")"

# The source FD freezes the inode, but a shared writer can still append to
# that inode after it is opened. The private snapshot must freeze the size as
# well; otherwise cp follows the moving EOF and the bytes shown in preview
# are not necessarily the bytes that were copied for the restore.
RTUIGROWROOT="$RTUIC/grow-fake-root"
mkdir -p "$RTUIGROWROOT/bin"
ln -s "$PWD/lib" "$RTUIGROWROOT/lib"
ln -s "$PWD/groups.default.json" "$RTUIGROWROOT/groups.default.json"
cat >"$RTUIGROWROOT/bin/omabackup" <<'STUBEOF'
#!/bin/bash
if [[ "$1" == restore ]]; then
    artifact=""
    for arg in "$@"; do
        [[ "$arg" == */backup.tar.zst ]] && artifact="$arg"
    done
    [[ -n "$artifact" ]] || exit 1
    stat -c %s "$artifact" >"${OMABACKUP_TEST_SNAPSHOT_SIZE:?}" || exit 1
    printf 'preview\n'
fi
exit 0
STUBEOF
chmod +x "$RTUIGROWROOT/bin/omabackup"
RTUIGROWDIR="$RTUIC/grow-destination"
mkdir -p "$RTUIGROWDIR"
RTUIGROWART="$RTUIGROWDIR/omabackup-grow-20260829-000010.tar.zst"
cp -- "$RART" "$RTUIGROWART"
RTUIGROWSIZE="$(stat -c %s "$RTUIGROWART")"
printf '%s\n' "$RTUIGROWSIZE" >"$RTUIC/grow-source-size"
printf '{"schemaVersion":1,"destinations":[{"id":"grow","type":"dir","path":"%s","keep":5,"enabled":true,"note":null}]}\n' \
    "$RTUIGROWDIR" >"$RTUIC/grow-destinations.json"
mkdir -p "$RTUIC/grow-head-stub"
cat >"$RTUIC/grow-head-stub/head" <<'STUBEOF'
#!/bin/bash
if [[ "${1:-}" == "-c" ]]; then
    /usr/bin/dd if=/dev/zero bs=4096 count=1 >>"${OMABACKUP_TEST_GROW_SOURCE:?}" 2>/dev/null || exit $?
fi
exec /usr/bin/head "$@"
STUBEOF
chmod +x "$RTUIC/grow-head-stub/head"
RTUIGROWLOG="$RTUIC/restore-growing-source.log"
RTUIGROWFIFO="$RTUIC/growing-source-input"
RTUIGROWSNAPSHOTSIZE="$RTUIC/grow-snapshot-size"
_restore_tui_start "$RTUIGROWLOG" "$RTUIGROWFIFO" \
    "env PATH='$RTUIC/grow-head-stub:$PATH' HOME='$RTUIC/grow-home' OMABACKUP_ROOT='$RTUIGROWROOT' \
         OMABACKUP_GROUPS='$RH/g.json' OMABACKUP_TEST_GROW_SOURCE='$RTUIGROWART' \
         OMABACKUP_TEST_SNAPSHOT_SIZE='$RTUIGROWSNAPSHOTSIZE' OMABACKUP_STATE='$RTUIC/grow-state' \
         OMABACKUP_DESTINATIONS='$RTUIC/grow-destinations.json' XDG_RUNTIME_DIR=/nonexistent '$OB' restore"
_restore_tui_wait_for "$RTUIGROWLOG" 'Choose a backup number' && _restore_tui_send $'1\n'
_restore_tui_wait_for "$RTUIGROWLOG" 'Choose [1/2/3/q]:' && _restore_tui_send $'1\n'
_restore_tui_wait_for "$RTUIGROWLOG" 'Apply this plan to the selected folder?' && _restore_tui_send $'q\n'
_restore_tui_finish; RTUIGROWRC=$?
RTUIGROWOUT="$(cat -- "$RTUIGROWLOG")"

it "restore freezes the source size before copying a growing bundle"
[[ "$RTUIGROWRC" -eq 0 ]] && ok || fail "growing-source session exited $RTUIGROWRC"
it "the growing-source regression exercised the append"
[[ "$(stat -c %s "$RTUIGROWART" 2>/dev/null)" -gt "$RTUIGROWSIZE" ]] \
    && ok || fail "the head stub never ran; the size-freeze path was not exercised"
it "restore keeps the snapshot at the size frozen before the append"
assert_eq "$(cat "$RTUIGROWSNAPSHOTSIZE" 2>/dev/null)" "$RTUIGROWSIZE"

# q is an explicit cancel everywhere the TUI asks for a choice, including
# before a target path has been entered.
RTUICANCELTARGETLOG="$RTUIC/restore-cancel-target.log"
RTUICANCELTARGETFIFO="$RTUIC/cancel-target-input"
_restore_tui_start "$RTUICANCELTARGETLOG" "$RTUICANCELTARGETFIFO" \
    "env HOME='$RTUIC/home' OMABACKUP_ROOT='$PWD' OMABACKUP_GROUPS='$RH/g.json' \
         OMABACKUP_STATE='$RTUIC/cancel-target-state' OMABACKUP_DESTINATIONS='$RTUIC/destinations.json' \
         XDG_RUNTIME_DIR=/nonexistent '$OB' restore"
_restore_tui_wait_for "$RTUICANCELTARGETLOG" 'Choose a backup number' && _restore_tui_send $'1\n'
_restore_tui_wait_for "$RTUICANCELTARGETLOG" 'Choose [1/2/3/q]:' && _restore_tui_send $'q\n'
_restore_tui_finish; RTUICANCELTARGETRC=$?
RTUICANCELTARGETOUT="$(cat -- "$RTUICANCELTARGETLOG")"

it "restore accepts q while choosing a target"
[[ "$RTUICANCELTARGETRC" -eq 0 ]] && ok || fail "target-cancel session exited $RTUICANCELTARGETRC"
assert_contains "$RTUICANCELTARGETOUT" "Restore cancelled."

RTUICANCELPATHLOG="$RTUIC/restore-cancel-path.log"
RTUICANCELPATHFIFO="$RTUIC/cancel-path-input"
_restore_tui_start "$RTUICANCELPATHLOG" "$RTUICANCELPATHFIFO" \
    "env HOME='$RTUIC/home' OMABACKUP_ROOT='$PWD' OMABACKUP_GROUPS='$RH/g.json' \
         OMABACKUP_STATE='$RTUIC/cancel-path-state' OMABACKUP_DESTINATIONS='$RTUIC/destinations.json' \
         XDG_RUNTIME_DIR=/nonexistent '$OB' restore"
_restore_tui_wait_for "$RTUICANCELPATHLOG" 'Choose a backup number' && _restore_tui_send $'1\n'
_restore_tui_wait_for "$RTUICANCELPATHLOG" 'Choose [1/2/3/q]:' && _restore_tui_send $'3\n'
_restore_tui_wait_for "$RTUICANCELPATHLOG" 'Absolute target folder:' && _restore_tui_send $'q\n'
_restore_tui_finish; RTUICANCELPATHRC=$?
RTUICANCELPATHOUT="$(cat -- "$RTUICANCELPATHLOG")"

it "restore accepts q while entering a custom target"
[[ "$RTUICANCELPATHRC" -eq 0 ]] && ok || fail "path-cancel session exited $RTUICANCELPATHRC"
assert_contains "$RTUICANCELPATHOUT" "Restore cancelled."

# A target resolver failure is recoverable input/state, not an invisible
# successful exit that closes the terminal.
mkdir -p "$RTUIC/realpath-failure-stub"
cat >"$RTUIC/realpath-failure-stub/realpath" <<'STUBEOF'
#!/bin/bash
exit 1
STUBEOF
chmod +x "$RTUIC/realpath-failure-stub/realpath"
cp -- "$RART" "$RTUICDEST/omabackup-test-20260829-000004.tar.zst"
RTUIREALPATHLOG="$RTUIC/restore-realpath-failure.log"
RTUIREALPATHFIFO="$RTUIC/realpath-failure-input"
_restore_tui_start "$RTUIREALPATHLOG" "$RTUIREALPATHFIFO" \
    "env PATH='$RTUIC/realpath-failure-stub:$PATH' HOME='$RTUIC/home' OMABACKUP_ROOT='$PWD' \
         OMABACKUP_GROUPS='$RH/g.json' OMABACKUP_STATE='$RTUIC/realpath-state' \
         OMABACKUP_DESTINATIONS='$RTUIC/destinations.json' XDG_RUNTIME_DIR=/nonexistent \
         '$OB' restore"
_restore_tui_wait_for "$RTUIREALPATHLOG" 'Choose a backup number' && _restore_tui_send $'1\n'
_restore_tui_wait_for "$RTUIREALPATHLOG" 'Choose [1/2/3/q]:' && _restore_tui_send $'1\n'
_restore_tui_wait_for "$RTUIREALPATHLOG" 'We could not resolve the restore target.' && _restore_tui_send $'q\n'
_restore_tui_finish; RTUIREALPATHRC=$?
RTUIREALPATHOUT="$(cat -- "$RTUIREALPATHLOG")"

it "restore keeps a realpath failure recoverable"
[[ "$RTUIREALPATHRC" -eq 0 ]] && ok || fail "realpath failure session exited $RTUIREALPATHRC"
assert_contains "$RTUIREALPATHOUT" "We could not resolve the restore target."
assert_contains "$RTUIREALPATHOUT" "q) Cancel"

# A shared destination can contain a hostile filename. It remains the real
# filename for selection, but the list must not emit terminal controls.
RTUIESCDIR="$RTUIC/escape-destination"
mkdir -p "$RTUIESCDIR"
RTUIESCNAME=$'omabackup-\033[2J\033[H-20260829-000003.tar.zst'
cp -- "$RART" "$RTUIESCDIR/$RTUIESCNAME"
RTUIC1NAME=$'omabackup-\u009b-20260829-000006.tar.zst'
cp -- "$RART" "$RTUIESCDIR/$RTUIC1NAME"
cp -- "$RART" "$RTUIESCDIR/omabackup-safe-20260829-000005.tar.zst"
printf '{"schemaVersion":1,"destinations":[{"id":"escape","type":"dir","path":"%s","keep":5,"enabled":true,"note":null}]}\n' \
    "$RTUIESCDIR" >"$RTUIC/escape-destinations.json"
RTUIESCLOG="$RTUIC/restore-escape-name.log"
RTUIESCFIFO="$RTUIC/escape-name-input"
_restore_tui_start "$RTUIESCLOG" "$RTUIESCFIFO" \
    "env HOME='$RTUIC/home' OMABACKUP_ROOT='$PWD' OMABACKUP_GROUPS='$RH/g.json' \
         OMABACKUP_STATE='$RTUIC/escape-state' OMABACKUP_DESTINATIONS='$RTUIC/escape-destinations.json' \
         XDG_RUNTIME_DIR=/nonexistent '$OB' restore"
_restore_tui_wait_for "$RTUIESCLOG" 'Choose a backup number' && _restore_tui_send $'q\n'
_restore_tui_finish; RTUIESCRC=$?
RTUIESCOUT="$(cat -- "$RTUIESCLOG")"

it "restore omits hostile artifact names from the interactive selector"
[[ "$RTUIESCRC" -eq 0 ]] && ok || fail "restore escape-name session exited $RTUIESCRC"
assert_contains "$RTUIESCOUT" "omabackup-safe-20260829-000005.tar.zst"
assert_contains "$RTUIESCOUT" "2 backup(s) hidden: unsafe file name."
assert_not_contains "$RTUIESCOUT" "20260829-000006.tar.zst"
it "restore does not echo the raw hostile artifact name"
[[ "$RTUIESCOUT" != *"$RTUIESCNAME"* ]] \
    && ok || fail "restore emitted the raw terminal control from the artifact name"

# Keep a separate all-hidden case so the actionable “No usable backups” path
# cannot regress while the mixed-list notice stays green.
RTUIONLYDIR="$RTUIC/escape-only-destination"
mkdir -p "$RTUIONLYDIR"
cp -- "$RART" "$RTUIONLYDIR/$RTUIESCNAME"
printf '{"schemaVersion":1,"destinations":[{"id":"escape-only","type":"dir","path":"%s","keep":5,"enabled":true,"note":null}]}\n' \
    "$RTUIONLYDIR" >"$RTUIC/escape-only-destinations.json"
RTUIONLYLOG="$RTUIC/restore-all-hidden.log"
RTUIONLYFIFO="$RTUIC/all-hidden-input"
_restore_tui_start "$RTUIONLYLOG" "$RTUIONLYFIFO" \
    "env HOME='$RTUIC/home' OMABACKUP_ROOT='$PWD' OMABACKUP_GROUPS='$RH/g.json' \
         OMABACKUP_STATE='$RTUIC/all-hidden-state' OMABACKUP_DESTINATIONS='$RTUIC/escape-only-destinations.json' \
         XDG_RUNTIME_DIR=/nonexistent '$OB' restore"
_restore_tui_wait_for "$RTUIONLYLOG" 'No usable backups found.'
_restore_tui_wait_for "$RTUIONLYLOG" 'Choose [1/2/q]:' && _restore_tui_send $'q\n'
_restore_tui_finish; RTUIONLYRC=$?
RTUIONLYOUT="$(cat -- "$RTUIONLYLOG")"

it "restore explains when every backup was hidden"
[[ "$RTUIONLYRC" -eq 0 ]] && ok || fail "all-hidden session exited $RTUIONLYRC"
assert_contains "$RTUIONLYOUT" "No usable backups found."
assert_contains "$RTUIONLYOUT" "1 backup file name(s) were hidden"
assert_contains "$RTUIONLYOUT" "Restore one by path if you trust it."

# The output sanitizer is exercised under the C locale as well as the normal
# UTF-8 locale. C1 controls can arrive as UTF-8 (C2 80..9F), so byte-oriented
# replacement must not leave the continuation byte behind when LC_ALL=C is
# inherited by the terminal launcher.
RTUISANITIZE_DEF="$(sed -n '/^_restore_tui_sanitize() {/,/^}/p' "$OB")"
RTUISANITIZE_INPUT=$'before\u009b\033[31mcolour\033[0m\001\n\u00c1rea\u00df'
RTUISANITIZE_OUTPUT="$(LC_ALL=C bash -c "$RTUISANITIZE_DEF; _restore_tui_sanitize \"\$1\"" _ "$RTUISANITIZE_INPUT")"

it "restore sanitizes C1 and ANSI output under the C locale"
assert_eq "$RTUISANITIZE_OUTPUT" $'before?colour?\n\u00c1rea\u00df'

# A restore plan can contain one line per file. Keep the sanitizer bounded by
# a single streaming pass so a normal large plan cannot freeze the TUI while
# it is waiting to print the preview or apply result.
RTUISANITIZE_LARGE="$(head -c 20000 /dev/zero | tr '\0' x)"
if timeout 2s bash -c "$RTUISANITIZE_DEF; _restore_tui_sanitize \"\$1\" >/dev/null" _ "$RTUISANITIZE_LARGE"; then
    it "restore sanitizes a large plan without quadratic delay"
    ok
else
    it "restore sanitizes a large plan without quadratic delay"
    fail "sanitizer exceeded the two-second regression bound"
fi

# Destination metadata is also external input. A path with a UTF-8 C1 code
# point is valid JSON and can reach the listing even though its human-facing
# form must never emit the control byte under LC_ALL=C.
RTUIMETADATADIR="$RTUIC/metadata-"$'\u009b'"-"$'\n'"line"
mkdir -p "$RTUIMETADATADIR"
cp -- "$RART" "$RTUIMETADATADIR/omabackup-metadata-20260829-000007.tar.zst"
jq -n --arg path "$RTUIMETADATADIR" \
    '{schemaVersion:1,destinations:[{id:"metadata",type:"dir",path:$path,keep:5,enabled:true,note:null}]}' \
    >"$RTUIC/metadata-destinations.json"
RTUIMETALOG="$RTUIC/restore-metadata.log"
RTUIMETAFIFO="$RTUIC/metadata-input"
_restore_tui_start "$RTUIMETALOG" "$RTUIMETAFIFO" \
    "env LC_ALL=C HOME='$RTUIC/home' OMABACKUP_ROOT='$PWD' OMABACKUP_GROUPS='$RH/g.json' \
         OMABACKUP_STATE='$RTUIC/metadata-state' OMABACKUP_DESTINATIONS='$RTUIC/metadata-destinations.json' \
         XDG_RUNTIME_DIR=/nonexistent '$OB' restore"
_restore_tui_wait_for "$RTUIMETALOG" 'Choose a backup number' && _restore_tui_send $'1\n'
_restore_tui_wait_for "$RTUIMETALOG" 'Choose [1/2/3/q]:' && _restore_tui_send $'1\n'
_restore_tui_wait_for "$RTUIMETALOG" 'Apply this plan to the selected folder?' && _restore_tui_send $'q\n'
_restore_tui_finish; RTUIMETARC=$?
RTUIMETAOUT="$(cat -- "$RTUIMETALOG")"

it "restore sanitizes destination metadata under the C locale"
[[ "$RTUIMETARC" -eq 0 ]] && ok || fail "metadata session exited $RTUIMETARC"
assert_contains "$RTUIMETAOUT" "metadata-?-?line"
assert_not_contains "$RTUIMETAOUT" "$RTUIMETADATADIR"

# The TUI also sanitizes the child command's preview and apply reports, not
# only the selector metadata. A tiny CLI double makes the terminal controls
# deterministic without weakening the real artifact-list path.
RTUIFAKEROOT="$RTUIC/fake-root"
mkdir -p "$RTUIFAKEROOT/bin"
ln -s "$PWD/lib" "$RTUIFAKEROOT/lib"
ln -s "$PWD/groups.default.json" "$RTUIFAKEROOT/groups.default.json"
cat >"$RTUIFAKEROOT/bin/omabackup" <<'STUBEOF'
#!/bin/bash
if [[ "$1" == restore ]]; then
    apply=0
    for arg in "$@"; do [[ "$arg" == --apply ]] && apply=1; done
    if (( apply )); then
        printf 'applied \033[31mred\033[0m\n'
    else
        printf 'preview \033[31mred\033[0m\n'
    fi
    exit 0
fi
exit 0
STUBEOF
chmod +x "$RTUIFAKEROOT/bin/omabackup"
RTUIREALOUTLOG="$RTUIC/restore-real-output.log"
RTUIREALOUTFIFO="$RTUIC/real-output-input"
_restore_tui_start "$RTUIREALOUTLOG" "$RTUIREALOUTFIFO" \
    "env HOME='$RTUIC/home' OMABACKUP_ROOT='$RTUIFAKEROOT' OMABACKUP_STATE='$RTUIC/real-output-state' \
         OMABACKUP_DESTINATIONS='$RTUIC/destinations.json' XDG_RUNTIME_DIR=/nonexistent '$OB' restore"
_restore_tui_wait_for "$RTUIREALOUTLOG" 'Choose a backup number' && _restore_tui_send $'1\n'
_restore_tui_wait_for "$RTUIREALOUTLOG" 'Choose [1/2/3/q]:' && _restore_tui_send $'1\n'
_restore_tui_wait_for "$RTUIREALOUTLOG" 'Apply this plan to the selected folder?' && _restore_tui_send $'y\n'
_restore_tui_wait_for "$RTUIREALOUTLOG" 'applied red'
_restore_tui_finish; RTUIREALOUTRC=$?
RTUIREALOUT="$(cat -- "$RTUIREALOUTLOG")"

it "restore sanitizes real preview and apply output"
[[ "$RTUIREALOUTRC" -eq 0 ]] && ok || fail "real-output session exited $RTUIREALOUTRC"
assert_contains "$RTUIREALOUT" "preview red"
assert_contains "$RTUIREALOUT" "applied red"
assert_not_contains "$RTUIREALOUT" $'\033[31m'

# Recovery must preserve the child diagnostic on the current screen. A raw
# transcript still contains bytes from previous screens even when a later
# clear erased them, so assert against the bytes after the last shared header.
RTUIFAILPREVROOT="$RTUIC/fake-preview-failure-root"
mkdir -p "$RTUIFAILPREVROOT/bin"
ln -s "$PWD/lib" "$RTUIFAILPREVROOT/lib"
ln -s "$PWD/groups.default.json" "$RTUIFAILPREVROOT/groups.default.json"
cat >"$RTUIFAILPREVROOT/bin/omabackup" <<'STUBEOF'
#!/bin/bash
if [[ "$1" == restore ]]; then
    printf 'PREVIEW-DIAGNOSTIC\n'
    exit 1
fi
exit 0
STUBEOF
chmod +x "$RTUIFAILPREVROOT/bin/omabackup"
RTUIFAILPREVLOG="$RTUIC/restore-preview-diagnostic.log"
RTUIFAILPREVFIFO="$RTUIC/preview-diagnostic-input"
_restore_tui_start "$RTUIFAILPREVLOG" "$RTUIFAILPREVFIFO" \
    "env HOME='$RTUIC/failure-preview-home' OMABACKUP_ROOT='$RTUIFAILPREVROOT' OMABACKUP_STATE='$RTUIC/failure-preview-state' \
         OMABACKUP_DESTINATIONS='$RTUIC/destinations.json' XDG_RUNTIME_DIR=/nonexistent '$OB' restore"
_restore_tui_wait_for "$RTUIFAILPREVLOG" 'Choose a backup number' && _restore_tui_send $'1\n'
_restore_tui_wait_for "$RTUIFAILPREVLOG" 'Choose [1/2/3/q]:' && _restore_tui_send $'1\n'
_restore_tui_wait_for "$RTUIFAILPREVLOG" 'This backup could not be previewed' && _restore_tui_send $'q\n'
_restore_tui_finish; RTUIFAILPREVRC=$?
RTUIFAILPREVOUT="$(cat -- "$RTUIFAILPREVLOG")"
RTUIFAILPREVSCREEN="${RTUIFAILPREVOUT##*$'\033[2J\033[H'}"

it "restore keeps the preview diagnostic on the recovery screen"
[[ "$RTUIFAILPREVRC" -eq 0 ]] && ok || fail "preview-diagnostic session exited $RTUIFAILPREVRC"
assert_contains "$RTUIFAILPREVSCREEN" "PREVIEW-DIAGNOSTIC"

RTUIFAILAPPLYROOT="$RTUIC/fake-apply-failure-root"
mkdir -p "$RTUIFAILAPPLYROOT/bin"
ln -s "$PWD/lib" "$RTUIFAILAPPLYROOT/lib"
ln -s "$PWD/groups.default.json" "$RTUIFAILAPPLYROOT/groups.default.json"
cat >"$RTUIFAILAPPLYROOT/bin/omabackup" <<'STUBEOF'
#!/bin/bash
if [[ "$1" == restore ]]; then
    for arg in "$@"; do
        if [[ "$arg" == --apply ]]; then
            printf 'APPLY-DIAGNOSTIC\n'
            exit 1
        fi
    done
    printf 'PREVIEW-OK\n'
    exit 0
fi
exit 0
STUBEOF
chmod +x "$RTUIFAILAPPLYROOT/bin/omabackup"
RTUIFAILAPPLYLOG="$RTUIC/restore-apply-diagnostic.log"
RTUIFAILAPPLYFIFO="$RTUIC/apply-diagnostic-input"
_restore_tui_start "$RTUIFAILAPPLYLOG" "$RTUIFAILAPPLYFIFO" \
    "env HOME='$RTUIC/failure-apply-home' OMABACKUP_ROOT='$RTUIFAILAPPLYROOT' OMABACKUP_STATE='$RTUIC/failure-apply-state' \
         OMABACKUP_DESTINATIONS='$RTUIC/destinations.json' XDG_RUNTIME_DIR=/nonexistent '$OB' restore"
_restore_tui_wait_for "$RTUIFAILAPPLYLOG" 'Choose a backup number' && _restore_tui_send $'1\n'
_restore_tui_wait_for "$RTUIFAILAPPLYLOG" 'Choose [1/2/3/q]:' && _restore_tui_send $'1\n'
_restore_tui_wait_for "$RTUIFAILAPPLYLOG" 'Apply this plan to the selected folder?' && _restore_tui_send $'y\n'
_restore_tui_wait_for "$RTUIFAILAPPLYLOG" 'The restore did not finish successfully' && _restore_tui_send $'q\n'
_restore_tui_finish; RTUIFAILAPPLYRC=$?
RTUIFAILAPPLYOUT="$(cat -- "$RTUIFAILAPPLYLOG")"
RTUIFAILAPPLYSCREEN="${RTUIFAILAPPLYOUT##*$'\033[2J\033[H'}"

it "restore keeps the apply diagnostic on the recovery screen"
[[ "$RTUIFAILAPPLYRC" -eq 0 ]] && ok || fail "apply-diagnostic session exited $RTUIFAILAPPLYRC"
assert_contains "$RTUIFAILAPPLYSCREEN" "APPLY-DIAGNOSTIC"

# _into_cleanup: found by review (round omabackup-33, `omabackup-rev-2`,
# scanning the whole repo for the same bash `local`-chaining pitfall
# fixed in lib/log.sh's _log_tail) to have been a complete no-op since it
# was written -- `local into="$1" boundary="$2" d="$into"` in one
# statement leaves `d` empty (bash does not see a variable just assigned
# earlier in the SAME `local` statement when expanding a later one on that
# line), so the cleanup loop's own `-n "$d"` was false on its very first
# check and nothing was ever removed, across all 17 call sites in
# cmd_restore's error paths. Extracted directly from bin/omabackup, not a
# hand-copy, so this test tracks the real function.
INTOCLEANUP_HOME="$(mktemp -d)"
mkdir -p "$INTOCLEANUP_HOME/base/x/y/z"
bash -c "
$(sed -n '/^_into_cleanup() {/,/^}/p' bin/omabackup)
_into_cleanup '$INTOCLEANUP_HOME/base/x/y/z' '$INTOCLEANUP_HOME/base'
"
INTOCLEANUP_REMAINING="$(find "$INTOCLEANUP_HOME/base" -mindepth 1 -type d)"

it "_into_cleanup actually removes newly-empty ancestor directories up to the boundary"
assert_eq "$INTOCLEANUP_REMAINING" ""
[[ -d "$INTOCLEANUP_HOME/base" ]] && ok || fail "the boundary directory itself should survive, but was removed too"

# A directory that is NOT empty (something else created a file inside one
# of the ancestors) must stop the climb right there, not remove it anyway
# -- rmdir's own real failure is what _into_cleanup relies on to know
# when to stop.
INTOCLEANUP_NONEMPTY_HOME="$(mktemp -d)"
mkdir -p "$INTOCLEANUP_NONEMPTY_HOME/base/x/y/z"
printf 'keep me\n' >"$INTOCLEANUP_NONEMPTY_HOME/base/x/marker.txt"
bash -c "
$(sed -n '/^_into_cleanup() {/,/^}/p' bin/omabackup)
_into_cleanup '$INTOCLEANUP_NONEMPTY_HOME/base/x/y/z' '$INTOCLEANUP_NONEMPTY_HOME/base'
"

it "_into_cleanup stops climbing at the first non-empty ancestor instead of forcing past it"
[[ ! -d "$INTOCLEANUP_NONEMPTY_HOME/base/x/y" && -d "$INTOCLEANUP_NONEMPTY_HOME/base/x" \
   && -f "$INTOCLEANUP_NONEMPTY_HOME/base/x/marker.txt" ]] \
    && ok || fail "expected y/z removed, x (containing marker.txt) kept"

# The third, most common-in-practice case for the same matrix (noted in
# review, round omabackup-34, `omabackup-rev-2`, as not a defect but worth
# covering explicitly): `--into` pointing at a directory that already
# existed before the restore started. `into == boundary` here, so the
# loop's own `"$d" != "$boundary"` is false on the very first check and
# nothing is removed -- exactly the behavior the function's own comment
# already documents ("or <into> itself, when <into> already existed: the
# loop below then does nothing"), and the most likely real call shape
# since restoring into an existing directory is the common case.
INTOCLEANUP_SAME_HOME="$(mktemp -d)"
mkdir -p "$INTOCLEANUP_SAME_HOME/base"
printf 'already here\n' >"$INTOCLEANUP_SAME_HOME/base/existing.txt"
bash -c "
$(sed -n '/^_into_cleanup() {/,/^}/p' bin/omabackup)
_into_cleanup '$INTOCLEANUP_SAME_HOME/base' '$INTOCLEANUP_SAME_HOME/base'
"

it "_into_cleanup does nothing when --into pointed at a directory that already existed (into == boundary)"
[[ -d "$INTOCLEANUP_SAME_HOME/base" && -f "$INTOCLEANUP_SAME_HOME/base/existing.txt" ]] \
    && ok || fail "an already-existing --into directory (or its contents) should never be touched"

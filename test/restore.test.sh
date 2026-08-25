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
# Truncated, not appended to: zstd ignores trailing bytes, so an artifact with
# rubbish stapled on the end verifies perfectly well and proves nothing.
RBAD="$RH/broken.tar.zst"
head -c "$(( $(stat -c%s "$RART") - 4096 ))" "$RART" >"$RBAD"

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

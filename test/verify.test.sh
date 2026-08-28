# Coverage regressions (bin/omabackup verify).
# The central case is the 2026-08-17 incident: config intact, format changed,
# backup green and useless. Rationale: docs/DESIGN.md §0 and §11.
#
# Each case builds a fake $HOME and its own manifest; nothing touches the machine.

OB="$PWD/bin/omabackup"

# _home -> a fake HOME holding a Lua Hyprland config
_home() {
    local h; h="$(mktemp -d)"
    mkdir -p "$h/.config/hypr"
    cat >"$h/.config/hypr/hyprland.lua" <<'LUA'
require("hypr.monitors")
require("hypr.bindings")
LUA
    printf 'hl.monitor({})\n'  >"$h/.config/hypr/monitors.lua"
    printf 'hl.bind({})\n'     >"$h/.config/hypr/bindings.lua"
    printf '%s' "$h"
}

# _groups <file> <paths-json> [excluded-json]
_groups() {
    cat >"$1" <<JSON
{ "schemaVersion": 1, "supportedTargets": ["4.*"],
  "excluded": ${3:-[]},
  "groups": [ { "id":"compositor","label":"Hyprland","mode":"copy",
                "coupled":true,"critical":true,"probe":"hypr-lua","paths": $2 } ] }
JSON
}

_verify() {  # echoes verify's JSON, run against the fake HOME
    HOME="$1" OMABACKUP_GROUPS="$2" XDG_RUNTIME_DIR=/nonexistent \
        OMABACKUP_STATE="$1/.local/state/omabackup" "$OB" verify --json 2>/dev/null
}

# -- the August incident ------------------------------------------------------
# The compositor reads .lua; the backup declares only .conf. Intact, valid, useless.
H="$(_home)"; G="$H/groups.json"
printf 'monitor=eDP-1\n' >"$H/.config/hypr/hyprland.conf"
_groups "$G" '["~/.config/hypr/hyprland.conf"]'
OUT="$(_verify "$H" "$G")"

it "august: a backup holding only .conf fails"
assert_eq "$(jq -r .ok <<<"$OUT")" "false"

it "august: names the .lua that was left out"
assert_contains "$(jq -r '.findings[]|select(.code=="lua-uncovered")|.path' <<<"$OUT")" "hyprland.lua"

it "august: fails every uncovered live .lua, not just the first"
assert_eq "$(jq -r '[.findings[]|select(.code=="lua-uncovered")]|length' <<<"$OUT")" "3"

# -- the same system, covered -------------------------------------------------
H="$(_home)"; G="$H/groups.json"
_groups "$G" '["~/.config/hypr"]'
OUT="$(_verify "$H" "$G")"

it "covering the whole directory passes"
assert_eq "$(jq -r .ok <<<"$OUT")" "true"

# -- transitivity --------------------------------------------------------------
# A module reached by require from OUTSIDE ~/.config/hypr must still be demanded.
# This is the real toggles/hypr/flags.lua case, which lives in ~/.local/state.
H="$(_home)"; G="$H/groups.json"
mkdir -p "$H/.local/state/meu"
printf 'return {}\n' >"$H/.local/state/meu/extra.lua"
printf 'require("meu.extra")\n' >>"$H/.config/hypr/hyprland.lua"
_groups "$G" '["~/.config/hypr"]'
OUT="$(_verify "$H" "$G")"

it "a module reached by require outside the group fails"
assert_eq "$(jq -r .ok <<<"$OUT")" "false"

it "the transitive module is named in the finding"
assert_contains "$(jq -r '.findings[]|select(.code=="lua-uncovered")|.path' <<<"$OUT")" "meu/extra.lua"

# -- a deliberate exclusion silences it, with a versioned reason ---------------
H="$(_home)"; G="$H/groups.json"
mkdir -p "$H/.local/state/meu"
printf 'return {}\n' >"$H/.local/state/meu/extra.lua"
printf 'require("meu.extra")\n' >>"$H/.config/hypr/hyprland.lua"
_groups "$G" '["~/.config/hypr"]' '[{"path":"~/.local/state/meu","reason":"gerado, reconstruível"}]'
OUT="$(_verify "$H" "$G")"

it "a deliberately excluded path does not fail"
assert_eq "$(jq -r .ok <<<"$OUT")" "true"

# -- phantom path ---------------------------------------------------------------
# A critical group pointing nowhere used to report "up to date" while covering
# zero bytes -- which is what happened when Omarchy moved current/ to ~/.local/state.
H="$(_home)"; G="$H/groups.json"
_groups "$G" '["~/.config/hypr","~/.config/omarchy/nao-existe"]'
OUT="$(_verify "$H" "$G")"

it "a declared but missing path becomes a warning"
assert_contains "$(jq -r '.findings[]|select(.code=="path-missing")|.message' <<<"$OUT")" "nao-existe"

# -- compatibility identity ------------------------------------------------------
H="$(_home)"; G="$H/groups.json"
_groups "$G" '["~/.config/hypr"]'
OUT="$(_verify "$H" "$G")"

it "the report carries the Omarchy version"
assert_contains "$(jq -r .omarchy.version <<<"$OUT")" "."

it "the report carries the migration watermark"
[[ "$(jq -r .omarchy.migrationWatermark <<<"$OUT")" =~ ^[0-9]+$ ]] && ok || fail "watermark is not numeric"

# ── a group whose probe cannot even be looked up must fail, not run nothing ─
# `probe="$(group_field "$id" probe)" || continue` silently skipped this
# group's dispatch on a query failure -- no finding, no trace in the exit
# status: verify reported ok:true having never actually run whatever probe
# this group declares. A stub jq that fails only on that specific query
# confirmed the result before the fix, and confirms the fix now: a `fail`
# finding, and ok:false.
VPH="$(mktemp -d)"
mkdir -p "$VPH/home/.config/omarchy"
printf '{}' >"$VPH/home/.config/omarchy/shell.json"
cat >"$VPH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"shell","label":"Shell","mode":"copy","coupled":false,"critical":false,
  "paths":["~/.config/omarchy/shell.json"],"probe":"shell-json"}]}
JSON
mkdir -p "$VPH/stub"
{ printf '#!/bin/bash\n'
  printf 'for a in "$@"; do [[ "$a" == *"select(.id==\$id) | .[\$f]"* ]] && exit 9; done\n'
  printf 'exec %s "$@"\n' "$(command -v jq)"
} >"$VPH/stub/jq"; chmod +x "$VPH/stub/jq"

it "verify fails when a group's own probe field cannot be queried"
VPOUT="$(HOME="$VPH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$VPH/g.json" \
    OMABACKUP_STATE="$VPH/home/.state" PATH="$VPH/stub:$PATH" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" verify --json 2>/dev/null)"
assert_eq "$(jq -r '.ok' <<<"$VPOUT")" "false"

it "and names it as a manifest problem, not silence"
assert_contains "$VPOUT" "probe could not be read"

# ── a mode:link group whose own mode query fails is not silently skipped ────
# `[[ "$(group_field "$id" mode)" == "link" ]] || continue` treated a
# failed query the same as a group that genuinely is not mode:link -- both
# are empty output, neither equals "link", and the loop just moved on
# without ever checking whether the declared path had stopped being a
# symlink. A PoC (jq failing only the --arg f mode query, for a real
# mode:link group whose path is now a plain file) confirmed the result:
# verify --json reported ok:true with no finding for that group at all.
VLH="$(mktemp -d)"
cat >"$VLH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"editorconf","label":"EditorConf","mode":"link","coupled":false,"critical":true,"paths":["~/.bashrc"]}]}
JSON
printf 'not a link anymore\n' >"$VLH/.bashrc"
mkdir -p "$VLH/stub"
{ printf '#!/bin/bash\n'
  printf 'for a in "$@"; do [[ "$a" == "mode" ]] && exit 9; done\n'
  printf 'exec %s "$@"\n' "$(command -v jq)"
} >"$VLH/stub/jq"; chmod +x "$VLH/stub/jq"
VLOUT="$(PATH="$VLH/stub:$PATH" HOME="$VLH" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$VLH/g.json" \
    OMABACKUP_STATE="$VLH/.state" XDG_RUNTIME_DIR=/nonexistent "$OB" verify --json 2>/dev/null)"

it "verify fails a mode:link group whose own mode query cannot be answered"
assert_eq "$(jq -r '.ok' <<<"$VLOUT")" "false"

it "and does not silently skip the link-integrity check for it"
assert_contains "$VLOUT" "editorconf"

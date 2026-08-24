# Collect regressions (bin/omabackup collect).
# One theme throughout: the manifest declares intent and the collector must
# honor it, or refuse loudly. Rationale: docs/CONTEXT.md §4,
# "a generic loop overrides specific handling".

OB="$PWD/bin/omabackup"

_env() {  # _env <home> <groups> <cmd...>
    local h="$1" g="$2"; shift 2
    HOME="$h" OMABACKUP_GROUPS="$g" OMABACKUP_STATE="$h/.state" \
        XDG_RUNTIME_DIR=/nonexistent "$OB" "$@" 2>&1
}

# -- exclude is honored -----------------------------------------------------------
H="$(mktemp -d)"; G="$H/g.json"
mkdir -p "$H/.config/app/node_modules/pacote" "$H/.config/app/src"
printf 'x\n' >"$H/.config/app/node_modules/pacote/index.js"
printf 'meu\n' >"$H/.config/app/src/main.lua"
cat >"$G" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,
  "paths":["~/.config/app"],"exclude":["node_modules/**"]}]}
JSON
_env "$H" "$G" collect >/dev/null

it "the manifest exclude keeps node_modules out of staging"
[[ ! -e "$H/.state/staging/.config/app/node_modules" ]] && ok || fail "node_modules was copied"

it "exclude does not take the rest with it"
assert_contains "$(cat "$H/.state/staging/.config/app/src/main.lua" 2>/dev/null)" "meu"

# -- mode:triple does not degrade into a generic copy -----------------------------
H="$(mktemp -d)"; G="$H/g.json"
P="$H/.config/omarchy/plugins/acme.dock"
mkdir -p "$P"
git init -q "$P"; git -C "$P" config user.email t@t; git -C "$P" config user.name t
printf 'slotSize: 42\n' >"$P/Dock.qml"
git -C "$P" add -A; git -C "$P" commit -qm base
git -C "$P" remote add origin https://github.com/acme/dock.git
printf 'slotSize: 56\n' >"$P/Dock.qml"
cat >"$G" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"plugins","label":"Plugins","mode":"triple","coupled":true,"critical":true,
  "paths":["~/.config/omarchy/plugins"]}]}
JSON
_env "$H" "$G" collect >/dev/null
ST="$H/.state/staging"

it "triple does not copy third-party plugin code"
[[ ! -e "$ST/.config/omarchy/plugins" ]] && ok || fail "the plugin directory was copied wholesale"

it "triple records URL and commit in the manifest"
assert_contains "$(cat "$ST/.plugins/manifest.txt" 2>/dev/null)" "github.com/acme/dock.git"

it "triple stores the local customization as a patch"
assert_contains "$(cat "$ST/.plugins/patches/acme.dock.patch" 2>/dev/null)" "slotSize: 56"

# -- the manifest cannot declare what the collector ignores -----------------------
H="$(mktemp -d)"; G="$H/g.json"
mkdir -p "$H/.config/app"
cat >"$G" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,
  "paths":["~/.config/app"],"fieldNobodyImplemented":true}]}
JSON
OUT="$(_env "$H" "$G" collect)"

it "an unknown manifest field aborts collect"
assert_contains "$OUT" "fieldNobodyImplemented"

it "an unknown field leaves no half-built staging"
[[ ! -d "$H/.state/staging" ]] && ok || fail "staging was created before aborting"

# -- an unknown mode too ----------------------------------------------------------
H="$(mktemp -d)"; G="$H/g.json"
mkdir -p "$H/.config/app"
cat >"$G" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"telepathy","coupled":false,"critical":false,
  "paths":["~/.config/app"]}]}
JSON
it "an unknown mode aborts collect"
assert_contains "$(_env "$H" "$G" collect)" "telepathy"

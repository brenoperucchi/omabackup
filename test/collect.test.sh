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

# -- tracked-only is per-path, not per-group -------------------------------------
H="$(mktemp -d)"; G="$H/g.json"; R="$H/repo"
mkdir -p "$R/dotfiles/.local-share-applications" "$H/.local/share/applications" "$H/.config"
git init -q "$R"; git -C "$R" config user.email t@t; git -C "$R" config user.name t
printf 'seen\n' >"$R/dotfiles/.local-share-applications/kept.desktop"
git -C "$R" add -A; git -C "$R" commit -qm base   # "tracked" means the git index, not the directory
printf 'kept\n'  >"$H/.local/share/applications/kept.desktop"
printf 'new\n'   >"$H/.local/share/applications/never-tracked.desktop"
printf 'icon\n'  >"$H/.local/share/applications/icon.png"
printf 'x=y\n'   >"$H/.config/mimeapps.list"
cat >"$G" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"desktop","label":"Desktop","mode":"copy","coupled":false,"critical":false,
  "paths":[{"live":"~/.local/share/applications","trackedRepoPath":"dotfiles/.local-share-applications"},
           "~/.config/mimeapps.list"]}]}
JSON
OMABACKUP_REPO="$R" _env "$H" "$G" collect >/dev/null
ST="$H/.state/staging"

it "a tracked-only path only stages what the repo already tracks"
assert_contains "$(cat "$ST/.local/share/applications/kept.desktop" 2>/dev/null)" "kept"

it "a tracked-only path never stages a name the repo never tracked"
[[ ! -e "$ST/.local/share/applications/never-tracked.desktop" ]] && ok || fail "an untracked desktop entry was staged"

it "a tracked-only path never stages an unrelated file type"
[[ ! -e "$ST/.local/share/applications/icon.png" ]] && ok || fail "a non-desktop file was staged"

it "a sibling plain-file path in the same group still copies normally"
assert_contains "$(cat "$ST/.config/mimeapps.list" 2>/dev/null)" "x=y"

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

# -- staging never accumulates stale content --------------------------------------
# A path a group used to declare, or a trackedOnly name that stopped matching,
# must not survive into the next collect: staging mirrors "right now", it is
# not an accumulating cache.
H="$(mktemp -d)"; G="$H/g.json"
mkdir -p "$H/.config/app"
printf 'x\n' >"$H/.config/app/keep.txt"
cat >"$G" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,
  "paths":["~/.config/app"]}]}
JSON
_env "$H" "$G" collect >/dev/null
mkdir -p "$H/.state/staging/.config/leftover"
printf 'stale\n' >"$H/.state/staging/.config/leftover/ghost.txt"
_env "$H" "$G" collect >/dev/null

it "a second collect wipes what an earlier run staged and no longer applies"
[[ ! -e "$H/.state/staging/.config/leftover" ]] && ok || fail "stale staging content survived a fresh collect"

it "a second collect still restages what is actually declared"
assert_contains "$(cat "$H/.state/staging/.config/app/keep.txt" 2>/dev/null)" "x"

# -- "tracked" means tracked by git, not merely present ----------------------------
# Deciding membership with `find` over the repo directory lets anything that
# landed there -- a stray file, an editor backup, output of an aborted run --
# start pulling its live counterpart in. Once junk is in the directory it
# perpetuates itself, which is exactly the accumulation staging was wiped to end.
H="$(mktemp -d)"; G="$H/g.json"; R="$H/repo"
mkdir -p "$R/dotfiles/.local-share-applications" "$H/.local/share/applications"
git init -q "$R"; git -C "$R" config user.email t@t; git -C "$R" config user.name t
printf 'a\n' >"$R/dotfiles/.local-share-applications/real.desktop"
git -C "$R" add -A; git -C "$R" commit -qm base
printf 'b\n' >"$R/dotfiles/.local-share-applications/junk.desktop"   # never `git add`ed
printf 'live-real\n' >"$H/.local/share/applications/real.desktop"
printf 'live-junk\n' >"$H/.local/share/applications/junk.desktop"
cat >"$G" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"desktop","label":"Desktop","mode":"copy","coupled":false,"critical":false,
  "paths":[{"live":"~/.local/share/applications","trackedRepoPath":"dotfiles/.local-share-applications"}]}]}
JSON
OMABACKUP_REPO="$R" _env "$H" "$G" collect >/dev/null
ST="$H/.state/staging"

it "a name the repo actually tracks is staged"
assert_contains "$(cat "$ST/.local/share/applications/real.desktop" 2>/dev/null)" "live-real"

it "a name merely sitting in the repo directory, untracked, is not"
[[ ! -e "$ST/.local/share/applications/junk.desktop" ]] && ok || fail "an untracked name in the repo directory pulled its live counterpart in"

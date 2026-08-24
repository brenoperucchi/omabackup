# Regressions for staging -> repo publishing (lib/publish.sh, cmd_sync).
# The mapping mirrors sync.sh's own conventions (docs/CONTEXT.md §4): a repo
# that already uses that layout needs no new rules.

source lib/publish.sh

# ── map_to_repo: the four general rules ──────────────────────────────────────
it "a .config path maps under configs/"
assert_eq "$(map_to_repo '.config/hypr/monitors.lua')" "configs/hypr/monitors.lua"

it "a nested .config file maps under configs/, preserving structure"
assert_eq "$(map_to_repo '.config/omarchy/shell.json')" "configs/omarchy/shell.json"

it "a top-level dotfile maps under dotfiles/"
assert_eq "$(map_to_repo '.bashrc')" "dotfiles/.bashrc"

it "omarchy state maps under state/omarchy/"
assert_eq "$(map_to_repo '.local/state/omarchy/toggles/hypr/flags.lua')" \
    "state/omarchy/toggles/hypr/flags.lua"

it "a desktop entry maps into the flat .local-share-applications convention"
assert_eq "$(map_to_repo '.local/share/applications/foo.desktop')" \
    "dotfiles/.local-share-applications/foo.desktop"

it "plugins are refused -- the triple strategy owns that path"
map_to_repo '.config/omarchy/plugins/acme.dock/Widget.qml' >/dev/null 2>&1
[[ $? -ne 0 ]] && ok || fail "should have failed for a plugin path"

it "a tracked-only script directory is refused -- collect writes it directly"
map_to_repo '.local/bin/my-script' >/dev/null 2>&1
[[ $? -ne 0 ]] && ok || fail "should have failed for .local/bin"

# ── publish_staging: end to end against a fake repo ──────────────────────────
STG="$(mktemp -d)"; REPO="$(mktemp -d)"
git init -q "$REPO"

mkdir -p "$STG/.config/hypr"
printf 'hl.monitor({})\n' >"$STG/.config/hypr/monitors.lua"
printf 'export EDITOR=nvim\n' >"$STG/.bashrc"
mkdir -p "$STG/.local/state/omarchy/toggles/hypr"
printf 'return {}\n' >"$STG/.local/state/omarchy/toggles/hypr/flags.lua"
mkdir -p "$STG/.generated"
printf 'git\nneovim\n' >"$STG/.generated/pkgs-explicit.txt"
mkdir -p "$STG/.plugins/patches" "$STG/.plugins/local/user.homegrown"
printf 'acme.dock https://github.com/acme/dock.git deadbeef\n' >"$STG/.plugins/manifest.txt"
printf '+slotSize: 56\n' >"$STG/.plugins/patches/acme.dock.patch"
printf 'return {}\n' >"$STG/.plugins/local/user.homegrown/Widget.qml"

publish_staging "$STG" "$REPO" >/dev/null

it "a .config path lands at the right place in the repo"
assert_contains "$(cat "$REPO/configs/hypr/monitors.lua" 2>/dev/null)" "hl.monitor"

it "a dotfile lands at the right place in the repo"
assert_contains "$(cat "$REPO/dotfiles/.bashrc" 2>/dev/null)" "EDITOR"

it "omarchy state lands at the right place in the repo"
assert_contains "$(cat "$REPO/state/omarchy/toggles/hypr/flags.lua" 2>/dev/null)" "return"

it "the generated package list is renamed to the repo's existing convention"
assert_contains "$(cat "$REPO/lists/pkgs-explicit.txt" 2>/dev/null)" "neovim"

it "the plugin manifest lands at lists/omarchy-plugins.txt"
assert_contains "$(cat "$REPO/lists/omarchy-plugins.txt" 2>/dev/null)" "acme/dock.git"

it "the plugin patch lands at patches/omarchy-plugins/"
assert_contains "$(cat "$REPO/patches/omarchy-plugins/acme.dock.patch" 2>/dev/null)" "slotSize"

it "a local plugin lands in full under configs/omarchy/plugins/"
assert_contains "$(cat "$REPO/configs/omarchy/plugins/user.homegrown/Widget.qml" 2>/dev/null)" "return"

# ── JSON normalization ────────────────────────────────────────────────────────
# Two writers serialize shell.json differently (jq -S vs. insertion order); a
# widget move should not rewrite the whole file in the diff.
STG2="$(mktemp -d)"; REPO2="$(mktemp -d)"; git init -q "$REPO2"
mkdir -p "$STG2/.config/omarchy" "$REPO2/configs/omarchy"
printf '{"b":2,"a":1}\n' >"$STG2/.config/omarchy/shell.json"
jq -S . <<<'{"a":1,"b":2}' >"$REPO2/configs/omarchy/shell.json"
git -C "$REPO2" add -A && git -C "$REPO2" commit -qm base
publish_staging "$STG2" "$REPO2" >/dev/null

it "reordered JSON keys produce no diff after normalization"
assert_eq "$(git -C "$REPO2" status --porcelain)" ""

# ── it never deletes ─────────────────────────────────────────────────────────
STG3="$(mktemp -d)"; REPO3="$(mktemp -d)"; git init -q "$REPO3"
mkdir -p "$REPO3/configs/gone"
printf 'still here\n' >"$REPO3/configs/gone/file.txt"
mkdir -p "$STG3/.config/present"
printf 'x\n' >"$STG3/.config/present/file.txt"
publish_staging "$STG3" "$REPO3" >/dev/null

it "a file that disappeared from the machine is left in the repo"
[[ -f "$REPO3/configs/gone/file.txt" ]] && ok || fail "publish deleted a file it never touched"

# Regressions for staging -> repo publishing (lib/publish.sh, cmd_sync).
# The mapping mirrors sync.sh's own conventions (docs/CONTEXT.md §4): a repo
# that already uses that layout needs no new rules.

source lib/publish.sh

# The manifest's trackedRepoPath entries, in the shape bin/omabackup builds
# them. map_to_repo consults this before its general rules.
TBL="$(printf '%s\t%s\n%s\t%s\n' \
    '.local/share/applications' 'dotfiles/.local-share-applications' \
    '.local/bin' 'scripts/local-bin')"

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

it "plugins are refused -- the triple strategy owns that path"
map_to_repo '.config/omarchy/plugins/acme.dock/Widget.qml' >/dev/null 2>&1
[[ $? -ne 0 ]] && ok || fail "should have failed for a plugin path"

# ── map_to_repo: destinations come from the manifest, not from literals ──────
# These three used to be hardcoded here: one destination repeated as a string
# literal, the other two refused with a comment claiming collect had already
# written them into the repo. It had not -- collect only ever writes into
# staging -- so the whole scripts group vanished between the two.
it "a desktop entry maps into the flat convention the manifest declared"
assert_eq "$(map_to_repo '.local/share/applications/foo.desktop' "$TBL")" \
    "dotfiles/.local-share-applications/foo.desktop"

it "a tracked-only script maps to the trackedRepoPath the manifest declared"
assert_eq "$(map_to_repo '.local/bin/my-script' "$TBL")" "scripts/local-bin/my-script"

it "a tracked-only path maps flat, never mirroring the live tree"
assert_eq "$(map_to_repo '.local/share/applications/sub/deep.desktop' "$TBL")" \
    "dotfiles/.local-share-applications/deep.desktop"

it "an executables directory the manifest never placed is refused, not guessed"
map_to_repo '.local/bin/my-script' >/dev/null 2>&1
[[ $? -ne 0 ]] && ok || fail "an undeclared .local/bin should not be published"

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

# ── symlinks are content too ──────────────────────────────────────────────────
# publish walked staging with `find -type f`, which excludes symlinks, so every
# staged link was silently dropped. A dotfiles tree is full of them: this
# machine stages ~/.config/nvim/lua/plugins/theme.lua and
# ~/.local/state/omarchy/current/background as links, and the destination repo
# tracks four. They were frozen at whatever the previous tool left, and a theme
# change that repointed one would never have reached the backup -- the same
# "declared but never actually saved" failure the whole project exists to catch.
STG4="$(mktemp -d)"; REPO4="$(mktemp -d)"; git init -q "$REPO4"
mkdir -p "$STG4/.config/app"
printf 'real\n' >"$STG4/.config/app/target.txt"
ln -s target.txt "$STG4/.config/app/link.txt"
ln -s /nowhere/outside/theme.lua "$STG4/.config/app/dangling.lua"
printf '#!/bin/sh\necho hi\n' >"$STG4/.config/app/script.sh"
chmod +x "$STG4/.config/app/script.sh"
publish_staging "$STG4" "$REPO4" >/dev/null

it "a staged symlink reaches the repo"
[[ -L "$REPO4/configs/app/link.txt" ]] && ok || fail "the symlink was dropped or flattened into a copy"

it "and arrives as a link, not as a copy of what it pointed at"
assert_eq "$(readlink "$REPO4/configs/app/link.txt" 2>/dev/null)" "target.txt"

it "a symlink pointing outside the tree survives too, target string intact"
assert_eq "$(readlink "$REPO4/configs/app/dangling.lua" 2>/dev/null)" "/nowhere/outside/theme.lua"

it "the executable bit survives the trip"
[[ -x "$REPO4/configs/app/script.sh" ]] && ok || fail "mode was not preserved"

it "and ordinary files still publish alongside them"
assert_contains "$(cat "$REPO4/configs/app/target.txt" 2>/dev/null)" "real"

# ── publishing is not allowed to cost a process per file ─────────────────────
# _publish_file used `rsync` for single regular files. Measured here: an rsync
# spawn is ~44ms against ~0.5ms for cp, so 597 staged files spent 27 of a sync's
# 33 seconds paying startup cost 597 times. That is what made a 5-minute timer
# indefensible. The bound below is deliberately loose -- it is there to catch an
# 85x regression, not to police milliseconds.
STG5="$(mktemp -d)"; REPO5="$(mktemp -d)"; git init -q "$REPO5"
mkdir -p "$STG5/.config/many"
for i in $(seq 1 300); do printf 'file %s\n' "$i" >"$STG5/.config/many/f$i.txt"; done
PUB_START="$(date +%s)"
publish_staging "$STG5" "$REPO5" >/dev/null
PUB_ELAPSED=$(( $(date +%s) - PUB_START ))

it "300 files publish in well under the old per-file rsync cost"
(( PUB_ELAPSED < 10 )) && ok || fail "took ${PUB_ELAPSED}s -- a process per file is back"

it "and all 300 actually arrived"
assert_eq "$(find "$REPO5/configs/many" -type f | wc -l)" "300"

# ── the destination may itself be a symlink ─────────────────────────────────
# `cp -p` follows a symlink that already exists at the destination and writes
# through it. With a repo path that is a link pointing outside the repo, publish
# overwrote somebody else's file instead of replacing the link -- reproduced.
STG6="$(mktemp -d)"; REPO6="$(mktemp -d)"; OUTSIDE="$(mktemp -d)"
git init -q "$REPO6"
mkdir -p "$REPO6/configs/app"
printf 'belongs to someone else\n' >"$OUTSIDE/target.txt"
ln -s "$OUTSIDE/target.txt" "$REPO6/configs/app/f.txt"
mkdir -p "$STG6/.config/app"
printf 'backup content\n' >"$STG6/.config/app/f.txt"
publish_staging "$STG6" "$REPO6" >/dev/null

it "publishing over a symlinked destination does not write outside the repo"
assert_eq "$(cat "$OUTSIDE/target.txt")" "belongs to someone else"

it "and replaces the link with the real file instead"
[[ -f "$REPO6/configs/app/f.txt" && ! -L "$REPO6/configs/app/f.txt" ]] \
    && ok || fail "the destination is still a symlink"

it "with the content the backup meant to store"
assert_contains "$(cat "$REPO6/configs/app/f.txt")" "backup content"

# ── a symlink inside a local plugin is content too ──────────────────────────
# The main loop learned this; the local-plugin branch kept `find -type f` and
# so copied links with rsync while leaving them out of the list that gets
# committed. Written but never staged is the same silence one directory over.
STG7="$(mktemp -d)"; REPO7="$(mktemp -d)"; git init -q "$REPO7"
mkdir -p "$STG7/.plugins/local/user.thing"
printf 'return {}\n' >"$STG7/.plugins/local/user.thing/Widget.qml"
ln -s Widget.qml "$STG7/.plugins/local/user.thing/alias.qml"
LIST7="$(mktemp)"
publish_staging "$STG7" "$REPO7" "" "$LIST7" >/dev/null

it "a symlink inside a local plugin is recorded for commit, not just copied"
assert_contains "$(tr '\0' '\n' <"$LIST7")" "alias.qml"

# ── a find that stops partway is a publish failure, not a silent undercount ─
# `done < <(find "$staging" ... -print0 2>/dev/null)` had no `wait "$!"`
# afterward -- find's own exit status was discarded the same way restore_rows
# and scan_files were already closed against. A stub find that prints one
# file then exits nonzero, simulating a walk that stopped partway, confirmed
# the result: publish_staging returned 0 having published fewer files than
# staging actually held.
PFH="$(mktemp -d)"; PFSTG="$PFH/staging"; PFREPO="$PFH/repo"
mkdir -p "$PFSTG/configs/app"
printf 'x\n' >"$PFSTG/configs/app/f1.txt"
printf 'y\n' >"$PFSTG/configs/app/f2.txt"
git init -q "$PFREPO"; git -C "$PFREPO" config user.email t@t; git -C "$PFREPO" config user.name t
mkdir -p "$PFH/stub"
cat >"$PFH/stub/find" <<STUB
#!/bin/bash
printf '%s\0' "$PFSTG/configs/app/f1.txt"
exit 9
STUB
chmod +x "$PFH/stub/find"

it "publish_staging fails when its own walk stops partway"
PATH="$PFH/stub:$PATH" publish_staging "$PFSTG" "$PFREPO" >/dev/null 2>&1 \
    && fail "reported success despite the walk stopping partway" || ok

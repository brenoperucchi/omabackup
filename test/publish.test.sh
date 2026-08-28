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

# ── two staged files mapping to the same destination refuse, not overwrite ──
# map_to_repo maps FLAT for a trackedRepoPath entry -- the repo keeps one
# directory of names, not a mirror -- and nothing stopped two DIFFERENT
# staged files from landing on the SAME repo destination: two groups whose
# trackedRepoPath both name the same repo directory, each holding a file
# with the same basename. A PoC confirmed the result: both wrote, the
# second silently overwrote the first, "2 files" published, one gone,
# exit 0.
DDH="$(mktemp -d)"
mkdir -p "$DDH/staging/a" "$DDH/staging/b" "$DDH/repo"
printf 'content-A\n' >"$DDH/staging/a/same.txt"
printf 'content-B\n' >"$DDH/staging/b/same.txt"
git init -q "$DDH/repo"; git -C "$DDH/repo" config user.email t@t; git -C "$DDH/repo" config user.name t
DDTABLE="$(printf 'a\tshared\nb\tshared\n')"

it "publish_staging refuses two staged files that collide on one destination"
publish_staging "$DDH/staging" "$DDH/repo" "$DDTABLE" >/dev/null 2>&1 \
    && fail "reported success despite a destination collision" || ok

it "and neither file's content silently overwrote the other"
[[ ! -e "$DDH/repo/shared/same.txt" ]] \
    && ok || fail "one file's content landed anyway, indistinguishable from a clean publish: $(cat "$DDH/repo/shared/same.txt" 2>/dev/null)"

# ── the most specific trackedRepoPath wins, not the one earlier in the table ─
# The first matching prefix used to win outright -- if the table declares
# BOTH "root" and "root/nested" (an override for a directory nested inside
# another trackedRepoPath), a file under root/nested/ matched both, and
# which one answered depended on table ORDER, not on which mapping was
# actually meant for it. A PoC confirmed the result changed with the two
# entries simply swapped.
it "root/nested wins over root, regardless of which comes first in the table"
T1="$(printf 'root\tshared\nroot/nested\tshared/nested\n')"
T2="$(printf 'root/nested\tshared/nested\nroot\tshared\n')"
assert_eq "$(map_to_repo 'root/nested/file.txt' "$T1")" "shared/nested/file.txt"
assert_eq "$(map_to_repo 'root/nested/file.txt' "$T2")" "shared/nested/file.txt"

# ── a preflight failure aborts before any write, not just at the end ────────
# The first fix (find's status checked, `failed` incremented) still fell
# through to the write pass regardless -- a PoC confirmed rc=1 reported, but
# only after the file the preflight DID manage to see had already been
# written. Now the whole function returns as soon as the preflight's own
# walk fails, before either pass over the captured list ever runs.
PA1H="$(mktemp -d)"
# .config/app/f1.txt, not configs/app/f1.txt: map_to_repo's default case
# only maps a leading-dot path (its .config/* fallback); the un-dotted
# spelling map_to_repo already refuses on its own, before the preflight
# fix is even reached, which made the original spec pass identically
# against the pre-fix code too -- it wasn't exercising the abort at all.
mkdir -p "$PA1H/staging/.config/app" "$PA1H/repo"
printf 'x\n' >"$PA1H/staging/.config/app/f1.txt"
git init -q "$PA1H/repo"; git -C "$PA1H/repo" config user.email t@t; git -C "$PA1H/repo" config user.name t
mkdir -p "$PA1H/stub"
cat >"$PA1H/stub/find" <<STUB
#!/bin/bash
printf '%s\0' "$PA1H/staging/.config/app/f1.txt"
exit 9
STUB
chmod +x "$PA1H/stub/find"

it "publish_staging aborts on a preflight failure before writing anything"
PATH="$PA1H/stub:$PATH" publish_staging "$PA1H/staging" "$PA1H/repo" >/dev/null 2>&1
[[ -z "$(find "$PA1H/repo" -type f ! -path '*/.git/*' 2>/dev/null)" ]] \
    && ok || fail "a file was written despite the preflight walk failing"

# ── a normal staged file colliding with a generated destination is caught ───
# .generated and .plugins/manifest.txt/patches were skipped by the collision
# count and written separately after -- a regular staged file whose
# trackedRepoPath happens to name the identical destination as a generated
# list (lists/pkgs-explicit.txt is real, reachable through a manifest that
# declares it) silently overwrote whichever one wrote last. Both namespaces
# are folded into the same collision map now.
PA3H="$(mktemp -d)"
mkdir -p "$PA3H/staging/.generated" "$PA3H/staging/tracked" "$PA3H/repo"
printf 'generated-content\n' >"$PA3H/staging/.generated/pkgs-explicit.txt"
printf 'staged-content\n' >"$PA3H/staging/tracked/pkgs-explicit.txt"
git init -q "$PA3H/repo"; git -C "$PA3H/repo" config user.email t@t; git -C "$PA3H/repo" config user.name t
PA3TABLE="$(printf 'tracked\tlists\n')"

it "a staged file colliding with a generated list's destination is refused"
publish_staging "$PA3H/staging" "$PA3H/repo" "$PA3TABLE" >/dev/null 2>&1 \
    && fail "published despite the generated/staged collision" || ok

it "and neither one silently landed there"
[[ ! -e "$PA3H/repo/lists/pkgs-explicit.txt" ]] \
    && ok || fail "one of the two colliding sources landed anyway"

# ── ancestor/descendant collision in the PUBLISH destination is caught ──────
# destcount keyed by exact equality only -- "shared" and "shared/child" never
# collide as strings, but a PoC forcing the more specific one to enumerate
# first turned the less specific one's own file into a directory COMPONENT
# of the other's path (shared/child/child instead of two real files), rc=0.
PA4H="$(mktemp -d)"
mkdir -p "$PA4H/staging/a" "$PA4H/staging/b" "$PA4H/repo"
printf 'a-content\n' >"$PA4H/staging/a/child"
printf 'b-content\n' >"$PA4H/staging/b/x"
git init -q "$PA4H/repo"; git -C "$PA4H/repo" config user.email t@t; git -C "$PA4H/repo" config user.name t
PA4TABLE="$(printf 'a\tshared\nb\tshared/child\n')"

it "an ancestor and descendant publish destination collide, refused"
publish_staging "$PA4H/staging" "$PA4H/repo" "$PA4TABLE" >/dev/null 2>&1 \
    && fail "published despite the ancestor/descendant destination collision" || ok

it "and nothing landed under shared/ at all"
[[ -z "$(find "$PA4H/repo/shared" -type f 2>/dev/null)" ]] \
    && ok || fail "something was written despite the collision"

# ── a symlinked ancestor directory in the repo is not written through ───────
# --remove-destination protects the final path component; nothing protected
# an ANCESTOR directory that is itself a symlink. A PoC (repo/configs ->
# /tmp/outside) had mkdir -p follow it same as any real directory, writing
# outside the repo entirely, rc=0.
PA7H="$(mktemp -d)"
mkdir -p "$PA7H/staging/.config/app" "$PA7H/outside" "$PA7H/repo"
printf 'staged\n' >"$PA7H/staging/.config/app/f.txt"
git init -q "$PA7H/repo"; git -C "$PA7H/repo" config user.email t@t; git -C "$PA7H/repo" config user.name t
ln -s "$PA7H/outside" "$PA7H/repo/configs"

it "publish_staging refuses to write through a symlinked ancestor directory"
publish_staging "$PA7H/staging" "$PA7H/repo" >/dev/null 2>&1 \
    && fail "wrote through the symlinked configs/ directory" || ok

it "and nothing landed outside the repo"
[[ -z "$(find "$PA7H/outside" -type f 2>/dev/null)" ]] \
    && ok || fail "a file was written outside the repo through the symlink"

# ── a plugin patch symlink is not followed either ────────────────────────────
# The patches loop used a bare `cp`, bypassing _publish_file's own
# --remove-destination protection entirely. A pre-planted symlink at the
# exact destination path had its target silently overwritten instead.
PA8H="$(mktemp -d)"
mkdir -p "$PA8H/staging/.plugins/patches" "$PA8H/outside" "$PA8H/repo/patches/omarchy-plugins"
printf 'sensitive\n' >"$PA8H/outside/victim.patch"
printf 'patch-content\n' >"$PA8H/staging/.plugins/patches/a.patch"
git init -q "$PA8H/repo"; git -C "$PA8H/repo" config user.email t@t; git -C "$PA8H/repo" config user.name t
ln -s "$PA8H/outside/victim.patch" "$PA8H/repo/patches/omarchy-plugins/a.patch"

it "a plugin patch does not write through a pre-planted symlink"
publish_staging "$PA8H/staging" "$PA8H/repo" >/dev/null 2>&1
assert_eq "$(cat "$PA8H/outside/victim.patch")" "sensitive"

it "and the real patch content landed in the repo instead"
assert_eq "$(cat "$PA8H/repo/patches/omarchy-plugins/a.patch" 2>/dev/null)" "patch-content"

# ── the JSON-normalization tmp file does not follow a pre-planted symlink ───
# `jq -S . "$src" >"$dst.tmp"` is a plain shell redirection -- it follows a
# symlink already sitting at "$dst.tmp" the same way plain cp follows one at
# "$dst". --remove-destination has no equivalent for a redirection; a PoC
# with configs/app/f.json.tmp -> an outside victim file confirmed it wrote
# through the link and returned rc=0.
PA9H="$(mktemp -d)"
mkdir -p "$PA9H/staging/.config/app" "$PA9H/outside" "$PA9H/repo/configs/app"
printf '{"a":1}\n' >"$PA9H/staging/.config/app/f.json"
printf 'sensitive\n' >"$PA9H/outside/victim.json"
git init -q "$PA9H/repo"; git -C "$PA9H/repo" config user.email t@t; git -C "$PA9H/repo" config user.name t
ln -s "$PA9H/outside/victim.json" "$PA9H/repo/configs/app/f.json.tmp"

it "the JSON normalization tmp write does not follow a pre-planted symlink"
publish_staging "$PA9H/staging" "$PA9H/repo" >/dev/null 2>&1
assert_eq "$(cat "$PA9H/outside/victim.json")" "sensitive"

it "and the normalized JSON landed in the repo instead"
assert_eq "$(cat "$PA9H/repo/configs/app/f.json" 2>/dev/null)" "$(printf '{\n  "a": 1\n}')"

# ── two destinations that are the same physical file via a repo symlink ─────
# destcount used to be keyed on the raw declared dst string -- two DIFFERENT
# trackedRepoPath entries whose destinations are the same file on disk only
# because one repo directory is a symlink to the other never collided as
# strings. A PoC (repo/configs/alias -> repo/configs/real) confirmed both
# published, one silently overwriting the other through the alias.
PA10H="$(mktemp -d)"
mkdir -p "$PA10H/staging/.config/appA" "$PA10H/staging/.config/appB" "$PA10H/repo/configs/real"
printf 'from-A\n' >"$PA10H/staging/.config/appA/f.json"
printf 'from-B\n' >"$PA10H/staging/.config/appB/f.json"
git init -q "$PA10H/repo"; git -C "$PA10H/repo" config user.email t@t; git -C "$PA10H/repo" config user.name t
ln -s "$PA10H/repo/configs/real" "$PA10H/repo/configs/alias"
PA10TABLE="$(printf '.config/appA\tconfigs/alias\n.config/appB\tconfigs/real\n')"

it "two destinations aliased by a repo symlink refuse, not overwrite"
publish_staging "$PA10H/staging" "$PA10H/repo" "$PA10TABLE" >/dev/null 2>&1 \
    && fail "reported success despite a physical destination collision" || ok

it "and neither one silently landed there"
[[ -z "$(find "$PA10H/repo/configs/real" -mindepth 1 -type f 2>/dev/null)" ]] \
    && ok || fail "one of the two aliased sources landed anyway"

# ── a pre-existing directory at the destination path is refused ─────────────
# --remove-destination unlinks a file or a symlink already at $dst; it does
# nothing to an existing DIRECTORY there. A PoC confirmed cp then wrote
# INSIDE it instead -- configs/app/f.json/f.json, rc=0, silent structural
# corruption of the repo rather than the intended overwrite.
PA11H="$(mktemp -d)"
mkdir -p "$PA11H/staging/.config/app" "$PA11H/repo/configs/app/f.json"
printf 'staged-content\n' >"$PA11H/staging/.config/app/f.json"
printf 'pre-existing\n' >"$PA11H/repo/configs/app/f.json/inner.txt"
git init -q "$PA11H/repo"; git -C "$PA11H/repo" config user.email t@t; git -C "$PA11H/repo" config user.name t

it "a pre-existing directory at the destination path is refused, not written into"
publish_staging "$PA11H/staging" "$PA11H/repo" >/dev/null 2>&1 \
    && fail "reported success despite a directory sitting at the destination" || ok

it "and the directory's own contents are untouched"
assert_eq "$(cat "$PA11H/repo/configs/app/f.json/inner.txt" 2>/dev/null)" "pre-existing"

# ── a plugin tree colliding with a regular staged file is caught too ────────
# .plugins/local was written by its own rsync block, never compared against
# the destcount map every other staged source (including .generated and
# .plugins/manifest.txt/patches) is folded into. A PoC confirmed the result:
# a regular staged file and a plugin's own tree both landing on
# configs/omarchy/plugins/mytheme/init.lua published, one silently
# overwrote the other, rc=0.
PA12H="$(mktemp -d)"
mkdir -p "$PA12H/staging/.plugins/local/mytheme" "$PA12H/staging/.config/mytheme" "$PA12H/repo"
printf 'plugin-tree-content\n' >"$PA12H/staging/.plugins/local/mytheme/init.lua"
printf 'staged-collision\n' >"$PA12H/staging/.config/mytheme/init.lua"
git init -q "$PA12H/repo"; git -C "$PA12H/repo" config user.email t@t; git -C "$PA12H/repo" config user.name t
PA12TABLE="$(printf '.config/mytheme\tconfigs/omarchy/plugins/mytheme\n')"

it "a plugin tree file colliding with a regular staged destination is refused"
publish_staging "$PA12H/staging" "$PA12H/repo" "$PA12TABLE" >/dev/null 2>&1 \
    && fail "published despite the plugin-tree/staged-file collision" || ok

it "and neither one silently landed there"
[[ ! -e "$PA12H/repo/configs/omarchy/plugins/mytheme/init.lua" ]] \
    && ok || fail "one of the two colliding sources landed anyway"

# ── a file that appears in a plugin tree AFTER the collision check is not ───
# ── copied by the rsync that follows it ──────────────────────────────────────
# rsync used to be pointed at the plugin's whole directory and left to walk
# it again on its own at write time -- a file that appeared between the
# preflight collision check above and that second walk was never checked
# against the collision map at all, but rsync copied it anyway. A PoC (a
# stub find that plants a new file into the plugin directory right after
# answering the preflight walk, simulating the race) confirmed the result:
# the raced-in file silently overwrote a regular staged file already
# sitting at the identical destination. rsync is now given the EXACT file
# list the preflight walk captured via --files-from, incapable of copying
# anything outside it by construction.
PA13H="$(mktemp -d)"
mkdir -p "$PA13H/staging/.plugins/local/mytheme" "$PA13H/staging/.config/other" "$PA13H/repo"
printf 'plugin-a\n' >"$PA13H/staging/.plugins/local/mytheme/a.txt"
printf 'staged-regular\n' >"$PA13H/staging/.config/other/new.txt"
git init -q "$PA13H/repo"; git -C "$PA13H/repo" config user.email t@t; git -C "$PA13H/repo" config user.name t
PA13TABLE="$(printf '.config/other\tconfigs/omarchy/plugins/mytheme\n')"
mkdir -p "$PA13H/stub"
cat >"$PA13H/stub/find" <<STUB
#!/bin/bash
if [[ "\$1" == "$PA13H/staging/.plugins/local/mytheme/" && ! -e "$PA13H/.raced" ]]; then
    touch "$PA13H/.raced"
    $(type -P find) "\$@"
    printf 'race-injected\n' >"$PA13H/staging/.plugins/local/mytheme/new.txt"
else
    exec $(type -P find) "\$@"
fi
STUB
chmod +x "$PA13H/stub/find"

PATH="$PA13H/stub:$PATH" publish_staging "$PA13H/staging" "$PA13H/repo" "$PA13TABLE" >/dev/null 2>&1

it "a file racing into a plugin tree after the preflight check is not copied over another"
assert_eq "$(cat "$PA13H/repo/configs/omarchy/plugins/mytheme/new.txt" 2>/dev/null)" "staged-regular"

# ── a $dst.tmp that cannot be unlinked is refused before the redirect opens ──
# rm -f "$dst.tmp"'s own status used to be discarded (2>/dev/null swallows
# it, and nothing checked the exit code either). A directory that refuses
# to let an entry be removed -- but still lets an EXISTING file reached
# through it be opened for writing, since that needs permission on the
# FILE, not the directory -- left a pre-planted symlink standing, and the
# `jq -S ... >"$dst.tmp"` redirect right after wrote straight through it.
# A PoC confirmed the result: mv failed afterward (permission denied on the
# directory), publish reported rc=1 -- but the external file was already
# overwritten with the normalized JSON by the time anything could react to
# that failure. The later refusal does not undo an external write that
# already happened.
PDTH="$(mktemp -d)"
mkdir -p "$PDTH/staging/.config/app" "$PDTH/outside" "$PDTH/repo/configs/app"
printf '{"a":1}\n' >"$PDTH/staging/.config/app/f.json"
printf 'victim-original\n' >"$PDTH/outside/victim.json"
chmod 666 "$PDTH/outside/victim.json"
git init -q "$PDTH/repo"; git -C "$PDTH/repo" config user.email t@t; git -C "$PDTH/repo" config user.name t
ln -s "$PDTH/outside/victim.json" "$PDTH/repo/configs/app/f.json.tmp"
chmod 555 "$PDTH/repo/configs/app"

publish_staging "$PDTH/staging" "$PDTH/repo" >/dev/null 2>&1
chmod 755 "$PDTH/repo/configs/app" 2>/dev/null

it "a dst.tmp that cannot be unlinked is refused before the redirect can write through it"
assert_eq "$(cat "$PDTH/outside/victim.json" 2>/dev/null)" "victim-original"

# ── a failed write of the --files-from list is not reported as published ────
# printf '%s\0' "${pfiles[@]}" >"$pflist" had its own status discarded --
# a write that failed left $pflist empty or truncated, --files-from copied
# fewer files than pfiles actually named, rsync itself still exited 0 for
# whatever it WAS given, and every name in pfiles was still added to
# written regardless. `enable -n printf` plus a stub that fails only on
# this exact format string (%s\0, used nowhere else printf builds this
# specific list) reproduces it without touching any other printf call in
# the same run.
PFH="$(mktemp -d)"
mkdir -p "$PFH/staging/.plugins/local/mytheme" "$PFH/repo"
printf 'plugin-a\n' >"$PFH/staging/.plugins/local/mytheme/a.txt"
git init -q "$PFH/repo"; git -C "$PFH/repo" config user.email t@t; git -C "$PFH/repo" config user.name t
mkdir -p "$PFH/stub"
{ printf '#!/bin/bash\n'
  printf 'if [[ "$1" == '"'"'%%s\\0'"'"' ]]; then exit 1; fi\n'
  printf 'exec /usr/bin/printf "$@"\n'
} >"$PFH/stub/printf"; chmod +x "$PFH/stub/printf"

PFOUT="$(bash -c '
    enable -n printf
    PATH="$1/stub:$PATH"
    source lib/publish.sh
    n="$(publish_staging "$2" "$3")"
    printf "rc=%s n=%s" "$?" "$n"
' _ "$PFH" "$PFH/staging" "$PFH/repo")"

it "publish_staging does not report a plugin file as published when its files-from list failed to write"
[[ "$PFOUT" == rc=1* ]] \
    && ok || fail "expected a nonzero rc, got: $PFOUT"

it "and the file was not actually copied into the repo"
[[ -z "$(find "$PFH/repo/configs/omarchy/plugins" -type f 2>/dev/null)" ]] \
    && ok || fail "a file landed in the repo despite the list write failing"

# ── map_to_repo's own refusal is reported, not silently swallowed ───────────
# `dst="$(map_to_repo "$rel" "$table")" || continue` dropped a file that
# map_to_repo deliberately refuses to place (.local/bin with no
# trackedRepoPath override, the documented "refuse rather than guess"
# case) with no record at all: not published, not counted as failed,
# nothing said. A PoC (a staged file under .local/bin/, no trackedRepoPath
# table entry naming it) confirmed the result: publish_staging returned
# rc=0 with 0 files published -- indistinguishable from a clean sync with
# genuinely nothing to do.
MTH2="$(mktemp -d)"; MTR2="$MTH2/repo"
git init -q "$MTR2"; git -C "$MTR2" config user.email t@t; git -C "$MTR2" config user.name t
mkdir -p "$MTR2/x"; printf 'x\n' >"$MTR2/x/f"
git -C "$MTR2" add -A && git -C "$MTR2" commit -qm one
mkdir -p "$MTH2/staging/.local/bin"
printf '#!/bin/bash\necho hi\n' >"$MTH2/staging/.local/bin/tool"

it "publish_staging reports failure when map_to_repo refuses to place a file"
publish_staging "$MTH2/staging" "$MTR2" >/dev/null 2>&1 \
    && fail "reported success despite map_to_repo refusing to map a staged file" || ok

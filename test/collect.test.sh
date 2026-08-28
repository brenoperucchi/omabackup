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

# -- the global `excluded` list reaches rsync too ----------------------------------
# A group's own `exclude` patterns are already relative to the path being
# copied, so they worked. The manifest-wide `excluded` entries are written as
# full paths (`~/.config/nvim/lazy-lock.json`) and were handed to rsync with
# only the leading `~/` stripped -- but rsync matches against the transfer root,
# so `.config/nvim/lazy-lock.json` never matched anything and the file the
# manifest called "constant diff noise" was backed up on every run.
H="$(mktemp -d)"; G="$H/g.json"
mkdir -p "$H/.config/editor/sub"
printf 'keep\n'  >"$H/.config/editor/init.lua"
printf 'noise\n' >"$H/.config/editor/lock.json"
printf 'deep\n'  >"$H/.config/editor/sub/nested.lua"
cat >"$G" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],
 "excluded":[{"path":"~/.config/editor/lock.json","reason":"regenerated on every run"}],
 "groups":[
 {"id":"editor","label":"Editor","mode":"copy","coupled":false,"critical":false,
  "paths":["~/.config/editor"]}]}
JSON
_env "$H" "$G" collect >/dev/null
ST="$H/.state/staging"

it "a globally excluded file nested under a declared directory is not staged"
[[ ! -e "$ST/.config/editor/lock.json" ]] && ok || fail "the excluded file was collected anyway"

it "excluding one file does not take its directory with it"
assert_contains "$(cat "$ST/.config/editor/init.lua" 2>/dev/null)" "keep"

it "and does not take unrelated nested files either"
assert_contains "$(cat "$ST/.config/editor/sub/nested.lua" 2>/dev/null)" "deep"

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

# -- and non-ASCII names survive the trip ------------------------------------------
# `git ls-files` without -z quotes anything outside ASCII: a tracked script
# called `ação.sh` comes back as "scripts/local-bin/a\303\247\303\243o.sh",
# quotes and all, so the direct-child test never matched and the file silently
# stopped being backed up. Not a hypothetical in a pt-BR home directory.
H="$(mktemp -d)"; G="$H/g.json"; R="$H/repo"
mkdir -p "$R/scripts/local-bin" "$H/.local/bin"
git init -q "$R"; git -C "$R" config user.email t@t; git -C "$R" config user.name t
printf 'v1\n' >"$R/scripts/local-bin/ação.sh"
printf 'v1\n' >"$R/scripts/local-bin/plain.sh"
git -C "$R" add -A; git -C "$R" commit -qm base
printf 'v2\n' >"$H/.local/bin/ação.sh"
printf 'v2\n' >"$H/.local/bin/plain.sh"
cat >"$G" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"scripts","label":"Scripts","mode":"copy","coupled":false,"critical":false,
  "paths":[{"live":"~/.local/bin","trackedRepoPath":"scripts/local-bin"}]}]}
JSON
OMABACKUP_REPO="$R" _env "$H" "$G" collect >/dev/null
ST="$H/.state/staging"

it "a tracked name with non-ASCII characters is staged"
assert_contains "$(cat "$ST/.local/bin/ação.sh" 2>/dev/null)" "v2"

it "and its plain-ASCII sibling still is too"
assert_contains "$(cat "$ST/.local/bin/plain.sh" 2>/dev/null)" "v2"

# -- a declared path that is itself excluded ---------------------------------------
# The exclusion translation only ever looked at descendants of the transfer
# root, so a path that is both declared by a group and listed in `excluded` was
# collected in full -- the manifest contradicting itself, resolved silently in
# favour of copying.
H="$(mktemp -d)"; G="$H/g.json"
mkdir -p "$H/.config/keep" "$H/.config/drop"
printf 'yes\n' >"$H/.config/keep/f.txt"
printf 'no\n'  >"$H/.config/drop/f.txt"
cat >"$G" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],
 "excluded":[{"path":"~/.config/drop","reason":"declared by a group but dead weight"}],
 "groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,
  "paths":["~/.config/keep","~/.config/drop"]}]}
JSON
_env "$H" "$G" collect >/dev/null
ST="$H/.state/staging"

it "a declared path that is itself excluded is not collected"
[[ ! -e "$ST/.config/drop" ]] && ok || fail "the excluded path was collected wholesale"

it "and its declared sibling still is"
assert_contains "$(cat "$ST/.config/keep/f.txt" 2>/dev/null)" "yes"

# ── a trackedRepoPath query that fails refuses to collect, not falls back ───
# `[[ -n "$(group_tracked_repo_path "$id" "$p")" ]]` could not tell "no
# override" from "the query itself failed" -- both are an empty string. A
# stub jq that fails only on the trackedRepoPath query, with a genuinely
# tracked-only path declared, confirmed the result: collect fell through to
# the generic rsync branch, which copies both tracked and untracked names
# into the same directory instead of refusing to guess.
TRPH="$(mktemp -d)"; TRPR="$TRPH/repo"
mkdir -p "$TRPR/scripts/local-bin"
git init -q "$TRPR"; git -C "$TRPR" config user.email t@t; git -C "$TRPR" config user.name t
printf '#!/bin/bash\necho hi\n' >"$TRPR/scripts/local-bin/tracked.sh"
git -C "$TRPR" add -A && git -C "$TRPR" commit -qm one
cat >"$TRPH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"scripts","label":"Scripts","mode":"copy","coupled":false,"critical":false,
  "paths":[{"live":"~/.local/bin","trackedRepoPath":"scripts/local-bin"}]}]}
JSON
mkdir -p "$TRPH/home/.local/bin"
printf '#!/bin/bash\necho hi\n' >"$TRPH/home/.local/bin/tracked.sh"
mkdir -p "$TRPH/stub"
{ printf '#!/bin/bash\n'
  printf 'for a in "$@"; do [[ "$a" == *trackedRepoPath* ]] && exit 9; done\n'
  printf 'exec %s "$@"\n' "$(command -v jq)"
} >"$TRPH/stub/jq"; chmod +x "$TRPH/stub/jq"

it "collect refuses when a trackedRepoPath query fails, rather than guessing"
HOME="$TRPH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$TRPH/g.json" \
    OMABACKUP_STATE="$TRPH/home/.state" OMABACKUP_REPO="$TRPR" \
    PATH="$TRPH/stub:$PATH" XDG_RUNTIME_DIR=/nonexistent "$OB" collect >/dev/null 2>&1 \
    && fail "collected via a generic rsync fallback instead of refusing" || ok

# ── a group_paths query that fails during collect_triple refuses, not "0" ───
# `dir="$(_expand "$(group_paths "$id" | head -1)")"` lost group_paths' own
# status twice over: head exits 0 regardless of whether its upstream
# producer failed, and even a correct pipefail status on the INNER
# substitution is not what the OUTER one (_expand's own, which never fails)
# reports. A stub jq that fails only on group_paths' own query, with a real
# local plugin present, confirmed the result: dir came back empty,
# [[ -d "$dir" ]] read that as "nothing to collect," and collect reported
# success having never looked up the plugin directory at all.
CTH="$(mktemp -d)"; CTR="$CTH/repo"
git init -q "$CTR"; git -C "$CTR" config user.email t@t; git -C "$CTR" config user.name t
mkdir -p "$CTR/x"; printf 'x\n' >"$CTR/x/f"
git -C "$CTR" add -A && git -C "$CTR" commit -qm one
cat >"$CTH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"plugins","label":"Plugins","mode":"triple","coupled":false,"critical":false,
  "paths":["~/.config/omarchy/plugins"]}]}
JSON
mkdir -p "$CTH/home/.config/omarchy/plugins/myplugin"
git init -q "$CTH/home/.config/omarchy/plugins/myplugin" >/dev/null 2>&1
printf 'x\n' >"$CTH/home/.config/omarchy/plugins/myplugin/f.txt"
mkdir -p "$CTH/stub"
{ printf '#!/bin/bash\n'
  printf 'for a in "$@"; do [[ "$a" == *"(.paths // [])"* ]] && exit 9; done\n'
  printf 'exec %s "$@"\n' "$(command -v jq)"
} >"$CTH/stub/jq"; chmod +x "$CTH/stub/jq"

it "collect refuses when a triple group's paths query fails"
HOME="$CTH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$CTH/g.json" \
    OMABACKUP_STATE="$CTH/home/.state" OMABACKUP_REPO="$CTR" \
    PATH="$CTH/stub:$PATH" XDG_RUNTIME_DIR=/nonexistent "$OB" collect >/dev/null 2>&1 \
    && fail "reported success without ever finding the plugin directory" || ok

# ── a failed exclusion query is refused, not read as "nothing excluded" ─────
# is_excluded consumed all_excluded_paths through a process substitution
# with no `$?` a caller could check -- a `.excluded` query that failed
# looked exactly like a manifest with no exclusions at all, and the file it
# was declared to keep out of the backup was staged anyway. A PoC confirmed
# the result: a manifest excluding ~/.config/app/secret, with a jq wrapper
# failing only that ONE query, staged the secret, rc=0, "1 paths in
# staging".
EXH="$(mktemp -d)"; EXR="$EXH/repo"
git init -q "$EXR"; git -C "$EXR" config user.email t@t; git -C "$EXR" config user.name t
mkdir -p "$EXR/x"; printf 'x\n' >"$EXR/x/f"
git -C "$EXR" add -A && git -C "$EXR" commit -qm one
cat >"$EXH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/app"]}],
 "excluded":[{"path":"~/.config/app/secret","reason":"test"}]}
JSON
mkdir -p "$EXH/home/.config/app"
printf 'topsecret\n' >"$EXH/home/.config/app/secret"
printf 'regular\n' >"$EXH/home/.config/app/regular.conf"
mkdir -p "$EXH/stub"
{ printf '#!/bin/bash\n'
  printf 'for a in "$@"; do [[ "$a" == *"(.excluded // [])"* ]] && exit 9; done\n'
  printf 'exec %s "$@"\n' "$(command -v jq)"
} >"$EXH/stub/jq"; chmod +x "$EXH/stub/jq"

it "collect refuses when the exclusion list itself cannot be queried"
HOME="$EXH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$EXH/g.json" \
    OMABACKUP_STATE="$EXH/home/.state" OMABACKUP_REPO="$EXR" \
    PATH="$EXH/stub:$PATH" XDG_RUNTIME_DIR=/nonexistent "$OB" collect >/dev/null 2>&1 \
    && fail "reported success without being able to check the exclusion list" || ok

it "and the excluded file was never staged"
[[ -z "$(find "$EXH/home/.state/staging" -iname secret 2>/dev/null)" ]] \
    && ok || fail "the file the manifest excludes leaked into staging"

# ── a group's own exclude-pattern query failing is refused the same way ─────
# _rsync_excludes fed two separate jq queries into `while read < <(...)`
# process substitutions, neither checked. A group's own `.exclude` patterns
# (not the manifest-wide `.excluded` list above) failing to query used to
# mean rsync ran with no exclude patterns at all, silently copying whatever
# they existed to keep out of the backup.
EPH="$(mktemp -d)"; EPR="$EPH/repo"
git init -q "$EPR"; git -C "$EPR" config user.email t@t; git -C "$EPR" config user.name t
mkdir -p "$EPR/x"; printf 'x\n' >"$EPR/x/f"
git -C "$EPR" add -A && git -C "$EPR" commit -qm one
cat >"$EPH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/app"],
  "exclude":["node_modules/**"]}]}
JSON
mkdir -p "$EPH/home/.config/app/node_modules"
printf 'noise\n' >"$EPH/home/.config/app/node_modules/junk.js"
mkdir -p "$EPH/stub"
{ printf '#!/bin/bash\n'
  printf 'for a in "$@"; do [[ "$a" == *"(.exclude // [])"* ]] && exit 9; done\n'
  printf 'exec %s "$@"\n' "$(command -v jq)"
} >"$EPH/stub/jq"; chmod +x "$EPH/stub/jq"

it "collect refuses when a group's own exclude-pattern query fails"
HOME="$EPH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$EPH/g.json" \
    OMABACKUP_STATE="$EPH/home/.state" OMABACKUP_REPO="$EPR" \
    PATH="$EPH/stub:$PATH" XDG_RUNTIME_DIR=/nonexistent "$OB" collect >/dev/null 2>&1 \
    && fail "reported success without being able to read this group's own exclude patterns" || ok

# ── a full rsync failure aborts collect, but a partial one does not ─────────
# Neither of collect's two rsync calls checked their own status -- `n`
# counted a path as collected regardless. A PoC (an rsync wrapper that
# always exits 1) confirmed the result: collect reported success, staging
# held nothing, and coverage recorded zero files/bytes for a group that
# looked, from the exit code alone, like it had just been backed up. Exit
# 23/24 (rsync's own codes for a partial transfer -- an unreadable
# subdirectory, a source file that vanished mid-walk) are deliberately NOT
# refused here: that is what _staged_size's own later measurement already
# exists to catch and report on its own terms, covered by coverage.test.sh.
RSH="$(mktemp -d)"; RSR="$RSH/repo"
git init -q "$RSR"; git -C "$RSR" config user.email t@t; git -C "$RSR" config user.name t
mkdir -p "$RSR/x"; printf 'x\n' >"$RSR/x/f"
git -C "$RSR" add -A && git -C "$RSR" commit -qm one
cat >"$RSH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/app"]}]}
JSON
mkdir -p "$RSH/home/.config/app"
printf 'x\n' >"$RSH/home/.config/app/f.conf"
mkdir -p "$RSH/stub"
printf '#!/bin/bash\nexit 1\n' >"$RSH/stub/rsync"; chmod +x "$RSH/stub/rsync"

it "collect refuses when rsync fails outright"
HOME="$RSH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$RSH/g.json" \
    OMABACKUP_STATE="$RSH/home/.state" OMABACKUP_REPO="$RSR" \
    PATH="$RSH/stub:$PATH" XDG_RUNTIME_DIR=/nonexistent "$OB" collect >/dev/null 2>&1 \
    && fail "reported success despite rsync failing outright" || ok

it "and nothing was staged for it"
[[ -z "$(find "$RSH/home/.state/staging" -type f 2>/dev/null)" ]] \
    && ok || fail "staging held a file despite the copy having failed"

# ── a generator's own command failing is refused, not staged empty ──────────
# collect_generated ran pacman/systemctl with their status discarded --
# not even fed to a variable, just redirected and forgotten. A PoC (pacman
# replaced with something that always exits 1) confirmed the result:
# collect reported success, and the three package lists were staged EMPTY
# rather than not staged at all. Publishing that is not a missing update --
# it is erasing whatever real package list the repo already held with a
# file that names none.
GEH="$(mktemp -d)"
mkdir -p "$GEH/.config/app"; printf 'x\n' >"$GEH/.config/app/f.txt"
cat >"$GEH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"packages","label":"Packages","mode":"gen","coupled":false,"critical":true,"generator":"packages"}]}
JSON
mkdir -p "$GEH/stub"
printf '#!/bin/bash\nexit 1\n' >"$GEH/stub/pacman"; chmod +x "$GEH/stub/pacman"

it "collect refuses when a generator's own command fails"
PATH="$GEH/stub:$PATH" HOME="$GEH" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$GEH/g.json" \
    OMABACKUP_STATE="$GEH/.state" XDG_RUNTIME_DIR=/nonexistent "$OB" collect >/dev/null 2>&1 \
    && fail "reported success despite pacman failing outright" || ok

it "and no empty package list was staged in its place"
[[ -z "$(find "$GEH/.state/staging" -type f 2>/dev/null)" ]] \
    && ok || fail "an empty generated list was staged despite the generator failing"

# ── a plugin's local capture failing is refused, not counted as collected ───
# _capture_local's own rsync copy was never checked by either of its two
# callers in capture_plugin -- both discarded it via a compound
# `{ _capture_local ...; echo "local"; return; }`, where a bare `return`
# reports the LAST command's status (the echo, always 0), not
# _capture_local's. A PoC (rsync stubbed to always fail) confirmed the
# result: collect reported success for a plugin directory that was never
# actually copied into staging.
PCH="$(mktemp -d)"; PCR="$PCH/repo"
mkdir -p "$PCR/x"
git init -q "$PCR"; git -C "$PCR" config user.email t@t; git -C "$PCR" config user.name t
printf 'x\n' >"$PCR/x/f"
git -C "$PCR" add -A && git -C "$PCR" commit -qm one
cat >"$PCH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"plugins","label":"Plugins","mode":"triple","coupled":false,"critical":false,
  "paths":["~/.config/omarchy/plugins"]}]}
JSON
mkdir -p "$PCH/home/.config/omarchy/plugins/myplugin"
printf 'x\n' >"$PCH/home/.config/omarchy/plugins/myplugin/f.txt"
mkdir -p "$PCH/stub"
printf '#!/bin/bash\nexit 1\n' >"$PCH/stub/rsync"; chmod +x "$PCH/stub/rsync"

it "collect refuses when a plugin's local capture fails to copy"
PATH="$PCH/stub:$PATH" HOME="$PCH/home" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$PCH/g.json" \
    OMABACKUP_STATE="$PCH/home/.state" OMABACKUP_REPO="$PCR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" collect >/dev/null 2>&1 \
    && fail "reported success despite the plugin's own rsync copy failing" || ok

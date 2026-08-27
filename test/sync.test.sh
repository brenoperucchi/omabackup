# Regressions for `omabackup sync` at the CLI level (bin/omabackup cmd_sync).
#
# These exist because publish.test.sh exercised `publish_staging` as a shell
# function and never the command a human actually types. The suite was 40/40
# green while `--commit` could not run at all: the flag parser rejected it, and
# even past that the parser shifted every argument away, so cmd_sync always
# received an empty string. Nothing below calls an internal function -- every
# spec drives the CLI the way the systemd timer will.

OB="$PWD/bin/omabackup"

_sync_env() {  # _sync_env <home> <repo> <groups> <args...>
    local h="$1" r="$2" g="$3"; shift 3
    HOME="$h" OMABACKUP_GROUPS="$g" OMABACKUP_STATE="$h/.state" OMABACKUP_REPO="$r" \
        XDG_RUNTIME_DIR=/nonexistent "$OB" "$@" 2>&1
}

# A destination repo with a base commit: without one, "the tree is clean" and
# "an unrelated change" are both indistinguishable from "everything is new".
_dest_repo() {
    local r="$1"
    git init -q "$r"
    git -C "$r" config user.email t@t
    git -C "$r" config user.name t
    printf 'seed\n' >"$r/README.md"
    git -C "$r" add -A
    git -C "$r" commit -qm base
}

_commits() { git -C "$1" log --oneline 2>/dev/null | wc -l | tr -d ' '; }

# -- --commit has to reach cmd_sync at all ----------------------------------------
SH="$(mktemp -d)"; SR="$SH/repo"; SG="$SH/g.json"
mkdir -p "$SH/.config/app"
printf 'x\n' >"$SH/.config/app/f.txt"
_dest_repo "$SR"
cat >"$SG" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,
  "paths":["~/.config/app"]}]}
JSON
OUT="$(_sync_env "$SH" "$SR" "$SG" sync --commit)"

it "sync accepts --commit instead of dying on an unknown flag"
assert_not_contains "$OUT" "unknown flag"

it "sync --commit commits what publish wrote"
assert_contains "$(git -C "$SR" log --oneline 2>/dev/null)" "omabackup: sync"

it "the commit actually carries the collected file"
assert_contains "$(git -C "$SR" show --name-only --format= HEAD 2>/dev/null)" "configs/app/f.txt"

# -- a second run with nothing to say must not manufacture a commit ---------------
_sync_env "$SH" "$SR" "$SG" sync --commit >/dev/null

it "a second sync --commit on an unchanged tree creates no empty commit"
assert_eq "$(_commits "$SR")" "2"

# -- without --commit, publish still writes but nothing is committed --------------
SH2="$(mktemp -d)"; SR2="$SH2/repo"; SG2="$SH2/g.json"
mkdir -p "$SH2/.config/app"
printf 'x\n' >"$SH2/.config/app/f.txt"
_dest_repo "$SR2"
cp "$SG" "$SG2"
_sync_env "$SH2" "$SR2" "$SG2" sync >/dev/null

it "sync without --commit leaves the change in the tree for review"
assert_contains "$(git -C "$SR2" status --porcelain)" "configs/"

it "sync without --commit creates no commit"
assert_eq "$(_commits "$SR2")" "1"

# -- a commit must carry the backup, not whatever else was lying around -----------
# `git add -A` in the destination repo sweeps up edits a human left mid-review.
SH3="$(mktemp -d)"; SR3="$SH3/repo"; SG3="$SH3/g.json"
mkdir -p "$SH3/.config/app"
printf 'x\n' >"$SH3/.config/app/f.txt"
_dest_repo "$SR3"
printf 'mine\n' >"$SR3/notes.txt"
git -C "$SR3" add -A && git -C "$SR3" commit -qm notes
printf 'half-finished edit\n' >"$SR3/notes.txt"
cp "$SG" "$SG3"
_sync_env "$SH3" "$SR3" "$SG3" sync --commit >/dev/null

it "sync --commit keeps an unrelated preexisting edit out of the commit"
assert_not_contains "$(git -C "$SR3" show --name-only --format= HEAD 2>/dev/null)" "notes.txt"

it "and leaves that edit untouched in the working tree"
assert_contains "$(git -C "$SR3" status --porcelain)" "notes.txt"

# -- and the same when the user already staged it ---------------------------------
# Scoping `git add` is not enough: `git commit` with no pathspec commits the
# whole index, so anything the user had already `git add`ed rode along under the
# tool's own commit message. The first version of the spec above only edited the
# working tree, which is exactly why this survived -- a green spec that did not
# test the real thing.
SH3b="$(mktemp -d)"; SR3b="$SH3b/repo"; SG3b="$SH3b/g.json"
mkdir -p "$SH3b/.config/app"
printf 'x\n' >"$SH3b/.config/app/f.txt"
_dest_repo "$SR3b"
printf 'mine\n' >"$SR3b/notes.txt"
git -C "$SR3b" add -A && git -C "$SR3b" commit -qm notes
printf 'half-finished edit\n' >"$SR3b/notes.txt"
git -C "$SR3b" add notes.txt          # the user staged their own work
cp "$SG" "$SG3b"
_sync_env "$SH3b" "$SR3b" "$SG3b" sync --commit >/dev/null

it "sync --commit keeps an unrelated STAGED change out of the commit"
assert_not_contains "$(git -C "$SR3b" show --name-only --format= HEAD 2>/dev/null)" "notes.txt"

it "and leaves it staged, neither committed nor reverted"
assert_contains "$(git -C "$SR3b" diff --cached --name-only 2>/dev/null)" "notes.txt"

it "while still committing what the backup published"
assert_contains "$(git -C "$SR3b" show --name-only --format= HEAD 2>/dev/null)" "configs/app/f.txt"

# -- verify is the product, not a commit-time formality ---------------------------
# A link-mode group whose paths stopped being symlinks is the August incident in
# miniature: the repo silently stopped receiving. A sync that does not say so is
# the failure this tool exists to prevent, with or without --commit.
SH4="$(mktemp -d)"; SR4="$SH4/repo"; SG4="$SH4/g.json"
_dest_repo "$SR4"
printf 'real\n' >"$SR4/bashrc"
ln -s "$SR4/bashrc" "$SH4/.bashrc"
printf 'no longer linked\n' >"$SH4/.inputrc"
cat >"$SG4" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"shellrc","label":"User shell","mode":"link","coupled":false,"critical":true,
  "paths":["~/.bashrc","~/.inputrc"]}]}
JSON
OUT4="$(_sync_env "$SH4" "$SR4" "$SG4" sync)"

it "a plain sync runs verify and surfaces a coverage failure"
assert_contains "$OUT4" "stopped being links"

OUT5="$(_sync_env "$SH4" "$SR4" "$SG4" sync --commit)"

it "sync --commit refuses to commit while verify fails"
assert_eq "$(_commits "$SR4")" "1"

it "and says why instead of failing silently"
assert_contains "$OUT5" "not committing"

# -- the scripts group has to survive the trip staging -> repo --------------------
# collect stages ~/.local/bin correctly, but map_to_repo refused the prefix with
# a comment claiming collect had already written it into the repo. It had not:
# collect only ever writes into staging, so the whole group was dropped in
# silence -- an incomplete backup that reported success.
SH6="$(mktemp -d)"; SR6="$SH6/repo"; SG6="$SH6/g.json"
_dest_repo "$SR6"
mkdir -p "$SR6/scripts/local-bin" "$SH6/.local/bin"
printf 'old\n' >"$SR6/scripts/local-bin/my-script"
git -C "$SR6" add -A && git -C "$SR6" commit -qm scripts
printf 'new version\n' >"$SH6/.local/bin/my-script"
printf 'shim\n' >"$SH6/.local/bin/npm"
cat >"$SG6" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"scripts","label":"Personal scripts","mode":"copy","coupled":false,"critical":false,
  "paths":[{"live":"~/.local/bin","trackedRepoPath":"scripts/local-bin"}]}]}
JSON
_sync_env "$SH6" "$SR6" "$SG6" sync >/dev/null

it "a tracked-only script reaches the repo"
assert_contains "$(cat "$SR6/scripts/local-bin/my-script" 2>/dev/null)" "new version"

it "an untracked shim in the same directory does not"
[[ ! -e "$SR6/scripts/local-bin/npm" ]] && ok || fail "an untracked shim was published"

# -- a destination repo that ignores what we publish ------------------------------
# `git add -A` skipped ignored paths in silence; a scoped `git add` refuses the
# whole batch over one of them. Neither is right: the file was published into a
# place it can never be committed from, so it is a coverage hole, and the way
# omabackup found this was by backing up ~/.config/opencode/.gitignore, whose
# rules then applied inside the dotfiles repo and ignored its own siblings.
SH8="$(mktemp -d)"; SR8="$SH8/repo"; SG8="$SH8/g.json"
mkdir -p "$SH8/.config/app"
printf 'x\n' >"$SH8/.config/app/f.txt"
printf 'noise\n' >"$SH8/.config/app/ignored.txt"
_dest_repo "$SR8"
printf 'ignored.txt\n' >"$SR8/.gitignore"
git -C "$SR8" add -A && git -C "$SR8" commit -qm ignore
cp "$SG" "$SG8"
OUT8="$(_sync_env "$SH8" "$SR8" "$SG8" sync --commit)"

it "one ignored file does not abort the whole commit"
assert_contains "$(git -C "$SR8" log --oneline 2>/dev/null)" "omabackup: sync"

it "the rest of the group is committed normally"
assert_contains "$(git -C "$SR8" show --name-only --format= HEAD 2>/dev/null)" "configs/app/f.txt"

it "the ignored file is left out of the commit, not forced in"
assert_not_contains "$(git -C "$SR8" show --name-only --format= HEAD 2>/dev/null)" "ignored.txt"

it "and it is reported as a coverage hole rather than swallowed"
assert_contains "$OUT8" "the repo ignores"

# -- a file matching .gitignore but already tracked is still committed -------------
# Ignore rules do not apply to tracked files, so treating "matches .gitignore"
# as "cannot be added" would silently stop backing up a file the repo does track.
SH9="$(mktemp -d)"; SR9="$SH9/repo"; SG9="$SH9/g.json"
mkdir -p "$SH9/.config/app"
printf 'updated\n' >"$SH9/.config/app/f.txt"
_dest_repo "$SR9"
mkdir -p "$SR9/configs/app"
printf 'old\n' >"$SR9/configs/app/f.txt"
printf 'f.txt\n' >"$SR9/.gitignore"
git -C "$SR9" add -f configs/app/f.txt .gitignore && git -C "$SR9" commit -qm tracked
cp "$SG" "$SG9"
_sync_env "$SH9" "$SR9" "$SG9" sync --commit >/dev/null

it "a tracked file matching .gitignore is still committed"
assert_contains "$(git -C "$SR9" show HEAD:configs/app/f.txt 2>/dev/null)" "updated"

# -- a git that refuses must not be reported as a success -------------------------
# The script runs under `set -uo pipefail` without -e: an unchecked `git commit`
# that fails still falls through to the success message.
SH7="$(mktemp -d)"; SR7="$SH7/repo"; SG7="$SH7/g.json"
mkdir -p "$SH7/.config/app"
printf 'x\n' >"$SH7/.config/app/f.txt"
_dest_repo "$SR7"
printf '#!/bin/sh\nexit 1\n' >"$SR7/.git/hooks/pre-commit"
chmod +x "$SR7/.git/hooks/pre-commit"
cp "$SG" "$SG7"
OUT7="$(_sync_env "$SH7" "$SR7" "$SG7" sync --commit)"

it "a git commit that fails is not announced as committed"
assert_not_contains "$OUT7" "committed"

it "and leaves no commit behind"
assert_eq "$(_commits "$SR7")" "1"

# -- a git that fails mid-flow must not read as "nothing changed" -----------------
# `dirty="$(git status ...)"` never checked its exit status, so any failure --
# ARG_MAX on a long pathspec, a broken index, a repo yanked mid-run -- produced
# empty output, which is indistinguishable from a clean tree. The tool then
# printed "up to date" and exited 0: a backup reporting success for a git it
# could not even talk to.
REAL_GIT="$(command -v git)"
_faking_git() {  # _faking_git <dir> <subcommand-to-fail>
    mkdir -p "$1"
    { printf '#!/bin/bash\n'
      printf 'for a in "$@"; do [[ "$a" == %q ]] && exit 128; done\n' "$2"
      printf 'exec %q "$@"\n' "$REAL_GIT"
    } >"$1/git"
    chmod +x "$1/git"
}

SHA="$(mktemp -d)"; SRA="$SHA/repo"; SGA="$SHA/g.json"
mkdir -p "$SHA/.config/app"
printf 'x\n' >"$SHA/.config/app/f.txt"
_dest_repo "$SRA"
cp "$SG" "$SGA"
_faking_git "$SHA/fakebin" status
OUTA="$(PATH="$SHA/fakebin:$PATH" _sync_env "$SHA" "$SRA" "$SGA" sync --commit)"
RCA=$?

it "a git status that fails is not reported as up to date"
assert_not_contains "$OUTA" "up to date"

it "and the sync fails loudly instead of exiting clean"
[[ $RCA -ne 0 ]] && ok || fail "sync exited 0 despite git status failing"

# -- publish that cannot write must not report success ----------------------------
# _publish_file's failures were dropped on the floor: the file was simply left
# out of the written list and publish_staging still ended on its success printf.
SHB="$(mktemp -d)"; SRB="$SHB/repo"; SGB="$SHB/g.json"
mkdir -p "$SHB/.config/app"
printf 'x\n' >"$SHB/.config/app/f.txt"
_dest_repo "$SRB"
printf 'not a directory\n' >"$SRB/configs"   # publish needs configs/ to be a dir
cp "$SG" "$SGB"
OUTB="$(_sync_env "$SHB" "$SRB" "$SGB" sync --commit)"
RCB=$?

it "a publish that cannot write its destination fails the sync"
[[ $RCB -ne 0 ]] && ok || fail "sync exited 0 despite publish being unable to write"

it "and says so rather than announcing a commit"
assert_not_contains "$OUTB" "committed"

# -- a flag that takes a value must not hang when the value is missing ------------
# `--groups` did `shift 2` unconditionally. With one argument left the shift
# fails, $# never reaches zero, and `while (($#))` spins forever.
SHC="$(mktemp -d)"; SGC="$SHC/g.json"
cp "$SG" "$SGC"
timeout 5 env HOME="$SHC" OMABACKUP_GROUPS="$SGC" OMABACKUP_STATE="$SHC/.state" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" verify --groups >/dev/null 2>&1
RCC=$?

it "--groups with no value fails instead of hanging forever"
[[ $RCC -ne 124 ]] && ok || fail "the argument loop spun forever (timed out)"

OUTD="$(timeout 5 env HOME="$SHC" OMABACKUP_GROUPS="$SGC" OMABACKUP_STATE="$SHC/.state" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" verify --groups 2>&1)"

it "and says what was missing"
assert_contains "$OUTD" "--groups"

OUTE="$(timeout 5 env HOME="$SHC" OMABACKUP_GROUPS="$SGC" OMABACKUP_STATE="$SHC/.state" \
    OMABACKUP_REPO="$SHC" XDG_RUNTIME_DIR=/nonexistent "$OB" sync --groups --commit 2>&1)"

it "a flag is never swallowed as another flag's value"
assert_contains "$OUTE" "--groups"

# ── a trailing slash on a declared live path no longer drops the whole group ─
# _expand did nothing but substitute a leading ~. A declared live path with a
# trailing slash ("~/.local/bin/" instead of "~/.local/bin") built a
# trackedRepoPath prefix ending in "/", and map_to_repo's own prefix match
# (rel == "$prefix/"*) became "rel == .local/bin//"* -- two slashes, which no
# real file's single-slash path ever satisfies. A PoC confirmed the result:
# sync --commit returned success, published 0 files for that group, and the
# repo stayed at whatever it held before -- silently, no warning, no error.
TSH="$(mktemp -d)"; TSR="$TSH/repo"; _dest_repo "$TSR"
mkdir -p "$TSR/scripts/local-bin"
printf 'old\n' >"$TSR/scripts/local-bin/tool"
git -C "$TSR" add -A && git -C "$TSR" -c user.email=t@t -c user.name=t commit -qm base
TSG="$TSH/g.json"
cat >"$TSG" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"scripts","label":"Scripts","mode":"copy","coupled":false,"critical":false,
  "paths":[{"live":"~/.local/bin/","trackedRepoPath":"scripts/local-bin"}]}]}
JSON
mkdir -p "$TSH/.local/bin"
printf 'new\n' >"$TSH/.local/bin/tool"

it "sync --commit publishes through a trailing-slash declared live path"
_sync_env "$TSH" "$TSR" "$TSG" sync --commit >/dev/null
assert_eq "$(cat "$TSR/scripts/local-bin/tool" 2>/dev/null)" "new"

# ── the same holds through a DOUBLE trailing slash, not just one ────────────
# `${e%/}` in _expand strips exactly one trailing slash -- a declared live
# path with TWO ("~/.local/bin//") built a trackedRepoPath prefix STILL
# ending in "/" (one of the two survived), reproducing the identical
# silently-dropped-group bug through the slash ${e%/} left behind. _expand
# now loops until every trailing slash is gone, not just the first.
TS2H="$(mktemp -d)"; TS2R="$TS2H/repo"; _dest_repo "$TS2R"
mkdir -p "$TS2R/scripts/local-bin"
printf 'old\n' >"$TS2R/scripts/local-bin/tool"
git -C "$TS2R" add -A && git -C "$TS2R" -c user.email=t@t -c user.name=t commit -qm base
TS2G="$TS2H/g.json"
cat >"$TS2G" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"scripts","label":"Scripts","mode":"copy","coupled":false,"critical":false,
  "paths":[{"live":"~/.local/bin//","trackedRepoPath":"scripts/local-bin"}]}]}
JSON
mkdir -p "$TS2H/.local/bin"
printf 'new\n' >"$TS2H/.local/bin/tool"

it "sync --commit publishes through a double-trailing-slash declared live path"
_sync_env "$TS2H" "$TS2R" "$TS2G" sync --commit >/dev/null
assert_eq "$(cat "$TS2R/scripts/local-bin/tool" 2>/dev/null)" "new"

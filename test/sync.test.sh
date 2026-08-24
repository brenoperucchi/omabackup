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

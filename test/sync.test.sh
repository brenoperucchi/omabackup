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
# The failure is injected with a git shim, not a pre-commit hook: the backup's
# own commit deliberately runs no hooks (review omabackup-69), so a hook can no
# longer make it fail -- but a git that refuses still must not read as success.
mkdir -p "$SH7/stub"
cat >"$SH7/stub/git" <<SHIM
#!/bin/bash
for a in "\$@"; do [[ "\$a" == commit || "\$a" == commit-tree ]] && exit 1; done
exec "$(command -v git)" "\$@"
SHIM
chmod +x "$SH7/stub/git"
cp "$SG" "$SG7"
OUT7="$(PATH="$SH7/stub:$PATH" _sync_env "$SH7" "$SR7" "$SG7" sync --commit)"

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

# ── a secret in staging is refused before it is published ────────────────────
# The deny-list ran in exactly two places: over the bundle, and over every ref
# of the repository right before `git push`. Nothing looked at staging, and
# nothing looked at what `sync --commit` was about to publish and commit. The
# fifteen-minute timer runs `sync --commit` unattended, so a private key that
# lands in a collected directory was published into the dotfiles worktree and
# committed to local history on the next tick, and the hourly push then refused
# it with advice to rewrite that history. The scan now runs over staging before
# publish, with the same deny-list, so the key never enters the worktree. It is
# the same patterns push applies, so nothing push would have accepted is
# refused here; the refusal just comes earlier, while it is still cheap.
_scan_home() {  # _scan_home <home> [leaked content]
    local h="$1"
    mkdir -p "$h/.config/app"
    printf 'ordinary config\n' >"$h/.config/app/fine.conf"
    [[ -n "${2:-}" ]] && printf '%s\n' "$2" >"$h/.config/app/leaked.conf"
    cat >"$h/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,
  "paths":["~/.config/app"]}]}
JSON
    _dest_repo "$h/repo"
}

SC="$(mktemp -d)"
_scan_home "$SC" "-----BEGIN OPENSSH PRIVATE KEY-----"
SCOUT="$(_sync_env "$SC" "$SC/repo" "$SC/g.json" sync --commit)"; SCRC=$?

it "sync refuses to publish when the deny-list matches a staged file"
(( SCRC != 0 )) && ok || fail "sync exited 0 with a private key in staging"

it "and no commit was created"
assert_eq "$(_commits "$SC/repo")" "1"

it "and the file never reached the backup worktree"
[[ ! -e "$SC/repo/configs/app/leaked.conf" && ! -e "$SC/repo/configs/app/fine.conf" ]] \
    && ok || fail "publish wrote into the worktree before the scan refused"

it "and staging was cleared so a later sync cannot republish it"
[[ -z "$(find "$SC/.state/staging" -mindepth 1 -print -quit 2>/dev/null)" ]] \
    && ok || fail "the refused staging was left in place"

it "the refusal names the pattern and the file, so the user knows what to move"
assert_contains "$SCOUT" "private-key-block"$'\t'".config/app/leaked.conf"

# A scan that could not run is not a clean scan. grep is what scan_files
# drives; a grep that fails outright must refuse the sync, not wave it on.
SE="$(mktemp -d)"
_scan_home "$SE"
mkdir -p "$SE/stub"; printf '#!/bin/bash\nexit 2\n' >"$SE/stub/grep"; chmod +x "$SE/stub/grep"
SEOUT="$(PATH="$SE/stub:$PATH" _sync_env "$SE" "$SE/repo" "$SE/g.json" sync --commit)"; SERC=$?

it "a staging scan that cannot run refuses the sync rather than calling it clean"
(( SERC != 0 )) && ok || fail "sync exited 0 although the scanner could not run"

it "and publishes nothing from the unscanned staging"
assert_eq "$(_commits "$SE/repo")" "1"

# Control: a staging with nothing to hide is published and committed as before.
SK="$(mktemp -d)"
_scan_home "$SK"
_sync_env "$SK" "$SK/repo" "$SK/g.json" sync --commit >/dev/null

it "a clean staging still publishes and commits"
assert_eq "$(_commits "$SK/repo")" "2"

# -- review round omabackup-73 ------------------------------------------------------
_r73tok="gh""p_$(printf 'E%.0s' {1..36})"

# The refusal prints where the hit is, never the line: the timer's output is
# the journal, and it would repeat the secret there every fifteen minutes.
R73A="$(mktemp -d)"; _scan_home "$R73A" "token = $_r73tok"
R73A_OUT="$(_sync_env "$R73A" "$R73A/repo" "$R73A/g.json" sync)"; R73A_RC=$?
it "the staging refusal never prints the matched line"
if (( R73A_RC != 0 )); then assert_not_contains "$R73A_OUT" "$_r73tok"
else fail "sync did not refuse a token in staging"; fi

it "and says how to get out of it"
assert_contains "$R73A_OUT" "exclude"

# A file NAME can be the secret; it is not printed either.
R73B="$(mktemp -d)"; _scan_home "$R73B"
printf 'token = %s\n' "$_r73tok" >"$R73B/.config/app/$_r73tok.conf"
R73B_OUT="$(_sync_env "$R73B" "$R73B/repo" "$R73B/g.json" sync)"; R73B_RC=$?
it "a file whose name holds a token is refused without printing the name"
if (( R73B_RC != 0 )); then assert_not_contains "$R73B_OUT" "$_r73tok"
else fail "sync did not refuse"; fi

# An unreadable deny-list exits through its own validator; staging must still
# be cleared, and the message is about sync, not push.
R73C="$(mktemp -d)"; _scan_home "$R73C"
R73C_OUT="$(OMABACKUP_SECRETS_DENY="$R73C/missing.json" _sync_env "$R73C" "$R73C/repo" "$R73C/g.json" sync)"; R73C_RC=$?
it "a missing deny-list refuses the sync"
(( R73C_RC != 0 )) && ok || fail "sync ran with no deny-list"

it "and clears the unscanned staging"
[[ -z "$(find "$R73C/.state/staging" -mindepth 1 -print -quit 2>/dev/null)" ]] \
    && ok || fail "unscanned staging was left on disk"

it "and does not speak of a push"
assert_not_contains "$R73C_OUT" "refusing to push"

# -- review round omabackup-75: symlinks reach git as a name and a target text ---
R75="$(mktemp -d)"; _scan_home "$R75"
ln -s fine.conf "$R75/.config/app/$_r73tok"
ln -s "$_r73tok" "$R75/.config/app/pointer"
R75_OUT="$(_sync_env "$R75" "$R75/repo" "$R75/g.json" sync --commit)"; R75_RC=$?
it "a symlink with a token in its name or target is refused before publish"
if (( R75_RC != 0 )); then assert_not_contains "$R75_OUT" "$_r73tok"
else fail "a token in a symlink reached the worktree"; fi

it "and nothing was published"
assert_eq "$(_commits "$R75/repo")" "1"

# -- a secret is refused BEFORE it becomes history ----------------------------------
# The deny-list used to run only in `push`, and push runs after sync has already
# committed. So a token that reached a collected file was never refused: it was
# committed, and from then on the history-wide scan blocked every push until
# someone rewrote the repository. The scan now runs over exactly what this
# commit would add, before `git add` makes it permanent, and a hit refuses the
# commit instead of poisoning the history.
#
# The token is assembled at runtime so this file never holds one in the clear.
_tok="gh""p_$(printf 'A%.0s' {1..36})"

_sec_env() {  # _sec_env <dir> -- a home with one collected app file and a repo
    mkdir -p "$1/.config/app"
    printf 'x\n' >"$1/.config/app/f.txt"
    _dest_repo "$1/repo"
    cat >"$1/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,
  "paths":["~/.config/app"]}]}
JSON
}

SC1="$(mktemp -d)"; _sec_env "$SC1"
_sync_env "$SC1" "$SC1/repo" "$SC1/g.json" sync --commit >/dev/null
printf 'token = %s\n' "$_tok" >"$SC1/.config/app/creds.txt"
SC1_OUT="$(_sync_env "$SC1" "$SC1/repo" "$SC1/g.json" sync --commit)"; SC1_RC=$?

it "sync --commit refuses when a collected file carries a known credential"
(( SC1_RC != 0 )) && ok || fail "sync --commit exited 0 with a GitHub token in what it was about to commit"

it "and creates no commit, so the history stays clean"
assert_eq "$(_commits "$SC1/repo")" "2"

it "and leaves nothing staged for a later commit to sweep up"
assert_eq "$(git -C "$SC1/repo" diff --cached --name-only)" ""

# The staging scan (#3) refuses this one before publish, under the staging
# path; the pre-commit gate names the repo path. Either names the file.
it "and names the rule and the file so the user can act on it"
assert_contains "$SC1_OUT" "github-token"
assert_contains "$SC1_OUT" "app/creds.txt"

# The scan covers what THIS commit adds, not the whole tree. A token already in
# history has already blocked push; blocking sync as well would stop the local
# backup altogether without protecting anything more.
SC2="$(mktemp -d)"; _sec_env "$SC2"
mkdir -p "$SC2/repo/configs/old"
printf 'token = %s\n' "$_tok" >"$SC2/repo/configs/old/leaked.txt"
git -C "$SC2/repo" add -A && git -C "$SC2/repo" commit -qm "old leak"
_sync_env "$SC2" "$SC2/repo" "$SC2/g.json" sync --commit >/dev/null

it "a token already in history does not block committing an unrelated clean change"
assert_contains "$(git -C "$SC2/repo" log -1 --format=%s)" "omabackup: sync"

# Nor does a file this run did not write. `commit -- written[]` never takes it,
# so it is not ours to refuse.
SC3="$(mktemp -d)"; _sec_env "$SC3"
printf 'token = %s\n' "$_tok" >"$SC3/repo/scratch.txt"
_sync_env "$SC3" "$SC3/repo" "$SC3/g.json" sync --commit >/dev/null

it "an unrelated file in the repo holding a token does not block the sync"
assert_contains "$(git -C "$SC3/repo" log -1 --format=%s)" "omabackup: sync"

it "and that file is still left out of the commit"
assert_not_contains "$(git -C "$SC3/repo" show --name-only --format= HEAD)" "scratch.txt"

# A scan that cannot run is not a clean scan. An unreadable deny-list has to
# refuse the commit, the same way push already refuses.
SC4="$(mktemp -d)"; _sec_env "$SC4"
SC4_OUT="$(OMABACKUP_SECRETS_DENY="$SC4/missing.json" _sync_env "$SC4" "$SC4/repo" "$SC4/g.json" sync --commit)"; SC4_RC=$?

it "sync --commit refuses when the secret scan itself cannot run"
(( SC4_RC != 0 )) && ok || fail "committed without a deny-list to scan against"

it "and creates no commit in that case either"
assert_eq "$(_commits "$SC4/repo")" "1"

# Without --commit nothing becomes history, and this gate used to let publish
# write the file for review. The staging scan (#3) now refuses before publish
# in both modes, so the token never reaches the worktree at all.
SC5="$(mktemp -d)"; _sec_env "$SC5"
printf 'token = %s\n' "$_tok" >"$SC5/.config/app/creds.txt"
_sync_env "$SC5" "$SC5/repo" "$SC5/g.json" sync >/dev/null; SC5_RC=$?

it "sync without --commit refuses a token too, before publish"
(( SC5_RC != 0 )) && ok || fail "sync without --commit published a token"

it "and the token never reached the worktree"
[[ ! -e "$SC5/repo/configs/app/creds.txt" ]] && ok || fail "creds.txt was published"

# -- the scan reads the object git records, not the file in the worktree ----------
# Review round omabackup-68: the first version grepped the worktree while
# `git commit -- paths` recorded whatever the worktree held a moment later.
# The two diverge in ways that matter, each pinned below.
_REALGIT="$(command -v git)"

# Omarchy keeps ~/.config/nvim/lua/plugins/theme.lua as a RELATIVE symlink into
# ~/.local/state. Published into the repo it dangles, and grep given a dangling
# link on its command line exits 2 -- so the first sync of every fresh install
# was refused forever, with a message naming no file. git records the link
# text, which holds no secret.
SY1="$(mktemp -d)"; _sec_env "$SY1"
mkdir -p "$SY1/.local/state/omarchy/theme" "$SY1/.config/app/lua"
printf 'return {}\n' >"$SY1/.local/state/omarchy/theme/neovim.lua"
ln -s ../../../.local/state/omarchy/theme/neovim.lua "$SY1/.config/app/lua/theme.lua"
_sync_env "$SY1" "$SY1/repo" "$SY1/g.json" sync --commit >/dev/null; SY1_RC=$?

it "a relative symlink that dangles once published does not block the commit"
(( SY1_RC == 0 )) && ok || fail "sync --commit refused a harmless Omarchy-style theme link"

it "and the link itself is committed"
assert_contains "$(git -C "$SY1/repo" show --name-only --format= HEAD)" "configs/app/lua/theme.lua"

SY2="$(mktemp -d)"; _sec_env "$SY2"
ln -s "$SY2/nowhere/at/all" "$SY2/.config/app/gone"
_sync_env "$SY2" "$SY2/repo" "$SY2/g.json" sync --commit >/dev/null; SY2_RC=$?

it "a dangling symlink does not block the commit"
(( SY2_RC == 0 )) && ok || fail "sync --commit refused a dangling symlink"

# A link to a file holding a token: git stores the path of the target, not the
# target, so there is nothing secret in what is committed.
SY3="$(mktemp -d)"; _sec_env "$SY3"
printf 'token = %s\n' "$_tok" >"$SY3/outside.txt"
ln -s "$SY3/outside.txt" "$SY3/.config/app/link"
SY3_OUT="$(_sync_env "$SY3" "$SY3/repo" "$SY3/g.json" sync --commit)"; SY3_RC=$?

it "a symlink to a file holding a token commits, because the blob is the link text"
(( SY3_RC == 0 )) && ok || fail "refused over content the commit would not carry"

it "and the target's content is never printed"
assert_not_contains "$SY3_OUT" "$_tok"

# What is committed is what was scanned. A shim appends a token to a collected
# file at the moment git is asked to commit: `commit -- paths` re-read the
# worktree and recorded the token unscanned.
SY4="$(mktemp -d)"; _sec_env "$SY4"; mkdir -p "$SY4/stub"
cat >"$SY4/stub/git" <<SHIM
#!/bin/bash
for a in "\$@"; do
    if [[ "\$a" == commit ]]; then
        printf 'token = %s\n' "$_tok" >>"$SY4/repo/configs/app/f.txt"; break
    fi
done
exec "$_REALGIT" "\$@"
SHIM
chmod +x "$SY4/stub/git"
PATH="$SY4/stub:$PATH" _sync_env "$SY4" "$SY4/repo" "$SY4/g.json" sync --commit >/dev/null

it "a write that lands between the scan and the commit never reaches history"
assert_not_contains "$(git -C "$SY4/repo" log -p --all 2>/dev/null)" "$_tok"

# If the list of files to scan cannot be produced, nothing was scanned -- that is
# not "nothing to scan".
SY5="$(mktemp -d)"; _sec_env "$SY5"; mkdir -p "$SY5/stub"
cat >"$SY5/stub/git" <<SHIM
#!/bin/bash
nm=0; df=0
# diff or diff-tree: the change list now comes from diff-tree on the written tree.
for a in "\$@"; do [[ "\$a" == --name-only ]] && nm=1; [[ "\$a" == diff || "\$a" == diff-tree ]] && df=1; done
(( nm && df )) && exit 128
exec "$_REALGIT" "\$@"
SHIM
chmod +x "$SY5/stub/git"
PATH="$SY5/stub:$PATH" _sync_env "$SY5" "$SY5/repo" "$SY5/g.json" sync --commit >/dev/null; SY5_RC=$?

it "sync --commit refuses when it cannot list what the commit would change"
(( SY5_RC != 0 )) && ok || fail "an unreadable change list was taken as nothing to scan"

it "and creates no commit"
assert_eq "$(_commits "$SY5/repo")" "1"

# The artefact scan skips repo.bundle because it is a packfile already scanned
# as objects. A collected file that happens to share the name is neither.
SY6="$(mktemp -d)"; _sec_env "$SY6"
printf 'token = %s\n' "$_tok" >"$SY6/.config/app/repo.bundle"
_sync_env "$SY6" "$SY6/repo" "$SY6/g.json" sync --commit >/dev/null; SY6_RC=$?

it "a collected file named repo.bundle is scanned like any other"
(( SY6_RC != 0 )) && ok || fail "a token in a file named repo.bundle was committed"

# A clean filter (git-crypt works this way) changes what is stored. This gate
# judges the stored blob, and alone it let a token the filter removes through.
# The staging scan (#3) reads the plaintext before publish and refuses it
# anyway: decided for 0.4.8 to refuse and document, the user excludes the file
# or adds an exception.
SY7="$(mktemp -d)"; _sec_env "$SY7"
git -C "$SY7/repo" config filter.hide.clean "sed 's/gh[p]_[A-Za-z0-9]*/REDACTED/'"
git -C "$SY7/repo" config filter.hide.smudge cat
printf 'configs/app/creds.txt filter=hide\n' >"$SY7/repo/.git/info/attributes"
printf 'token = %s\n' "$_tok" >"$SY7/.config/app/creds.txt"
_sync_env "$SY7" "$SY7/repo" "$SY7/g.json" sync --commit >/dev/null; SY7_RC=$?

it "a token a clean filter would remove is still refused before publish"
(( SY7_RC != 0 )) && ok || fail "a plaintext token behind a clean filter was published"

it "and nothing holds it, stored or published"
assert_not_contains "$(git -C "$SY7/repo" log -p --all 2>/dev/null)" "$_tok"
[[ ! -e "$SY7/repo/configs/app/creds.txt" ]] && ok || fail "creds.txt was published"

# The other way round only this gate can see: staging is clean and the clean
# filter puts the token into the stored blob. The refusal names the repo path
# and the line, never the content.
SYI="$(mktemp -d)"; _sec_env "$SYI"
git -C "$SYI/repo" config filter.leak.clean "sed 's/PLACEHOLDER/$_tok/'"
git -C "$SYI/repo" config filter.leak.smudge cat
printf 'configs/app/creds.txt filter=leak\n' >"$SYI/repo/.git/info/attributes"
printf 'token = PLACEHOLDER\n' >"$SYI/.config/app/creds.txt"
SYI_OUT="$(_sync_env "$SYI" "$SYI/repo" "$SYI/g.json" sync --commit)"; SYI_RC=$?

it "a token a clean filter adds is refused before the commit"
(( SYI_RC != 0 )) && ok || fail "the stored blob carried a token and was committed"

it "and the history stays clean"
assert_not_contains "$(git -C "$SYI/repo" log -p --all 2>/dev/null)" "$_tok"

it "and the refusal names the repo path and the line, not the content"
assert_contains "$SYI_OUT" "configs/app/creds.txt, line 1"
assert_not_contains "$SYI_OUT" "$_tok"

# The refusal goes to the systemd journal when the timer runs it. It names the
# rule, the file and the line -- never the line's content.
SY8="$(mktemp -d)"; _sec_env "$SY8"
printf 'token = %s\n' "$_tok" >"$SY8/.config/app/creds.txt"
SY8_OUT="$(_sync_env "$SY8" "$SY8/repo" "$SY8/g.json" sync --commit)"

it "the refusal never prints the credential itself"
assert_not_contains "$SY8_OUT" "$_tok"

# The staging scan (#3) refuses first, as "<staging path>:<line>"; the
# pre-commit form "<repo path>, line N" is covered by the clean-filter case.
it "but still points at the file and the line"
assert_contains "$SY8_OUT" "app/creds.txt:1"

# A refusal must not touch what the user had staged by hand, on the same path
# or on another one.
SY9="$(mktemp -d)"; _sec_env "$SY9"
_sync_env "$SY9" "$SY9/repo" "$SY9/g.json" sync --commit >/dev/null
printf 'mine\n' >"$SY9/repo/notes.txt"; git -C "$SY9/repo" add notes.txt
printf 'hand-staged\n' >"$SY9/repo/configs/app/f.txt"; git -C "$SY9/repo" add configs/app/f.txt
SY9_BEFORE="$(git -C "$SY9/repo" ls-files -s -- notes.txt configs/app/f.txt)"
printf 'token = %s\n' "$_tok" >"$SY9/.config/app/f.txt"
_sync_env "$SY9" "$SY9/repo" "$SY9/g.json" sync --commit >/dev/null

it "a refusal leaves the user's own staging exactly as it was"
assert_eq "$(git -C "$SY9/repo" ls-files -s -- notes.txt configs/app/f.txt)" "$SY9_BEFORE"

# -- review round omabackup-69: the candidate had to be read, not grepped ---------
# `git grep --cached` still interpreted the blob through the user's settings and
# its own rules. Each case below read something other than the bytes committed.

# A hook runs after the scan with GIT_INDEX_FILE pointing at the candidate, and
# git re-reads the index after pre-commit on purpose. The backup's own commit
# runs no hooks.
SZ1="$(mktemp -d)"; _sec_env "$SZ1"
_sync_env "$SZ1" "$SZ1/repo" "$SZ1/g.json" sync --commit >/dev/null
cat >"$SZ1/repo/.git/hooks/pre-commit" <<HOOK
#!/bin/bash
printf 'token = %s\n' "$_tok" >>configs/app/f.txt
git add configs/app/f.txt
HOOK
cat >"$SZ1/repo/.git/hooks/prepare-commit-msg" <<HOOK
#!/bin/bash
printf '\ntoken = %s\n' "$_tok" >>"\$1"
HOOK
chmod +x "$SZ1/repo/.git/hooks/pre-commit" "$SZ1/repo/.git/hooks/prepare-commit-msg"
printf 'y\n' >"$SZ1/.config/app/f.txt"
_sync_env "$SZ1" "$SZ1/repo" "$SZ1/g.json" sync --commit >/dev/null

it "a hook cannot slip content or a message into the commit after the scan"
assert_not_contains "$(git -C "$SZ1/repo" log -p --all 2>/dev/null)" "$_tok"

# git grep skips symlink entries entirely, but git stores the link TEXT as a
# blob. A link whose text is a token is a token in history.
SZ2="$(mktemp -d)"; _sec_env "$SZ2"
ln -s "$_tok" "$SZ2/.config/app/tlink"
_sync_env "$SZ2" "$SZ2/repo" "$SZ2/g.json" sync --commit >/dev/null; SZ2_RC=$?

it "a symlink whose own text is a token is refused"
(( SZ2_RC != 0 )) && ok || fail "the link text was committed unscanned"

# A NUL right before the token: bash dropped it when reading the line back, so
# the second regex pass lost the word boundary and discarded a real hit.
SZ3="$(mktemp -d)"; _sec_env "$SZ3"
printf 'a\0%s\n' "$_tok" >"$SZ3/.config/app/bin.dat"
_sync_env "$SZ3" "$SZ3/repo" "$SZ3/g.json" sync --commit >/dev/null; SZ3_RC=$?

it "a token right after a NUL byte is refused"
(( SZ3_RC != 0 )) && ok || fail "a NUL before the token hid it"

# Display settings of the repo must not change the verdict.
for _cfg in "color.ui always" "color.grep always" "grep.column true"; do
    SZC="$(mktemp -d)"; _sec_env "$SZC"
    git -C "$SZC/repo" config $_cfg
    printf 'token = %s\n' "$_tok" >"$SZC/.config/app/creds.txt"
    _sync_env "$SZC" "$SZC/repo" "$SZC/g.json" sync --commit >/dev/null; SZC_RC=$?
    it "sync --commit still refuses a token with ${_cfg% *}=${_cfg#* }"
    (( SZC_RC != 0 )) && ok || fail "${_cfg% *} let a token into the commit"
done

# git replace swaps what git SHOWS for an object. The candidate names the real
# blob; reading it through a replacement judged different bytes.
SZ4="$(mktemp -d)"; _sec_env "$SZ4"
printf 'token = %s\n' "$_tok" >"$SZ4/.config/app/creds.txt"
_bad="$(git -C "$SZ4/repo" hash-object -w "$SZ4/.config/app/creds.txt")"
_good="$(printf 'clean\n' | git -C "$SZ4/repo" hash-object -w --stdin)"
git -C "$SZ4/repo" replace "$_bad" "$_good"
_sync_env "$SZ4" "$SZ4/repo" "$SZ4/g.json" sync --commit >/dev/null; SZ4_RC=$?

it "a replacement object cannot stand in for the blob being committed"
(( SZ4_RC != 0 )) && ok || fail "the scan read the replacement, the commit took the token"

# A published name with glob characters is a literal path, not a pattern: it
# must not sweep up a same-looking draft this run never wrote.
SZ5="$(mktemp -d)"; _sec_env "$SZ5"
_sync_env "$SZ5" "$SZ5/repo" "$SZ5/g.json" sync --commit >/dev/null
printf 'draft\n' >"$SZ5/repo/configs/app/a1.txt"
printf 'mine\n' >"$SZ5/.config/app/a[1].txt"
_sync_env "$SZ5" "$SZ5/repo" "$SZ5/g.json" sync --commit >/dev/null

it "a published file named with glob characters commits only itself"
assert_not_contains "$(git -C "$SZ5/repo" show --name-only --format= HEAD)" "configs/app/a1.txt"

# If refreshing the user's index after the commit fails, the advice must not
# reset the WHOLE index and throw away what they staged elsewhere.
SZ6="$(mktemp -d)"; _sec_env "$SZ6"; mkdir -p "$SZ6/stub"
cat >"$SZ6/stub/git" <<SHIM
#!/bin/bash
if [[ -z "\${GIT_INDEX_FILE:-}" ]]; then
    for a in "\$@"; do [[ "\$a" == reset ]] && exit 1; done
fi
exec "$_REALGIT" "\$@"
SHIM
chmod +x "$SZ6/stub/git"
SZ6_OUT="$(PATH="$SZ6/stub:$PATH" _sync_env "$SZ6" "$SZ6/repo" "$SZ6/g.json" sync --commit)"

it "the recovery advice resets only the backed-up paths"
assert_contains "$SZ6_OUT" "reset -q -- "

# An interrupted sync leaves no candidate index -- nor any copy of a scanned
# blob -- behind. The shim holds the scan open until the test signals it.
SZ7="$(mktemp -d)"; _sec_env "$SZ7"; mkdir -p "$SZ7/stub"
cat >"$SZ7/stub/git" <<SHIM
#!/bin/bash
for a in "\$@"; do
    if [[ "\$a" == cat-file ]]; then : >"$SZ7/reached"; sleep 2; break; fi
done
exec "$_REALGIT" "\$@"
SHIM
chmod +x "$SZ7/stub/git"
printf 'z\n' >"$SZ7/.config/app/f.txt"
PATH="$SZ7/stub:$PATH" HOME="$SZ7" OMABACKUP_GROUPS="$SZ7/g.json" OMABACKUP_STATE="$SZ7/.state" \
    OMABACKUP_REPO="$SZ7/repo" XDG_RUNTIME_DIR=/nonexistent "$OB" sync --commit >/dev/null 2>&1 &
SZ7_PID=$!
for _ in $(seq 1 100); do [[ -e "$SZ7/reached" ]] && break; sleep 0.1; done
kill -TERM "$SZ7_PID" 2>/dev/null; wait "$SZ7_PID" 2>/dev/null

it "an interrupted sync leaves no candidate index or scanned copy behind"
[[ -e "$SZ7/reached" && -z "$(ls -d "$SZ7/repo/.git"/omabackup-sync.* 2>/dev/null)" ]] \
    && ok || fail "the scan was never reached, or its temporary files survived the signal"

# -- review round omabackup-70 ------------------------------------------------------
# A merge (or cherry-pick) the user is still resolving lives in the git
# directory, not in the index. A commit built from HEAD plus the backup paths
# would move HEAD under that operation. The old `commit -- paths` was refused by
# git in that state; the backup must refuse too and touch nothing.
SW1="$(mktemp -d)"; _sec_env "$SW1"
_sync_env "$SW1" "$SW1/repo" "$SW1/g.json" sync --commit >/dev/null
git -C "$SW1/repo" checkout -q -b side
printf 'side\n' >"$SW1/repo/README.md"; git -C "$SW1/repo" commit -qam side
git -C "$SW1/repo" checkout -q -
printf 'main\n' >"$SW1/repo/README.md"; git -C "$SW1/repo" commit -qam main
git -C "$SW1/repo" merge -q side >/dev/null 2>&1
SW1_HEAD="$(git -C "$SW1/repo" rev-parse HEAD)"
printf 'changed\n' >"$SW1/.config/app/f.txt"
_sync_env "$SW1" "$SW1/repo" "$SW1/g.json" sync --commit >/dev/null; SW1_RC=$?

it "sync --commit refuses while a merge is in progress"
(( SW1_RC != 0 )) && ok || fail "the backup committed in the middle of the user's merge"

it "and leaves HEAD and the merge state untouched"
[[ "$(git -C "$SW1/repo" rev-parse HEAD)" == "$SW1_HEAD" && -f "$SW1/repo/.git/MERGE_HEAD" ]] \
    && ok || fail "HEAD moved or MERGE_HEAD was cleared"

SW2="$(mktemp -d)"; _sec_env "$SW2"
_sync_env "$SW2" "$SW2/repo" "$SW2/g.json" sync --commit >/dev/null
git -C "$SW2/repo" checkout -q -b pick
printf 'pick\n' >"$SW2/repo/README.md"; git -C "$SW2/repo" commit -qam pick
git -C "$SW2/repo" checkout -q -
printf 'here\n' >"$SW2/repo/README.md"; git -C "$SW2/repo" commit -qam here
git -C "$SW2/repo" cherry-pick pick >/dev/null 2>&1
printf 'changed\n' >"$SW2/.config/app/f.txt"
_sync_env "$SW2" "$SW2/repo" "$SW2/g.json" sync --commit >/dev/null; SW2_RC=$?

it "sync --commit refuses while a cherry-pick is in progress"
(( SW2_RC != 0 )) && [[ -f "$SW2/repo/.git/CHERRY_PICK_HEAD" ]] \
    && ok || fail "the backup committed in the middle of the user's cherry-pick"

# A NUL INSIDE a quoted value: generic-assigned-secret's negated class crosses
# the NUL, and the push scan (which drops NULs) sees the whole value. Splitting
# the blob at NUL hid it, so the commit went in and push was blocked for good.
SW3="$(mktemp -d)"; _sec_env "$SW3"
printf 'pass''word = "abcdefgh\0ijklmnopqrstuv"\n' >"$SW3/.config/app/blob.bin"
_sync_env "$SW3" "$SW3/repo" "$SW3/g.json" sync --commit >/dev/null; SW3_RC=$?

it "a secret value with a NUL inside it is refused, as push would"
(( SW3_RC != 0 )) && ok || fail "the pre-commit scan was more permissive than the push scan"

# The prefilter must follow each rule's own case sensitivity: with -i, a
# negated class like [^A] also excludes `a`, so a case-sensitive rule could be
# skipped by the very pass meant to only save time.
SW4="$(mktemp -d)"; _sec_env "$SW4"
cat >"$SW4/deny.json" <<'JSON'
{"schemaVersion":1,"patterns":[
 {"id":"custom-cs","regex":"^secret=[^A]{16}$","reason":"test rule, case-sensitive"}]}
JSON
printf 'sec''ret=aaaaaaaaaaaaaaaa\n' >"$SW4/.config/app/c.txt"
OMABACKUP_SECRETS_DENY="$SW4/deny.json" _sync_env "$SW4" "$SW4/repo" "$SW4/g.json" sync --commit >/dev/null; SW4_RC=$?

it "the prefilter never skips what a case-sensitive rule would catch"
(( SW4_RC != 0 )) && ok || fail "a case-insensitive prefilter hid a case-sensitive rule's hit"

# Hooks defined in config (hook.<name>.event) are not files, so an empty hooks
# path does not silence them, and --no-verify leaves prepare-commit-msg running.
SW5="$(mktemp -d)"; _sec_env "$SW5"
_sync_env "$SW5" "$SW5/repo" "$SW5/g.json" sync --commit >/dev/null
git -C "$SW5/repo" config hook.leak.event prepare-commit-msg
git -C "$SW5/repo" config hook.leak.command "printf 'token = %s\n' '$_tok' >>\"\$1\""
printf 'changed\n' >"$SW5/.config/app/f.txt"
_sync_env "$SW5" "$SW5/repo" "$SW5/g.json" sync --commit >/dev/null

it "a config-defined hook cannot put anything into the backup's commit message"
assert_not_contains "$(git -C "$SW5/repo" log -1 --format=%B)" "$_tok"

SW6="$(mktemp -d)"; _sec_env "$SW6"
_sync_env "$SW6" "$SW6/repo" "$SW6/g.json" sync --commit >/dev/null
git -C "$SW6/repo" config hook.nope.event prepare-commit-msg
git -C "$SW6/repo" config hook.nope.command "false"
printf 'changed\n' >"$SW6/.config/app/f.txt"
_sync_env "$SW6" "$SW6/repo" "$SW6/g.json" sync --commit >/dev/null

it "a failing config-defined hook does not stop the backup from committing"
assert_eq "$(_commits "$SW6/repo")" "3"

# The push scan reads every path name in history, not only contents. A file
# whose NAME holds a token would pass a content-only scan here, be committed,
# and then block push for good -- the pre-commit scan has to read names too.
SN1="$(mktemp -d)"; _sec_env "$SN1"
printf 'harmless\n' >"$SN1/.config/app/$_tok.txt"
SN1_OUT="$(_sync_env "$SN1" "$SN1/repo" "$SN1/g.json" sync --commit)"; SN1_RC=$?

it "a collected file whose name holds a token is refused"
(( SN1_RC != 0 )) && ok || fail "a token in a file name was committed; push would then block for good"

it "and the refusal does not print that name in full"
assert_not_contains "$SN1_OUT" "$_tok"

# -- scout analysis omabackup-25 ------------------------------------------------------
# A: the commit OBJECT carries author and committer, and the push scan reads raw
# commit objects. A token in user.name passed every blob check and was written
# into history by commit-tree.
SX1="$(mktemp -d)"; _sec_env "$SX1"
_sync_env "$SX1" "$SX1/repo" "$SX1/g.json" sync --commit >/dev/null
SX1_HEAD="$(git -C "$SX1/repo" rev-parse HEAD)"
printf 'changed\n' >"$SX1/.config/app/f.txt"
SX1_OUT="$(GIT_AUTHOR_NAME="$_tok" GIT_COMMITTER_NAME="$_tok" _sync_env "$SX1" "$SX1/repo" "$SX1/g.json" sync --commit)"; SX1_RC=$?

it "a token in the commit's author or committer is refused before any ref moves"
(( SX1_RC != 0 )) && [[ "$(git -C "$SX1/repo" rev-parse HEAD)" == "$SX1_HEAD" ]] \
    && ok || fail "commit-tree wrote a token into the commit header and HEAD moved"

it "and the refusal does not print the header"
assert_not_contains "$SX1_OUT" "$_tok"

# B: the candidate is built from one HEAD; the commit must sit on that same HEAD.
# A commit the user makes while the sync scans moved HEAD, the old code re-read
# it as the parent, and the backup's tree -- built from the earlier HEAD --
# silently reverted the user's change.
SX2="$(mktemp -d)"; _sec_env "$SX2"; mkdir -p "$SX2/stub"
_sync_env "$SX2" "$SX2/repo" "$SX2/g.json" sync --commit >/dev/null
cat >"$SX2/stub/git" <<SHIM
#!/bin/bash
for a in "\$@"; do
    if [[ "\$a" == cat-file && ! -e "$SX2/done" ]]; then
        : >"$SX2/done"
        printf 'user edit\n' >"$SX2/repo/README.md"
        env -u GIT_INDEX_FILE "$_REALGIT" -C "$SX2/repo" commit -qam "user commit" >/dev/null 2>&1
        break
    fi
done
exec "$_REALGIT" "\$@"
SHIM
chmod +x "$SX2/stub/git"
printf 'changed\n' >"$SX2/.config/app/f.txt"
PATH="$SX2/stub:$PATH" _sync_env "$SX2" "$SX2/repo" "$SX2/g.json" sync --commit >/dev/null

it "a commit made during the sync is never reverted by the backup"
assert_eq "$(git -C "$SX2/repo" show HEAD:README.md 2>/dev/null)" "user edit"

# The branch is fixed too: switching to another branch at the same commit must
# not land the backup on it.
SX3="$(mktemp -d)"; _sec_env "$SX3"; mkdir -p "$SX3/stub"
_sync_env "$SX3" "$SX3/repo" "$SX3/g.json" sync --commit >/dev/null
SX3_BR="$(git -C "$SX3/repo" symbolic-ref --short HEAD)"
cat >"$SX3/stub/git" <<SHIM
#!/bin/bash
for a in "\$@"; do
    if [[ "\$a" == cat-file && ! -e "$SX3/done" ]]; then
        : >"$SX3/done"
        env -u GIT_INDEX_FILE "$_REALGIT" -C "$SX3/repo" checkout -q -b other >/dev/null 2>&1
        break
    fi
done
exec "$_REALGIT" "\$@"
SHIM
chmod +x "$SX3/stub/git"
printf 'changed\n' >"$SX3/.config/app/f.txt"
PATH="$SX3/stub:$PATH" _sync_env "$SX3" "$SX3/repo" "$SX3/g.json" sync --commit >/dev/null

it "a branch switched to during the sync does not receive the backup"
assert_eq "$(git -C "$SX3/repo" rev-parse other)" "$(git -C "$SX3/repo" rev-parse "$SX3_BR")"

# A replacement of the BASE commit would change the tree the candidate starts
# from -- outside the written paths, where nothing is scanned or compared.
SX4="$(mktemp -d)"; _sec_env "$SX4"
_sync_env "$SX4" "$SX4/repo" "$SX4/g.json" sync --commit >/dev/null
_empty="$(git -C "$SX4/repo" hash-object -t tree /dev/null)"
_fake="$(git -C "$SX4/repo" commit-tree "$_empty" -m fake)"
git -C "$SX4/repo" replace HEAD "$_fake"
printf 'changed\n' >"$SX4/.config/app/f.txt"
_sync_env "$SX4" "$SX4/repo" "$SX4/g.json" sync --commit >/dev/null

it "a replaced base commit cannot drop files from the backup's commit"
assert_contains "$(GIT_NO_REPLACE_OBJECTS=1 git -C "$SX4/repo" ls-tree -r --name-only HEAD)" "README.md"

# C: update-ref runs reference-transaction, from a file or from config. A hook
# that fails stopped every backup; one that prints reached the journal.
SX5="$(mktemp -d)"; _sec_env "$SX5"
_sync_env "$SX5" "$SX5/repo" "$SX5/g.json" sync --commit >/dev/null
printf '#!/bin/sh\necho FILE >>%s/ran\nexit 1\n' "$SX5" >"$SX5/repo/.git/hooks/reference-transaction"
chmod +x "$SX5/repo/.git/hooks/reference-transaction"
git -C "$SX5/repo" config hook.rt.event reference-transaction
git -C "$SX5/repo" config hook.rt.command "echo CFG >>$SX5/ran; exit 1"
printf 'changed\n' >"$SX5/.config/app/f.txt"
_sync_env "$SX5" "$SX5/repo" "$SX5/g.json" sync --commit >/dev/null

it "no reference-transaction hook runs for the backup's commit"
[[ ! -e "$SX5/ran" && "$(_commits "$SX5/repo")" == 3 ]] \
    && ok || fail "a reference-transaction hook ran (or blocked the commit)"

# D: a content hit printed the path, and the path itself can be the secret.
SX6="$(mktemp -d)"; _sec_env "$SX6"
printf 'token = %s\n' "$_tok" >"$SX6/.config/app/$_tok.conf"
SX6_OUT="$(_sync_env "$SX6" "$SX6/repo" "$SX6/g.json" sync --commit)"; SX6_RC=$?

it "a file with a token in both its name and its content is refused"
(( SX6_RC != 0 )) && ok || fail "not refused"

it "and neither the name nor the content is printed"
assert_not_contains "$SX6_OUT" "$_tok"

# -- review round omabackup-71 ------------------------------------------------------
# The push scan judges every TREE name too (rev-list --objects lists
# directories). A rule anchored on a directory's own path never matched the
# full path of the file below it.
SY71A="$(mktemp -d)"; _sec_env "$SY71A"
_dirtok="AKIA$(printf 'A%.0s' {1..16})"
cat >"$SY71A/deny.json" <<JSON
{"schemaVersion":1,"patterns":[
 {"id":"dir-anchored","regex":"^configs/app/AKIA[A-Z0-9]{16}\$","reason":"test rule anchored on a directory"}]}
JSON
mkdir -p "$SY71A/.config/app/$_dirtok"
printf 'clean\n' >"$SY71A/.config/app/$_dirtok/clean.txt"
SY71A_OUT="$(OMABACKUP_SECRETS_DENY="$SY71A/deny.json" _sync_env "$SY71A" "$SY71A/repo" "$SY71A/g.json" sync --commit)"; SY71A_RC=$?

it "a directory whose own name the deny-list matches is refused"
(( SY71A_RC != 0 )) && ok || fail "a directory name the push scan would block was committed"

it "and the directory name is not printed"
assert_not_contains "$SY71A_OUT" "$_dirtok"

# The coverage warning about a published file the repo ignores named that file
# before any scan ran -- and the name can be the secret.
SY71B="$(mktemp -d)"; _sec_env "$SY71B"
printf '%s*\n' "configs/app/gh" >"$SY71B/repo/.gitignore"
git -C "$SY71B/repo" add .gitignore && git -C "$SY71B/repo" commit -qm ignore
printf 'harmless\n' >"$SY71B/.config/app/$_tok.txt"
printf 'token = %s\n' "$_tok" >"$SY71B/.config/app/creds.txt"
SY71B_OUT="$(_sync_env "$SY71B" "$SY71B/repo" "$SY71B/g.json" sync --commit)"

it "the ignored-file warning never prints a file name"
assert_not_contains "$SY71B_OUT" "$_tok"

# A token in the name is now refused by the staging scan before the warning
# exists, so the warning itself is checked with an ordinary ignored file.
SY71W="$(mktemp -d)"; _sec_env "$SY71W"
printf 'configs/app/dropped*\n' >"$SY71W/repo/.gitignore"
git -C "$SY71W/repo" add .gitignore && git -C "$SY71W/repo" commit -qm ignore
printf 'harmless\n' >"$SY71W/.config/app/dropped-file.txt"
SY71W_OUT="$(_sync_env "$SY71W" "$SY71W/repo" "$SY71W/g.json" sync --commit)"

it "but still warns that something was dropped"
assert_contains "$SY71W_OUT" "repo ignores"

it "without naming the dropped file"
assert_not_contains "$SY71W_OUT" "dropped-file"

# git puts the identity into some of its own errors. A failing commit-tree must
# not print it.
SY71C="$(mktemp -d)"; _sec_env "$SY71C"
_sync_env "$SY71C" "$SY71C/repo" "$SY71C/g.json" sync --commit >/dev/null
printf 'changed\n' >"$SY71C/.config/app/f.txt"
SY71C_OUT="$(GIT_AUTHOR_NAME="" GIT_COMMITTER_NAME="" GIT_AUTHOR_EMAIL="$_tok@example.test" GIT_COMMITTER_EMAIL="$_tok@example.test" \
    _sync_env "$SY71C" "$SY71C/repo" "$SY71C/g.json" sync --commit)"; SY71C_RC=$?

it "a commit-tree that fails on the identity does not print it"
if (( SY71C_RC != 0 )); then assert_not_contains "$SY71C_OUT" "$_tok"
else fail "the commit went ahead with an identity git should have refused"; fi

# Hooks that run while the candidate is being BUILT (post-index-change, from a
# file or from config) and core.fsmonitor. The tree is written before the scan
# and only that tree is committed, so nothing they do can slip in -- and they
# are switched off besides.
for _v in file config fsmonitor; do
    SY71D="$(mktemp -d)"; _sec_env "$SY71D"
    _sync_env "$SY71D" "$SY71D/repo" "$SY71D/g.json" sync --commit >/dev/null
    cat >"$SY71D/inj.sh" <<INJ
#!/bin/bash
printf 'token = %s\n' "$_tok" >"$SY71D/repo/sneak.txt"
git -C "$SY71D/repo" add sneak.txt >/dev/null 2>&1
INJ
    chmod +x "$SY71D/inj.sh"
    case "$_v" in
        file)      cp "$SY71D/inj.sh" "$SY71D/repo/.git/hooks/post-index-change" ;;
        config)    git -C "$SY71D/repo" config hook.pic.event post-index-change
                   git -C "$SY71D/repo" config hook.pic.command "$SY71D/inj.sh" ;;
        fsmonitor) printf 'printf "/\\0"\n' >>"$SY71D/inj.sh"
                   git -C "$SY71D/repo" config core.fsmonitor "$SY71D/inj.sh" ;;
    esac
    printf 'changed\n' >"$SY71D/.config/app/f.txt"
    _sync_env "$SY71D" "$SY71D/repo" "$SY71D/g.json" sync --commit >/dev/null
    it "a $_v hook running while the candidate is built never reaches history"
    assert_not_contains "$(git -C "$SY71D/repo" log -p --all 2>/dev/null)" "$_tok"
done

# The commit may only carry what this run wrote. Anything else that reached the
# candidate -- by any route, hook or not -- refuses the commit, even when clean.
# A git shim injects the entry right after the candidate's own `add`.
SY71F="$(mktemp -d)"; _sec_env "$SY71F"; mkdir -p "$SY71F/stub"
_sync_env "$SY71F" "$SY71F/repo" "$SY71F/g.json" sync --commit >/dev/null
cat >"$SY71F/stub/git" <<SHIM
#!/bin/bash
"$_REALGIT" "\$@"; rc=\$?
if [[ -n "\${GIT_INDEX_FILE:-}" ]]; then
    for a in "\$@"; do
        if [[ "\$a" == add ]]; then
            oid=\$(printf 'clean but unasked\n' | "$_REALGIT" -C "$SY71F/repo" hash-object -w --stdin)
            "$_REALGIT" -C "$SY71F/repo" update-index --add --cacheinfo "100644,\$oid,extra.txt"
            break
        fi
    done
fi
exit \$rc
SHIM
chmod +x "$SY71F/stub/git"
printf 'changed\n' >"$SY71F/.config/app/f.txt"
PATH="$SY71F/stub:$PATH" _sync_env "$SY71F" "$SY71F/repo" "$SY71F/g.json" sync --commit >/dev/null; SY71F_RC=$?

it "a path this run did not write never rides into the backup's commit"
if (( SY71F_RC != 0 )); then assert_not_contains "$(git -C "$SY71F/repo" ls-tree -r --name-only HEAD)" "extra.txt"
else fail "a path this run never wrote was committed"; fi

# A commit-object scan that could not run is not a match, and must not send the
# user to check their identity.
SY71G="$(mktemp -d)"; _sec_env "$SY71G"; mkdir -p "$SY71G/stub"
_sync_env "$SY71G" "$SY71G/repo" "$SY71G/g.json" sync --commit >/dev/null
cat >"$SY71G/stub/git" <<SHIM
#!/bin/bash
c=0; m=0
for a in "\$@"; do [[ "\$a" == cat-file ]] && c=1; [[ "\$a" == commit ]] && m=1; done
(( c && m )) && exit 1
exec "$_REALGIT" "\$@"
SHIM
chmod +x "$SY71G/stub/git"
printf 'changed\n' >"$SY71G/.config/app/f.txt"
SY71G_OUT="$(PATH="$SY71G/stub:$PATH" _sync_env "$SY71G" "$SY71G/repo" "$SY71G/g.json" sync --commit)"

it "a commit-object scan that cannot run says so, without blaming the identity"
assert_contains "$SY71G_OUT" "could not complete"
assert_not_contains "$SY71G_OUT" "user.name"

# Every update-ref failure used to read "HEAD moved during the sync", a busy
# ref lock included.
SY71H="$(mktemp -d)"; _sec_env "$SY71H"; mkdir -p "$SY71H/stub"
_sync_env "$SY71H" "$SY71H/repo" "$SY71H/g.json" sync --commit >/dev/null
cat >"$SY71H/stub/git" <<SHIM
#!/bin/bash
for a in "\$@"; do [[ "\$a" == update-ref ]] && exit 1; done
exec "$_REALGIT" "\$@"
SHIM
chmod +x "$SY71H/stub/git"
printf 'changed\n' >"$SY71H/.config/app/f.txt"
SY71H_OUT="$(PATH="$SY71H/stub:$PATH" _sync_env "$SY71H" "$SY71H/repo" "$SY71H/g.json" sync --commit)"

it "a failed branch update does not claim that HEAD moved"
assert_not_contains "$SY71H_OUT" "HEAD moved"

# The timer runs under the systemd user manager's locale (LANG=en_US.UTF-8 on
# the development machine). The pre-commit gate must hold there too.
SU8="$(mktemp -d)"; _sec_env "$SU8"
printf '\xff%s\n' "$_tok" >"$SU8/.config/app/bin.dat"
LC_ALL=C.UTF-8 _sync_env "$SU8" "$SU8/repo" "$SU8/g.json" sync --commit >/dev/null; SU8_RC=$?
it "sync --commit refuses a token after an invalid UTF-8 byte under a UTF-8 locale"
(( SU8_RC != 0 )) && ok || fail "a UTF-8 locale let a token into the commit"

# -- review round omabackup-78 ------------------------------------------------------
# A path that changes type. git add drops configs/app/foo when it records
# configs/app/foo/bar, and dd/x when it records the file dd; the check for
# paths this run did not write counted those deletions and refused every sync
# of the repository from then on, blaming a hook. Publish already refuses
# while the old path is in the worktree, so the user frees it first.
R78A="$(mktemp -d)"; _sec_env "$R78A"
printf 'was a file\n' >"$R78A/.config/app/foo"
_sync_env "$R78A" "$R78A/repo" "$R78A/g.json" sync --commit >/dev/null
rm -f "$R78A/.config/app/foo"; mkdir -p "$R78A/.config/app/foo"; printf 'now below\n' >"$R78A/.config/app/foo/bar"
rm -f "$R78A/repo/configs/app/foo"
_sync_env "$R78A" "$R78A/repo" "$R78A/g.json" sync --commit >/dev/null; R78A_RC=$?
it "a file that became a directory is committed"
(( R78A_RC == 0 )) && ok || fail "sync --commit refused a file -> directory change"
it "and the commit holds the new path"
assert_contains "$(git -C "$R78A/repo" ls-tree -r --name-only HEAD)" "configs/app/foo/bar"

R78B="$(mktemp -d)"; _sec_env "$R78B"
mkdir -p "$R78B/.config/app/dd"; printf 'below\n' >"$R78B/.config/app/dd/x"
_sync_env "$R78B" "$R78B/repo" "$R78B/g.json" sync --commit >/dev/null
rm -f "$R78B/.config/app/dd/x"; rmdir "$R78B/.config/app/dd"; printf 'now a file\n' >"$R78B/.config/app/dd"
rm -f "$R78B/repo/configs/app/dd/x"; rmdir "$R78B/repo/configs/app/dd"
_sync_env "$R78B" "$R78B/repo" "$R78B/g.json" sync --commit >/dev/null; R78B_RC=$?
it "a directory that became a file is committed"
(( R78B_RC == 0 )) && ok || fail "sync --commit refused a directory -> file change"
it "and the commit holds the file, not the old entry"
R78B_LS="$(git -C "$R78B/repo" ls-tree -r --name-only HEAD)"
[[ "$R78B_LS" == *"configs/app/dd"* && "$R78B_LS" != *"configs/app/dd/x"* ]] && ok || fail "tree: $R78B_LS"

# Only a deletion a written path implies. A wrapper that drops an unrelated
# entry from the candidate still refuses.
R78C="$(mktemp -d)"; _sec_env "$R78C"; mkdir -p "$R78C/stub"
_sync_env "$R78C" "$R78C/repo" "$R78C/g.json" sync --commit >/dev/null
cat >"$R78C/stub/git" <<SHIM
#!/bin/bash
"$_REALGIT" "\$@"; rc=\$?
if [[ -n "\${GIT_INDEX_FILE:-}" ]]; then
    for a in "\$@"; do
        if [[ "\$a" == add ]]; then
            "$_REALGIT" -C "$R78C/repo" update-index --force-remove README.md
            break
        fi
    done
fi
exit \$rc
SHIM
chmod +x "$R78C/stub/git"
printf 'changed\n' >"$R78C/.config/app/f.txt"
PATH="$R78C/stub:$PATH" _sync_env "$R78C" "$R78C/repo" "$R78C/g.json" sync --commit >/dev/null; R78C_RC=$?
it "a deletion this run did not cause still refuses the commit"
if (( R78C_RC != 0 )); then assert_contains "$(git -C "$R78C/repo" ls-tree -r --name-only HEAD)" "README.md"
else fail "an unrelated deletion rode into the backup's commit"; fi

# A name with a newline, under a rule anchored with $: refused before it can
# become history that push would refuse.
R78D="$(mktemp -d)"; _sec_env "$R78D"
_sync_env "$R78D" "$R78D/repo" "$R78D/g.json" sync --commit >/dev/null
cat >"$R78D/deny.json" <<'JSON'
{"schemaVersion":1,"patterns":[
 {"id":"custom-end","regex":"secret=[a-z]{16}$","reason":"test rule anchored at the end"}]}
JSON
printf 'clean\n' >"$R78D/.config/app/sec""ret=abcdefghijklmnop"$'\n'"x.txt"
R78D_OUT="$(OMABACKUP_SECRETS_DENY="$R78D/deny.json" _sync_env "$R78D" "$R78D/repo" "$R78D/g.json" sync --commit)"; R78D_RC=$?
it "a name a rule matches up to its first newline is refused"
(( R78D_RC != 0 )) && ok || fail "committed a name that push would refuse"
it "and nothing was committed, nor the name printed"
assert_eq "$(_commits "$R78D/repo")" "2"
assert_not_contains "$R78D_OUT" "abcdefghijklmnop"

# A file name only this gate sees: a rule anchored on the repository path,
# which the staging scan never has.
R78E="$(mktemp -d)"; _sec_env "$R78E"
_sync_env "$R78E" "$R78E/repo" "$R78E/g.json" sync --commit >/dev/null
_r78tok="AKIA$(printf 'B%.0s' {1..16})"
cat >"$R78E/deny.json" <<JSON
{"schemaVersion":1,"patterns":[
 {"id":"repo-anchored","regex":"^configs/app/AKIA[A-Z0-9]{16}\\\\.txt\$","reason":"test rule anchored on the repo path"}]}
JSON
printf 'clean\n' >"$R78E/.config/app/$_r78tok.txt"
R78E_OUT="$(OMABACKUP_SECRETS_DENY="$R78E/deny.json" _sync_env "$R78E" "$R78E/repo" "$R78E/g.json" sync --commit)"; R78E_RC=$?
it "a file name matched only on its repository path is refused before the commit"
(( R78E_RC != 0 )) && ok || fail "committed a file name the push scan would refuse"
it "by the pre-commit gate, without printing the name"
assert_contains "$R78E_OUT" "changed path #"
assert_not_contains "$R78E_OUT" "$_r78tok"

# The panel's Config section: where this machine is pointed.
#
# Everything here is machine identity rather than project data -- the repo that
# receives the backup, the destinations file, the deny-list, the timer schedule.
# None of it lives in the public manifest, which is exactly why the interface
# has to show it: otherwise the only way to know what a machine is configured to
# do is to read four files in three directories.

OB="$(realpath "$PWD/bin/omabackup")"

_cfg_env() {
    local h="$1"; shift
    HOME="$h" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$h/g.json" \
        OMABACKUP_STATE="$h/.state" OMABACKUP_REPO="$h/repo" \
        OMABACKUP_DESTINATIONS="$h/dest.json" OMABACKUP_SYSTEMCTL="$h/stub/systemctl" \
        XDG_RUNTIME_DIR=/nonexistent "$OB" "$@" 2>&1
}

_cfg_home() {
    local h; h="$(mktemp -d)"
    mkdir -p "$h/.config/app" "$h/stub" "$h/repo"
    printf 'x\n' >"$h/.config/app/f.txt"
    cat >"$h/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/app"]}]}
JSON
    printf '{"schemaVersion":1,"destinations":[]}\n' >"$h/dest.json"
    # A stub that answers the schedule query the way systemd does.
    { printf '#!/bin/bash\n'
      printf 'if [[ "$*" == *TimersCalendar* && "$*" == *sync* ]]; then echo "{ OnCalendar=*-*-* *:00/15:00 ; next_elapse=... }"; exit 0; fi\n'
      printf 'if [[ "$*" == *TimersCalendar* && "$*" == *push* ]]; then echo "{ OnCalendar=*-*-* *:00:00 ; next_elapse=... }"; exit 0; fi\n'
      printf 'exit 0\n'
    } >"$h/stub/systemctl"
    chmod +x "$h/stub/systemctl"
    git init -q "$h/repo"
    printf '%s' "$h"
}

CH="$(_cfg_home)"
CJ="$(_cfg_env "$CH" status --json)"

it "status --json reports which repo receives the backup"
assert_contains "$(printf '%s' "$CJ" | jq -r '.config.repo')" "$CH/repo"

it "and where the destinations are configured"
assert_contains "$(printf '%s' "$CJ" | jq -r '.config.destinationsFile')" "dest.json"

it "and which deny-list guards the push"
assert_contains "$(printf '%s' "$CJ" | jq -r '.config.denyList')" "secrets.deny.json"

it "and where its own state lives"
assert_contains "$(printf '%s' "$CJ" | jq -r '.config.state')" "$CH/.state"

it "status reports GitHub as inactive when the repository has no origin"
assert_eq "$(printf '%s' "$CJ" | jq -r '.config.github.active')" "false"
assert_eq "$(printf '%s' "$CJ" | jq -r '.config.github.configured')" "false"

it "the schedule is read from the timers, not hardcoded in the panel"
# The interval is systemd's to know. Repeating it in QML would be the same fact
# in two places, which is how four things in this project have already drifted.
assert_contains "$(printf '%s' "$CJ" | jq -r '.scheduler.sync')" "15"
assert_eq "$(printf '%s' "$CJ" | jq -r '.scheduler.syncCron // empty')" "*/15 * * * *"

it "and the push schedule with it"
[[ -n "$(printf '%s' "$CJ" | jq -r '.scheduler.push // empty')" ]] \
    && ok || fail "no push schedule reported"

# ── it degrades where there is no session to ask ─────────────────────────────
DH="$(_cfg_home)"
printf '#!/bin/bash\nexit 1\n' >"$DH/stub/systemctl"; chmod +x "$DH/stub/systemctl"
DJ="$(_cfg_env "$DH" status --json)"

it "a machine with no timers still produces a valid document"
assert_eq "$(printf '%s' "$DJ" | jq -r '.schemaVersion')" "1"

it "and reports the schedule as unknown rather than inventing one"
assert_eq "$(printf '%s' "$DJ" | jq -r '.scheduler.sync')" "null"

# ── the machine-owned config contract ───────────────────────────────────────
mkdir -p "$CH/.config/systemd/user"
cat >"$CH/.config/systemd/user/omabackup-sync.timer" <<'UNIT'
[Timer]
OnCalendar=*:0/15
Persistent=true
UNIT
cat >"$CH/.config/systemd/user/omabackup-push.timer" <<'UNIT'
[Timer]
OnCalendar=hourly
Persistent=true
UNIT

CFG_SHOW="$(_cfg_env "$CH" config show --json)"

it "config show is a machine-readable read-only view"
assert_eq "$(printf '%s' "$CFG_SHOW" | jq -r '.schemaVersion')" "1"

it "config show exposes the current repo and destination schema"
assert_eq "$(printf '%s' "$CFG_SHOW" | jq -r '.repo')" "$CH/repo"
assert_eq "$(printf '%s' "$CFG_SHOW" | jq -r '.destinations | type')" "array"
assert_eq "$(printf '%s' "$CFG_SHOW" | jq -r '.schedules.sync')" "*/15 * * * *"
assert_eq "$(printf '%s' "$CFG_SHOW" | jq -r '.schedules.calendar.sync')" "*-*-* *:00/15:00"

it "config show distinguishes a repository without an origin"
assert_eq "$(printf '%s' "$CFG_SHOW" | jq -r '.github.active')" "false"
assert_eq "$(printf '%s' "$CFG_SHOW" | jq -r '.github.configured')" "false"
assert_eq "$(printf '%s' "$CFG_SHOW" | jq -r '.github.url // empty')" ""

git init -q --bare "$CH/remote.git"
git -C "$CH/repo" remote add origin "$CH/remote.git"
CFG_GITHUB_SHOW="$(_cfg_env "$CH" config show --json)"
CFG_GITHUB_STATUS="$(_cfg_env "$CH" status --json)"

it "config show reports the implicit GitHub destination when origin exists"
assert_eq "$(printf '%s' "$CFG_GITHUB_SHOW" | jq -r '.github.active')" "true"
assert_eq "$(printf '%s' "$CFG_GITHUB_SHOW" | jq -r '.github.configured')" "true"
assert_eq "$(printf '%s' "$CFG_GITHUB_SHOW" | jq -r '.github.remote')" "origin"
assert_eq "$(printf '%s' "$CFG_GITHUB_SHOW" | jq -r '.github.url')" "$CH/remote.git"

it "status reports GitHub as active when the repository has an origin"
assert_eq "$(printf '%s' "$CFG_GITHUB_STATUS" | jq -r '.config.github.active')" "true"
assert_eq "$(printf '%s' "$CFG_GITHUB_STATUS" | jq -r '.config.github.configured')" "true"
assert_eq "$(printf '%s' "$CFG_GITHUB_STATUS" | jq -r '.config.github.url')" "$CH/remote.git"

git -C "$CH/repo" remote set-url origin "$CH/fetch.git"
git -C "$CH/repo" remote set-url --push origin "$CH/push.git"
CFG_PUSHURL_SHOW="$(_cfg_env "$CH" config show --json)"
CFG_PUSHURL_STATUS="$(_cfg_env "$CH" status --json)"

it "config and status show the effective push URL when pushurl differs"
assert_eq "$(printf '%s' "$CFG_PUSHURL_SHOW" | jq -r '.github.url')" "$CH/push.git"
assert_eq "$(printf '%s' "$CFG_PUSHURL_STATUS" | jq -r '.config.github.url')" "$CH/push.git"

git -C "$CH/repo" remote set-url --push origin 'https://breno:ghp_EXAMPLE_TOKEN@github.com/user/dotfiles.git'
CFG_CREDENTIAL_SHOW="$(_cfg_env "$CH" config show --json)"
CFG_CREDENTIAL_STATUS="$(_cfg_env "$CH" status --json)"

it "config status redacts credentials from the effective push URL"
assert_eq "$(printf '%s' "$CFG_CREDENTIAL_SHOW" | jq -r '.github.url')" "https://github.com/user/dotfiles.git"
assert_eq "$(printf '%s' "$CFG_CREDENTIAL_STATUS" | jq -r '.config.github.url')" "https://github.com/user/dotfiles.git"
assert_not_contains "$CFG_CREDENTIAL_SHOW" "ghp_EXAMPLE_TOKEN"
assert_not_contains "$CFG_CREDENTIAL_STATUS" "ghp_EXAMPLE_TOKEN"
assert_eq "$(printf '%s' "$CFG_CREDENTIAL_STATUS" | jq -r '.destinations[] | select(.id == "github") | .locator')" "https://github.com/user/dotfiles.git"
assert_not_contains "$(printf '%s' "$CFG_CREDENTIAL_STATUS" | jq -r '.destinations[] | select(.id == "github") | .locator')" "ghp_EXAMPLE_TOKEN"

git -C "$CH/repo" remote set-url --add --push origin "$CH/second-push.git"
MULTI_PUSH_COUNT="$(git -C "$CH/repo" remote get-url --push --all origin | wc -l)"
MULTI_PUSH_HAS_SECOND=0
git -C "$CH/repo" remote get-url --push --all origin | grep -Fx "$CH/second-push.git" >/dev/null \
    && MULTI_PUSH_HAS_SECOND=1
CFG_MULTI_PUSH="$(_cfg_env "$CH" config show --json)"
MULTI_PUSH_STATUS="$(_cfg_env "$CH" status --json)"

it "documents that GitHub status exposes the first push target when origin fans out"
assert_eq "$MULTI_PUSH_COUNT" "2"
assert_eq "$MULTI_PUSH_HAS_SECOND" "1"
assert_eq "$(printf '%s' "$CFG_MULTI_PUSH" | jq -r '.github.url')" "https://github.com/user/dotfiles.git"
assert_eq "$(printf '%s' "$MULTI_PUSH_STATUS" | jq -r '.destinations[] | select(.id == "github") | .locator')" "https://github.com/user/dotfiles.git"

git -C "$CH/repo" commit --allow-empty -qm worktree-base
git -C "$CH/repo" worktree add -q "$CH/worktree"
WORKTREE_SHOW="$(HOME="$CH" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$CH/g.json" \
    OMABACKUP_STATE="$CH/.state" OMABACKUP_REPO="$CH/worktree" \
    OMABACKUP_DESTINATIONS="$CH/dest.json" OMABACKUP_SYSTEMCTL="$CH/stub/systemctl" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" config show --json 2>&1)"

it "config keeps linked worktrees outside the supported repository contract"
assert_eq "$(printf '%s' "$WORKTREE_SHOW" | jq -r '.github.active')" "false"
assert_eq "$(printf '%s' "$WORKTREE_SHOW" | jq -r '.github.configured')" "false"
assert_eq "$(printf '%s' "$WORKTREE_SHOW" | jq -r '.github.url // empty')" ""

CH_INACTIVE="$(_cfg_home)"
INACTIVE_REMOTE="$CH_INACTIVE/remote.git"; git init -q --bare "$INACTIVE_REMOTE"
git -C "$CH_INACTIVE/repo" remote add origin "$INACTIVE_REMOTE"
printf '#!/bin/bash\nexit 1\n' >"$CH_INACTIVE/stub/systemctl"
chmod +x "$CH_INACTIVE/stub/systemctl"
INACTIVE_STATUS="$(_cfg_env "$CH_INACTIVE" status --json)"

it "keeps GitHub configured when timers are unavailable"
assert_eq "$(printf '%s' "$INACTIVE_STATUS" | jq -r '.config.github.active')" "true"
assert_eq "$(printf '%s' "$INACTIVE_STATUS" | jq -r '.config.github.configured')" "true"

mkdir -p "$CH/.config/omabackup"
printf 'CUSTOM_HAND_EDIT=kept\nOMABACKUP_REPO=%s\n' "$CH/repo" >"$CH/.config/omabackup/env"
git init -q "$CH/repo with spaces"
_cfg_env "$CH" config set repo "$CH/repo with spaces" >/dev/null

it "config set preserves unrelated env lines and writes the repo atomically"
assert_contains "$(cat "$CH/.config/omabackup/env")" "CUSTOM_HAND_EDIT=kept"
assert_contains "$(cat "$CH/.config/omabackup/env")" "OMABACKUP_REPO=$CH/repo with spaces"
[[ ! -e "$CH/.config/omabackup/.env.tmp" ]] && ok || fail "temporary env file was left behind"

INVALID_REPO_HOME="$(_cfg_home)"
mkdir -p "$INVALID_REPO_HOME/.config/omabackup"
printf 'CUSTOM_HAND_EDIT=kept\nOMABACKUP_REPO=%s\n' "$INVALID_REPO_HOME/repo" \
    >"$INVALID_REPO_HOME/.config/omabackup/env"
INVALID_REPO_ENV_BEFORE="$(cat "$INVALID_REPO_HOME/.config/omabackup/env")"
INVALID_REPO_RC=0
INVALID_REPO_OUT="$(_cfg_env "$INVALID_REPO_HOME" config set repo "$INVALID_REPO_HOME/not-a-repository" 2>&1)" \
    || INVALID_REPO_RC=$?

it "an invalid repository is rejected without erasing the configured repository"
[[ $INVALID_REPO_RC -ne 0 ]] && ok || fail "invalid repository unexpectedly passed"
assert_eq "$(cat "$INVALID_REPO_HOME/.config/omabackup/env")" "$INVALID_REPO_ENV_BEFORE"
assert_contains "$INVALID_REPO_OUT" "existing git repository"

DEST_PATH="$CH/Backups Here"
_cfg_env "$CH" config destination add local "$DEST_PATH" 3 >/dev/null

it "config destination add accepts spaces and persists retention"
assert_eq "$(jq -r '.destinations[0].path' "$CH/dest.json")" "$DEST_PATH"
assert_eq "$(jq -r '.destinations[0].keep' "$CH/dest.json")" "3"

_cfg_tui() {
    _cfg_tui_home "$CH" "$1" "$CH/repo"
}

_cfg_tui_home() {
    local h="$1" input="$2" repo
    if (($# >= 3)); then repo="$3"; else repo="$h/repo"; fi
    printf '%b' "$input" | script -qec \
        "env HOME='$h' OMABACKUP_ROOT='$PWD' OMABACKUP_GROUPS='$h/g.json' \
         OMABACKUP_STATE='$h/.state' OMABACKUP_REPO='$repo' \
         OMABACKUP_DESTINATIONS='$h/dest.json' OMABACKUP_SYSTEMCTL='$h/stub/systemctl' \
         XDG_RUNTIME_DIR=/nonexistent '$OB' config" /dev/null 2>&1
}

HUMAN_GITHUB_SHOW="$(_cfg_env "$CH" config show)"
GITHUB_TUI="$(_cfg_tui $'q\n')"

it "the Settings TUI explains that GitHub is an implicit repository push"
assert_contains "$GITHUB_TUI" "GitHub"
assert_contains "$GITHUB_TUI" "https://github.com/user/dotfiles.git"
assert_contains "$GITHUB_TUI" "first push target"
assert_contains "$GITHUB_TUI" "Git may use more"
assert_contains "$GITHUB_TUI" "default push set"
assert_not_contains "$GITHUB_TUI" "every push"
assert_not_contains "$GITHUB_TUI" "ghp_EXAMPLE_TOKEN"
assert_contains "$HUMAN_GITHUB_SHOW" "first push target"
assert_contains "$HUMAN_GITHUB_SHOW" "Git may use more"

GITINIT_HOME="$(_cfg_home)"
mkdir -p "$GITINIT_HOME/plain-folder"
GITINIT_TUI="$(_cfg_tui_home "$GITINIT_HOME" $'1\n'"$GITINIT_HOME/plain-folder"$'\ny\nq\n' "$GITINIT_HOME/repo")"

it "the config TUI offers to git init a plain folder chosen as the backup repository, and inits on yes"
assert_contains "$GITINIT_TUI" "is not a git repository yet"
assert_contains "$GITINIT_TUI" "Initialized an empty git repository"
[[ -d "$GITINIT_HOME/plain-folder/.git" ]] && ok || fail "accepting the offer did not run git init in the chosen folder"
assert_contains "$(cat "$GITINIT_HOME/.config/omabackup/env" 2>/dev/null)" "OMABACKUP_REPO=$GITINIT_HOME/plain-folder"
assert_not_contains "$GITINIT_TUI" "will back up nothing"

# A fresh `git init` means an empty index, and a manifest path declared
# trackedOnly (paths[].trackedRepoPath) uses `git ls-files` as its allow-list
# (collect_tracked_only, bin/omabackup) -- so it silently backs up nothing
# until something is committed there. That already surfaces as a `warn`
# finding on the next sync, but this asserts it is ALSO said right here, at
# the moment the empty index is created, not discovered as a surprise days
# later.
GITINIT_TRACKED_HOME="$(_cfg_home)"
cat >"$GITINIT_TRACKED_HOME/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"scripts","label":"Personal scripts","mode":"copy","coupled":false,"critical":false,
  "paths":[{"live":"~/.local/bin","trackedRepoPath":"scripts/local-bin"}]}]}
JSON
mkdir -p "$GITINIT_TRACKED_HOME/plain-folder"
GITINIT_TRACKED_TUI="$(_cfg_tui_home "$GITINIT_TRACKED_HOME" $'1\n'"$GITINIT_TRACKED_HOME/plain-folder"$'\ny\nq\n' "$GITINIT_TRACKED_HOME/repo")"

it "the git-init offer warns up front about trackedOnly groups that will have empty coverage"
assert_contains "$GITINIT_TRACKED_TUI" "Initialized an empty git repository"
assert_contains "$GITINIT_TRACKED_TUI" "~/.local/bin"
# Naming only the live path and saying "commit something there" is not
# actionable: coverage depends on git ls-files under trackedRepoPath INSIDE
# the backup repo (collect_tracked_only, bin/omabackup), not on the live path,
# which is usually not even a git repository of its own. The message must
# name that real location.
assert_contains "$GITINIT_TRACKED_TUI" "tracked under scripts/local-bin"
assert_contains "$GITINIT_TRACKED_TUI" "will back up nothing until this repository tracks files there"

# Every other per-group jq query in this codebase filters
# select(.enabled != false) (bin/omabackup:285,290,309,311,317) -- a disabled
# group's declared paths intentionally back up nothing, so warning about them
# here would be its own false positive.
GITINIT_DISABLED_HOME="$(_cfg_home)"
cat >"$GITINIT_DISABLED_HOME/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"scripts","label":"Personal scripts","mode":"copy","coupled":false,"critical":false,"enabled":false,
  "paths":[{"live":"~/.local/bin","trackedRepoPath":"scripts/local-bin"}]}]}
JSON
mkdir -p "$GITINIT_DISABLED_HOME/plain-folder"
GITINIT_DISABLED_TUI="$(_cfg_tui_home "$GITINIT_DISABLED_HOME" $'1\n'"$GITINIT_DISABLED_HOME/plain-folder"$'\ny\nq\n' "$GITINIT_DISABLED_HOME/repo")"

it "the trackedOnly warning does not fire for a disabled group's paths"
assert_contains "$GITINIT_DISABLED_TUI" "Initialized an empty git repository"
assert_not_contains "$GITINIT_DISABLED_TUI" "will back up nothing"

# A bare repository (`git init --bare`) has no `.git` subdirectory at all --
# the other concrete "no .git subdir" shape besides a linked worktree's
# .git-as-a-file, and the one omabackup-16's own request specifically named
# as reproduced-but-uncovered. `git rev-parse --git-dir` still recognizes it.
GITINIT_BARE_HOME="$(_cfg_home)"
git init -q --bare "$GITINIT_BARE_HOME/bare.git"
GITINIT_BARE_TUI="$(_cfg_tui_home "$GITINIT_BARE_HOME" $'1\n'"$GITINIT_BARE_HOME/bare.git"$'\nq\n' "$GITINIT_BARE_HOME/repo")"

it "the config TUI does not offer git init, or reinitialize, a bare repository"
assert_not_contains "$GITINIT_BARE_TUI" "is not a git repository yet"
assert_contains "$GITINIT_BARE_TUI" "existing git repository"
[[ -z "$(find "$GITINIT_BARE_HOME/bare.git" -maxdepth 1 -name '.git')" ]] \
    && ok || fail "a bare repository unexpectedly grew a nested .git"
[[ ! -e "$GITINIT_BARE_HOME/.config/omabackup/env" ]] && ok || fail "the repository setting changed for an ineligible bare repository"

# `git rev-parse --git-dir` only checks ancestors, never descendants: it says
# nothing about a directory that just happens to hold a lot of unrelated
# content and isn't inside any repo at all -- reproduced live against $HOME
# itself, which is not inside a repo despite `~/Devs` being full of them.
# Accepting the offer there would `git init "$HOME"` and let the next sync
# start publishing backup content directly into it. The offer is scoped to an
# empty directory -- its actual use case -- rather than guessing at a
# blocklist of dangerous paths that could never be complete.
GITINIT_NONEMPTY_HOME="$(_cfg_home)"
mkdir -p "$GITINIT_NONEMPTY_HOME/not-empty"
printf 'pre-existing content\n' >"$GITINIT_NONEMPTY_HOME/not-empty/some-file.txt"
GITINIT_NONEMPTY_TUI="$(_cfg_tui_home "$GITINIT_NONEMPTY_HOME" $'1\n'"$GITINIT_NONEMPTY_HOME/not-empty"$'\nq\n' "$GITINIT_NONEMPTY_HOME/repo")"

it "the config TUI does not offer git init for a non-empty directory that merely isn't inside a repo"
assert_not_contains "$GITINIT_NONEMPTY_TUI" "is not a git repository yet"
assert_contains "$GITINIT_NONEMPTY_TUI" "existing git repository"
[[ ! -d "$GITINIT_NONEMPTY_HOME/not-empty/.git" ]] && ok || fail "git init ran against a non-empty, unrelated directory"
[[ ! -e "$GITINIT_NONEMPTY_HOME/.config/omabackup/env" ]] && ok || fail "the repository setting changed for a non-empty directory"

# find's default -P policy does not follow a symlink given as its own
# starting argument, while `-d`, `git -C`, and `git init` all do -- reproduced
# live against /bin, a symlink to the non-empty /usr/bin on this machine.
# Without realpath canonicalizing the target once up front, a writable
# symlink to a non-empty, non-git tree passed the emptiness check as though
# it were an empty real directory, then `git init` still followed the link
# and wrote into the real target.
GITINIT_SYMLINK_HOME="$(_cfg_home)"
mkdir -p "$GITINIT_SYMLINK_HOME/real-target"
printf 'pre-existing content\n' >"$GITINIT_SYMLINK_HOME/real-target/some-file.txt"
ln -s "$GITINIT_SYMLINK_HOME/real-target" "$GITINIT_SYMLINK_HOME/link-to-target"
GITINIT_SYMLINK_TUI="$(_cfg_tui_home "$GITINIT_SYMLINK_HOME" $'1\n'"$GITINIT_SYMLINK_HOME/link-to-target"$'\nq\n' "$GITINIT_SYMLINK_HOME/repo")"

it "the config TUI does not offer git init through a symlink to a non-empty directory"
assert_not_contains "$GITINIT_SYMLINK_TUI" "is not a git repository yet"
assert_contains "$GITINIT_SYMLINK_TUI" "existing git repository"
[[ ! -d "$GITINIT_SYMLINK_HOME/real-target/.git" ]] && ok || fail "git init ran against the symlink's real, non-empty target"
[[ ! -e "$GITINIT_SYMLINK_HOME/.config/omabackup/env" ]] && ok || fail "the repository setting changed for a symlink to a non-empty directory"

# find's stderr was discarded and only its stdout emptiness was checked --
# empty stdout because a directory truly has nothing in it, and empty stdout
# because find could not even read the directory (no permission), used to
# look identical. Reproduced live: `find /root -mindepth 1 -maxdepth 1 -print
# -quit 2>/dev/null` prints nothing and exits 1, for exactly this reason. A
# 0300 (write+execute, no read) directory owned by the test process
# reproduces the same shape without needing root: find cannot list it, but
# git init (which only needs write+execute on the parent to create `.git`)
# would have succeeded there under the old, exit-status-blind check.
GITINIT_UNREADABLE_HOME="$(_cfg_home)"
mkdir -p "$GITINIT_UNREADABLE_HOME/unreadable"
printf 'secret\n' >"$GITINIT_UNREADABLE_HOME/unreadable/file.txt"
chmod 0300 "$GITINIT_UNREADABLE_HOME/unreadable"
GITINIT_UNREADABLE_TUI="$(_cfg_tui_home "$GITINIT_UNREADABLE_HOME" $'1\n'"$GITINIT_UNREADABLE_HOME/unreadable"$'\nq\n' "$GITINIT_UNREADABLE_HOME/repo")"
chmod 0700 "$GITINIT_UNREADABLE_HOME/unreadable"

it "the config TUI refuses git init on a directory it cannot read, instead of treating the read failure as empty"
assert_not_contains "$GITINIT_UNREADABLE_TUI" "is not a git repository yet"
assert_contains "$GITINIT_UNREADABLE_TUI" "existing git repository"
[[ ! -d "$GITINIT_UNREADABLE_HOME/unreadable/.git" ]] && ok || fail "git init ran against a directory find could not read"

# _config_repo_init_eligible is called twice by the TUI on purpose: once
# before the prompt, and again immediately before `git init`. The prompt
# blocks on user input for as long as it takes to answer, an arbitrary window
# for the target to stop being empty -- this pins the primitive both call
# sites depend on: eligible while empty, ineligible the moment it is not.
GITINIT_RACE_DIR="$(mktemp -d)"
GITINIT_RACE_BEFORE=1
bash -c 'source lib/config.sh; _config_repo_init_eligible "$1"' _ "$GITINIT_RACE_DIR" >/dev/null 2>&1 \
    || GITINIT_RACE_BEFORE=0
printf 'appeared during the prompt\n' >"$GITINIT_RACE_DIR/late-file.txt"
GITINIT_RACE_AFTER=1
bash -c 'source lib/config.sh; _config_repo_init_eligible "$1"' _ "$GITINIT_RACE_DIR" >/dev/null 2>&1 \
    || GITINIT_RACE_AFTER=0

it "_config_repo_init_eligible catches a target that stopped being empty between two calls"
[[ $GITINIT_RACE_BEFORE -eq 1 && $GITINIT_RACE_AFTER -eq 0 ]] \
    && ok || fail "the eligibility check did not react to the directory changing between calls (before=$GITINIT_RACE_BEFORE after=$GITINIT_RACE_AFTER)"

GITINIT_DECLINE_HOME="$(_cfg_home)"
mkdir -p "$GITINIT_DECLINE_HOME/plain-folder"
GITINIT_DECLINE_TUI="$(_cfg_tui_home "$GITINIT_DECLINE_HOME" $'1\n'"$GITINIT_DECLINE_HOME/plain-folder"$'\nn\nq\n' "$GITINIT_DECLINE_HOME/repo")"

it "declining the git-init offer leaves the folder plain and the configured repository unchanged"
assert_contains "$GITINIT_DECLINE_TUI" "is not a git repository yet"
assert_contains "$GITINIT_DECLINE_TUI" "existing git repository"
[[ ! -d "$GITINIT_DECLINE_HOME/plain-folder/.git" ]] && ok || fail "git init ran even though the offer was declined"
[[ ! -e "$GITINIT_DECLINE_HOME/.config/omabackup/env" ]] && ok || fail "the repository setting changed despite declining git init"

# `-d "$path/.git"` (the original guard) is wrong in both directions: a linked
# worktree's `.git` is a FILE, not a directory, so the guard could not tell it
# apart from a plain folder -- the offer would fire, `git init` would just
# reinitialize the existing repo and return 0, and the notice would claim
# "Initialized an empty git repository" right next to config-set-repo's real
# "must point at an existing git repository" failure. `git rev-parse
# --git-dir` is what actually answers "is this already a repo".
GITINIT_WORKTREE_HOME="$(_cfg_home)"
git -C "$GITINIT_WORKTREE_HOME/repo" commit -q --allow-empty -m init
git -C "$GITINIT_WORKTREE_HOME/repo" worktree add -q "$GITINIT_WORKTREE_HOME/wt" -b wt-branch
GITINIT_WORKTREE_TUI="$(_cfg_tui_home "$GITINIT_WORKTREE_HOME" $'1\n'"$GITINIT_WORKTREE_HOME/wt"$'\nq\n' "$GITINIT_WORKTREE_HOME/repo")"

it "the config TUI does not offer git init for a linked worktree, whose .git is a file"
assert_not_contains "$GITINIT_WORKTREE_TUI" "is not a git repository yet"
assert_contains "$GITINIT_WORKTREE_TUI" "existing git repository"
[[ ! -e "$GITINIT_WORKTREE_HOME/.config/omabackup/env" ]] && ok || fail "the repository setting changed for an ineligible worktree"

# The same wrong guard also missed the opposite failure mode: a folder that is
# merely a SUBdirectory of an existing repository has no `.git` of its own
# either, so the old guard would offer to init it, `git init` would nest a
# second repository inside the first, and config-set-repo would then *accept*
# that nested repo with no error at all -- a silently wrong, origin-less
# OMABACKUP_REPO instead of the honest failure this asserts.
GITINIT_NESTED_HOME="$(_cfg_home)"
git -C "$GITINIT_NESTED_HOME/repo" commit -q --allow-empty -m init
mkdir -p "$GITINIT_NESTED_HOME/repo/sub"
GITINIT_NESTED_TUI="$(_cfg_tui_home "$GITINIT_NESTED_HOME" $'1\n'"$GITINIT_NESTED_HOME/repo/sub"$'\nq\n' "$GITINIT_NESTED_HOME/repo")"

it "the config TUI does not offer git init, or nest a repo, inside an existing repository"
assert_not_contains "$GITINIT_NESTED_TUI" "is not a git repository yet"
assert_contains "$GITINIT_NESTED_TUI" "existing git repository"
[[ ! -d "$GITINIT_NESTED_HOME/repo/sub/.git" ]] && ok || fail "git init created a nested repository inside an existing one"
[[ ! -e "$GITINIT_NESTED_HOME/.config/omabackup/env" ]] && ok || fail "the repository setting silently accepted a nested repo"

NO_REPO_HOME="$(_cfg_home)"
NO_REPO_TUI="$(_cfg_tui_home "$NO_REPO_HOME" $'q\n' '')"

it "shows explicit friendly values when repository and folders are not configured"
assert_contains "$NO_REPO_TUI" "Backup repository: Not configured"
assert_contains "$NO_REPO_TUI" "Backup folders: Not configured"
assert_contains "$NO_REPO_TUI" "Backup schedule:"
assert_contains "$NO_REPO_TUI" "Send schedule:"
assert_contains "$NO_REPO_TUI" "Automatic backups:"
assert_not_contains "$NO_REPO_TUI" "repo:"

INVALID_TUI="$(_cfg_tui $'\nq\n')"
OUT_OF_RANGE_TUI="$(_cfg_tui $'7\nq\n')"

it "keeps an empty menu choice in the same prompt instead of a dead end"
assert_contains "$INVALID_TUI" "Please choose 1-6 or q."
assert_not_contains "$INVALID_TUI" "Unknown choice"
assert_not_contains "$INVALID_TUI" "Press Enter to continue"
[[ "$(grep -F -o 'Choose an option' <<<"$INVALID_TUI" | wc -l)" -ge 2 ]] \
    && ok || fail "empty input did not return to the menu"

it "explains a numeric menu choice outside the advertised range"
assert_contains "$OUT_OF_RANGE_TUI" "Please choose 1-6 or q."
assert_not_contains "$OUT_OF_RANGE_TUI" "Unknown choice"
[[ "$(grep -F -o 'Choose an option' <<<"$OUT_OF_RANGE_TUI" | wc -l)" -ge 2 ]] \
    && ok || fail "out-of-range input did not return to the menu"

# Escape is an immediate cancel key in a terminal, not a literal line that
# requires Enter. Drive the real config TUI through a PTY and send only ESC;
# this intentionally does not depend on terminal echo or a pre-buffered line.
CFG_ESC_HOME="$(_cfg_home)"
CFG_ESC_LOG="$CFG_ESC_HOME/config-escape.log"
CFG_ESC_FIFO="$CFG_ESC_HOME/config-escape.input"
mkfifo "$CFG_ESC_FIFO"
script -qec "env HOME='$CFG_ESC_HOME' OMABACKUP_ROOT='$PWD' OMABACKUP_GROUPS='$CFG_ESC_HOME/g.json' \
     OMABACKUP_STATE='$CFG_ESC_HOME/.state' OMABACKUP_REPO='$CFG_ESC_HOME/repo' \
     OMABACKUP_DESTINATIONS='$CFG_ESC_HOME/dest.json' OMABACKUP_SYSTEMCTL='$CFG_ESC_HOME/stub/systemctl' \
     XDG_RUNTIME_DIR=/nonexistent '$OB' config" /dev/null \
    <"$CFG_ESC_FIFO" >"$CFG_ESC_LOG" 2>&1 &
CFG_ESC_PID=$!
exec 8>"$CFG_ESC_FIFO"
CFG_ESC_PROMPT=0
for _ in {1..100}; do
    if grep -Fq 'Choose an option' "$CFG_ESC_LOG" 2>/dev/null; then
        CFG_ESC_PROMPT=1
        break
    fi
    /usr/bin/sleep 0.05
done
CFG_ESC_WRITE=0
if (( CFG_ESC_PROMPT )); then
    printf '\033' >&8 && CFG_ESC_WRITE=1
fi
exec 8>&-
CFG_ESC_RC=124
for _ in {1..100}; do
    if ! kill -0 "$CFG_ESC_PID" >/dev/null 2>&1; then
        wait "$CFG_ESC_PID" >/dev/null 2>&1; CFG_ESC_RC=$?
        break
    fi
    /usr/bin/sleep 0.05
done
if kill -0 "$CFG_ESC_PID" >/dev/null 2>&1; then
    kill -TERM "$CFG_ESC_PID" >/dev/null 2>&1 || true
    /usr/bin/sleep 0.1
    kill -KILL "$CFG_ESC_PID" >/dev/null 2>&1 || true
    wait "$CFG_ESC_PID" >/dev/null 2>&1 || true
fi

it "Escape cancels the Config TUI immediately in a real terminal"
[[ $CFG_ESC_PROMPT -eq 1 && $CFG_ESC_WRITE -eq 1 && $CFG_ESC_RC -eq 0 ]] \
    && ok || fail "Config did not exit cleanly after the immediate Escape key"
assert_contains "$(cat "$CFG_ESC_LOG" 2>/dev/null)" "Configuration cancelled"

# Escape begins cursor/function-key sequences too. A real arrow must be
# ignored by the line reader, not mistaken for the immediate-cancel key.
CFG_ARROW_HOME="$(_cfg_home)"
CFG_ARROW_LOG="$CFG_ARROW_HOME/config-arrow.log"
CFG_ARROW_FIFO="$CFG_ARROW_HOME/config-arrow.input"
mkfifo "$CFG_ARROW_FIFO"
script -qec "env HOME='$CFG_ARROW_HOME' OMABACKUP_ROOT='$PWD' OMABACKUP_GROUPS='$CFG_ARROW_HOME/g.json' \
     OMABACKUP_STATE='$CFG_ARROW_HOME/.state' OMABACKUP_REPO='$CFG_ARROW_HOME/repo' \
     OMABACKUP_DESTINATIONS='$CFG_ARROW_HOME/dest.json' OMABACKUP_SYSTEMCTL='$CFG_ARROW_HOME/stub/systemctl' \
     XDG_RUNTIME_DIR=/nonexistent '$OB' config" /dev/null \
    <"$CFG_ARROW_FIFO" >"$CFG_ARROW_LOG" 2>&1 &
CFG_ARROW_PID=$!
exec 8>"$CFG_ARROW_FIFO"
CFG_ARROW_PROMPT=0
for _ in {1..100}; do
    if grep -Fq 'Choose an option' "$CFG_ARROW_LOG" 2>/dev/null; then
        CFG_ARROW_PROMPT=1
        break
    fi
    /usr/bin/sleep 0.05
done
CFG_ARROW_WRITE=0
if (( CFG_ARROW_PROMPT )); then
    printf '\033[A' >&8 && CFG_ARROW_WRITE=1
    /usr/bin/sleep 0.1
    # A following invalid choice proves the prompt survived the arrow; q then
    # exits the still-live TUI cleanly.
    printf 'x\nq\n' >&8 || true
fi
exec 8>&-
CFG_ARROW_RC=124
for _ in {1..100}; do
    if ! kill -0 "$CFG_ARROW_PID" >/dev/null 2>&1; then
        wait "$CFG_ARROW_PID" >/dev/null 2>&1; CFG_ARROW_RC=$?
        break
    fi
    /usr/bin/sleep 0.05
done
if kill -0 "$CFG_ARROW_PID" >/dev/null 2>&1; then
    kill -TERM "$CFG_ARROW_PID" >/dev/null 2>&1 || true
    /usr/bin/sleep 0.1
    kill -KILL "$CFG_ARROW_PID" >/dev/null 2>&1 || true
    wait "$CFG_ARROW_PID" >/dev/null 2>&1 || true
fi

it "an arrow key does not cancel the Config TUI"
CFG_ARROW_OUT="$(cat "$CFG_ARROW_LOG" 2>/dev/null)"
[[ $CFG_ARROW_PROMPT -eq 1 && $CFG_ARROW_WRITE -eq 1 && $CFG_ARROW_RC -eq 0 ]] \
    && assert_contains "$CFG_ARROW_OUT" "Please choose 1-6 or q." \
    || fail "Config treated an arrow-key sequence as Escape"

# Signals can arrive while the reader owns the terminal. Verify the raw
# termios state is restored before the caller continues, rather than relying
# on the outer shell to notice a broken echo mode later.
CFG_INT_HOME="$(_cfg_home)"
CFG_INT_BEFORE="$CFG_INT_HOME/stty.before"
CFG_INT_AFTER="$CFG_INT_HOME/stty.after"
CFG_INT_PIDFILE="$CFG_INT_HOME/config.pid"
CFG_INT_CMD="$CFG_INT_HOME/run-config"
CFG_INT_LOG="$CFG_INT_HOME/config-signal.log"
CFG_INT_FIFO="$CFG_INT_HOME/config-signal.input"
cat >"$CFG_INT_CMD" <<EOF
#!/bin/bash
stty -g >'$CFG_INT_BEFORE'
'$OB' config <&0 &
child=\$!
printf '%s\\n' "\$child" >'$CFG_INT_PIDFILE'
wait "\$child"
rc=\$?
stty -g >'$CFG_INT_AFTER'
exit "\$rc"
EOF
chmod +x "$CFG_INT_CMD"
mkfifo "$CFG_INT_FIFO"
script -qec "env HOME='$CFG_INT_HOME' OMABACKUP_ROOT='$PWD' OMABACKUP_GROUPS='$CFG_INT_HOME/g.json' \
     OMABACKUP_STATE='$CFG_INT_HOME/.state' OMABACKUP_REPO='$CFG_INT_HOME/repo' \
     OMABACKUP_DESTINATIONS='$CFG_INT_HOME/dest.json' OMABACKUP_SYSTEMCTL='$CFG_INT_HOME/stub/systemctl' \
     XDG_RUNTIME_DIR=/nonexistent '$CFG_INT_CMD'" /dev/null \
    <"$CFG_INT_FIFO" >"$CFG_INT_LOG" 2>&1 &
CFG_INT_SCRIPT_PID=$!
exec 8>"$CFG_INT_FIFO"
CFG_INT_PROMPT=0
for _ in {1..100}; do
    if grep -Fq 'Choose an option' "$CFG_INT_LOG" 2>/dev/null; then
        CFG_INT_PROMPT=1
        break
    fi
    /usr/bin/sleep 0.05
done
CFG_INT_KILLED=0
if (( CFG_INT_PROMPT )) && [[ -s "$CFG_INT_PIDFILE" ]]; then
    kill -TERM "$(cat "$CFG_INT_PIDFILE")" >/dev/null 2>&1 && CFG_INT_KILLED=1
fi
exec 8>&-
CFG_INT_RC=124
for _ in {1..100}; do
    if ! kill -0 "$CFG_INT_SCRIPT_PID" >/dev/null 2>&1; then
        wait "$CFG_INT_SCRIPT_PID" >/dev/null 2>&1; CFG_INT_RC=$?
        break
    fi
    /usr/bin/sleep 0.05
done
if kill -0 "$CFG_INT_SCRIPT_PID" >/dev/null 2>&1; then
    kill -TERM "$CFG_INT_SCRIPT_PID" >/dev/null 2>&1 || true
    /usr/bin/sleep 0.1
    kill -KILL "$CFG_INT_SCRIPT_PID" >/dev/null 2>&1 || true
    wait "$CFG_INT_SCRIPT_PID" >/dev/null 2>&1 || true
fi

it "a signal during Config restores the terminal mode"
CFG_INT_BEFORE_VALUE="$(cat "$CFG_INT_BEFORE" 2>/dev/null || true)"
CFG_INT_AFTER_VALUE="$(cat "$CFG_INT_AFTER" 2>/dev/null || true)"
[[ $CFG_INT_PROMPT -eq 1 && $CFG_INT_KILLED -eq 1 && $CFG_INT_RC -eq 143 \
    && -n "$CFG_INT_BEFORE_VALUE" && "$CFG_INT_BEFORE_VALUE" == "$CFG_INT_AFTER_VALUE" ]] \
    && ok || fail "Config left the PTY in raw/no-echo mode after a signal"

BAD_SCHEDULE_TUI="$(_cfg_tui $'4\n4\n9\nq\nq\n')"

BAD_SCHEDULE_CHOICE_TUI="$(_cfg_tui $'4\n9\nq\nq\n')"

it "keeps an invalid schedule choice in the schedule editor"
assert_contains "$BAD_SCHEDULE_CHOICE_TUI" "Please choose 1-5 or q. Try again."
[[ "$(grep -F -o 'Choose [1-5/q]' <<<"$BAD_SCHEDULE_CHOICE_TUI" | wc -l)" -ge 2 ]] \
    && ok || fail "invalid schedule choice returned to the main menu"

it "keeps an invalid schedule field in the schedule editor"
assert_contains "$BAD_SCHEDULE_TUI" "Day must be from 0 to 7."
assert_not_contains "$BAD_SCHEDULE_TUI" "Press Enter to continue"
[[ "$(grep -F -o 'Day (0 Sunday, 1 Monday, ... 6 Saturday)' <<<"$BAD_SCHEDULE_TUI" | wc -l)" -ge 2 ]] \
    && ok || fail "invalid schedule input did not stay in the schedule editor"

ADD_TUI="$(_cfg_tui $'2\n/tmp/Backup folder\n\nq\n')"

it "the TUI can add a folder without asking the user to invent an id"
AUTO_ID="$(jq -r '.destinations[] | select(.path == "/tmp/Backup folder") | .id' "$CH/dest.json")"
[[ -n "$AUTO_ID" && "$AUTO_ID" != null ]] && ok || fail "the TUI did not generate a destination name"
assert_eq "$(jq -r --arg id "$AUTO_ID" '.destinations[] | select(.id == $id) | .keep' "$CH/dest.json")" "5"
assert_contains "$ADD_TUI" "Keep the N newest backups"
assert_not_contains "$ADD_TUI" "How many previous backups"
assert_not_contains "$ADD_TUI" "Name (optional"

SANITIZE_TUI_HOME="$(_cfg_home)"
SANITIZE_TUI_REPO="\${SANITIZE_TUI_HOME}/repo-"$'\033[31m'
SANITIZE_TUI_PATH="\${SANITIZE_TUI_HOME}/backup-"$'\033[31m'-$'\n'line
jq -n --arg path "$SANITIZE_TUI_PATH" \
    '{schemaVersion:1,destinations:[{id:"unsafe",type:"dir",path:$path,keep:5,enabled:true,note:null}]}' \
    >"$SANITIZE_TUI_HOME/dest.json"
SANITIZE_TUI="$(_cfg_tui_home "$SANITIZE_TUI_HOME" $'q\n' "$SANITIZE_TUI_REPO")"
SANITIZE_TUI_CLEAN="$(printf '%s' "$SANITIZE_TUI" | sed -E $'s/\033\\[2J\033\\[H//g')"

it "sanitizes control characters before Config renders external paths"
assert_not_contains "$SANITIZE_TUI_CLEAN" $'\033'
assert_not_contains "$SANITIZE_TUI_CLEAN" "$SANITIZE_TUI_PATH"

GITHUB_FOLDER_HOME="$(_cfg_home)"
GITHUB_FOLDER_PATH="$GITHUB_FOLDER_HOME/github"
GITHUB_FOLDER_TUI="$(_cfg_tui_home "$GITHUB_FOLDER_HOME" $'2\n'"$GITHUB_FOLDER_PATH"$'\n\nq\n' "$GITHUB_FOLDER_HOME/repo")"

it "auto-names a folder whose basename is github without using the reserved id"
assert_eq "$(jq -r --arg path "$GITHUB_FOLDER_PATH" '[.destinations[] | select(.path == $path)] | length' "$GITHUB_FOLDER_HOME/dest.json")" "1"
assert_eq "$(jq -r --arg path "$GITHUB_FOLDER_PATH" '.destinations[] | select(.path == $path) | .id' "$GITHUB_FOLDER_HOME/dest.json")" "github-2"

OVERFLOW_TUI_HOME="$(_cfg_home)"
printf '{"schemaVersion":1,"destinations":[{"id":"local","type":"dir","path":"%s","keep":5,"enabled":true,"note":null}]}\n' \
    "$OVERFLOW_TUI_HOME/backup" >"$OVERFLOW_TUI_HOME/dest.json"
OVERFLOW_TUI="$(_cfg_tui_home "$OVERFLOW_TUI_HOME" $'3\n18446744073709551617\nq\n' "$OVERFLOW_TUI_HOME/repo")"

it "does not let an oversized folder number wrap to the first entry"
assert_eq "$(jq -r '.destinations | length' "$OVERFLOW_TUI_HOME/dest.json")" "1"
assert_contains "$OVERFLOW_TUI" "No backup folder matches that number."

REMOVE_TUI_HOME="$(_cfg_home)"
REMOVE_TUI_PATH="$REMOVE_TUI_HOME/backup-folder"
printf '{"schemaVersion":1,"destinations":[{"id":"local","type":"dir","path":"%s","keep":5,"enabled":true,"note":null}]}\n' \
    "$REMOVE_TUI_PATH" >"$REMOVE_TUI_HOME/dest.json"
REMOVE_TUI="$(_cfg_tui_home "$REMOVE_TUI_HOME" $'3\n1\nq\n' "$REMOVE_TUI_HOME/repo")"

it "the TUI removal prompt matches the numbered folder list"
assert_contains "$REMOVE_TUI" "Remove which backup folder number?"
assert_not_contains "$REMOVE_TUI" "Remove which number or name?"

it "the TUI removes the selected folder and confirms the result"
assert_eq "$(jq -r '.destinations | length' "$REMOVE_TUI_HOME/dest.json")" "0"
assert_contains "$REMOVE_TUI" "Backup folder removed."

REMOVE_NAME_HOME="$(_cfg_home)"
REMOVE_NAME_PATH="$REMOVE_NAME_HOME/backup-folder"
printf '{"schemaVersion":1,"destinations":[{"id":"local","type":"dir","path":"%s","keep":5,"enabled":true,"note":null}]}\n' \
    "$REMOVE_NAME_PATH" >"$REMOVE_NAME_HOME/dest.json"
REMOVE_NAME_TUI="$(_cfg_tui_home "$REMOVE_NAME_HOME" $'3\nlocal\nq\n' "$REMOVE_NAME_HOME/repo")"

it "the TUI does not accept a hidden destination id in an ordinal prompt"
assert_eq "$(jq -r '.destinations | length' "$REMOVE_NAME_HOME/dest.json")" "1"
assert_contains "$REMOVE_NAME_TUI" "No backup folder matches that number."

BEFORE_DEST="$(cat "$CH/dest.json")"
BAD_RC=0
_cfg_env "$CH" config destination add bad "$CH/nope" 0 >/dev/null 2>&1 || BAD_RC=$?

it "invalid retention is rejected without changing destinations"
[[ $BAD_RC -ne 0 ]] && ok || fail "invalid retention unexpectedly passed"
assert_eq "$(cat "$CH/dest.json")" "$BEFORE_DEST"

HUGE_KEEP_RC=0
_cfg_env "$CH" config destination add huge "$CH/nope" 18446744073709551617 >/dev/null 2>&1 || HUGE_KEEP_RC=$?

it "oversized retention is rejected before Bash arithmetic can wrap"
[[ $HUGE_KEEP_RC -ne 0 ]] && ok || fail "oversized retention unexpectedly passed"
assert_eq "$(cat "$CH/dest.json")" "$BEFORE_DEST"

_cfg_env "$CH" config set sync-schedule 'daily' >/dev/null
_cfg_env "$CH" config set push-schedule 'weekly' >/dev/null

it "timer changes validate through systemd and update only OnCalendar"
assert_contains "$(cat "$CH/.config/systemd/user/omabackup-sync.timer")" "OnCalendar=*-*-* 00:00:00"
assert_contains "$(cat "$CH/.config/systemd/user/omabackup-push.timer")" "OnCalendar=Sun *-*-* 00:00:00"
assert_contains "$(cat "$CH/.config/systemd/user/omabackup-sync.timer")" "Persistent=true"

_cfg_env "$CH" config set sync-schedule '*/15 * * * *' >/dev/null
_cfg_env "$CH" config set push-schedule '30 2 * * *' >/dev/null

_cfg_env "$CH" config set sync-schedule '*/20 * * * *' >/dev/null
# The real CLI asks systemd for the effective schedule. Make this fixture's
# systemctl shim reflect the just-written unit before testing the guided
# default, instead of returning its original hard-coded fifteen-minute value.
{
    printf '#!/bin/bash\n'
    printf 'if [[ "$*" == *TimersCalendar* && "$*" == *sync* ]]; then echo "{ OnCalendar=*:0/20 ; next_elapse=... }"; exit 0; fi\n'
    printf 'if [[ "$*" == *TimersCalendar* && "$*" == *push* ]]; then echo "{ OnCalendar=*-*-* *:00:00 ; next_elapse=... }"; exit 0; fi\n'
    printf 'exit 0\n'
} >"$CH/stub/systemctl"
chmod +x "$CH/stub/systemctl"
DEFAULT_SCHEDULE_TUI="$(_cfg_tui $'4\n1\n\nq\n')"

it "uses the current interval as the guided schedule default"
assert_contains "$(cat "$CH/.config/systemd/user/omabackup-sync.timer")" "OnCalendar=*:0/20"
assert_contains "$DEFAULT_SCHEDULE_TUI" "Every 20 minutes"

# Options 4 and 5 share one code path in cmd_config_tui (`4|5) ... choice==4
# ? sync : push ...`), but only option 4 had ever been driven interactively;
# option 5's own branch (push-schedule, "Send schedule saved.",
# omabackup-push.timer) was only ever reached through the non-interactive
# `config set push-schedule` CLI form. Same asymmetric-coverage shape as the
# tui_read_line and git-init bugs this file's other regressions close.
#
# A dedicated home, not $CH: every test around this one builds on $CH's
# cumulative schedule state (see the crontab/rollback specs further down),
# and driving option 5 interactively here would overwrite
# omabackup-push.timer out from under them.
SEND_SCHEDULE_HOME="$(_cfg_home)"
mkdir -p "$SEND_SCHEDULE_HOME/.config/systemd/user"
# `config set push-schedule` gates on both timer *files* existing
# (lib/config.sh:821 -- "timers are not installed yet" otherwise), not just
# the directory.
printf '[Timer]\nOnCalendar=*:0/15\nPersistent=true\n' >"$SEND_SCHEDULE_HOME/.config/systemd/user/omabackup-sync.timer"
printf '[Timer]\nOnCalendar=hourly\nPersistent=true\n' >"$SEND_SCHEDULE_HOME/.config/systemd/user/omabackup-push.timer"
SEND_SCHEDULE_TUI="$(_cfg_tui_home "$SEND_SCHEDULE_HOME" $'5\n1\n20\n\nq\n' "$SEND_SCHEDULE_HOME/repo")"

it "the Send schedule option (5) actually drives the push timer, not just sync"
assert_contains "$SEND_SCHEDULE_TUI" "Send schedule saved."
assert_contains "$(cat "$SEND_SCHEDULE_HOME/.config/systemd/user/omabackup-push.timer")" "OnCalendar=*:0/20"

{
    printf '#!/bin/bash\n'
    printf 'if [[ "$*" == *TimersCalendar* && "$*" == *sync* ]]; then echo "{ OnCalendar=*:*:00 ; next_elapse=... }"; exit 0; fi\n'
    printf 'if [[ "$*" == *TimersCalendar* && "$*" == *push* ]]; then echo "{ OnCalendar=*-*-* *:00:00 ; next_elapse=... }"; exit 0; fi\n'
    printf 'exit 0\n'
} >"$CH/stub/systemctl"
chmod +x "$CH/stub/systemctl"
EVERY_MINUTE_DEFAULT_TUI="$(_cfg_tui $'4\n1\n\nq\n')"

it "uses one minute as the guided default for an every-minute timer"
assert_contains "$EVERY_MINUTE_DEFAULT_TUI" "Minutes between runs [1]"
_cfg_env "$CH" config set sync-schedule '*/15 * * * *' >/dev/null

_cfg_tui $'4\n1\n20\n\nq\n' >/dev/null

it "the TUI builds a crontab schedule from a frequency choice"
assert_contains "$(cat "$CH/.config/systemd/user/omabackup-sync.timer")" "OnCalendar=*:0/20"
_cfg_env "$CH" config set sync-schedule '*/15 * * * *' >/dev/null

it "accepts crontab schedules and translates them to systemd calendars"
assert_contains "$(cat "$CH/.config/systemd/user/omabackup-sync.timer")" "OnCalendar=*:0/15"
assert_contains "$(cat "$CH/.config/systemd/user/omabackup-push.timer")" "OnCalendar=*-*-* 02:30:00"

it "round-trips the every-minute schedule without losing its meaning"
EVERY_MINUTE_CALENDAR="$(OMABACKUP_ROOT="$PWD" bash -c 'source "$0/lib/schedule.sh"; schedule_cron_to_calendar "* * * * *"' "$PWD")"
assert_eq "$EVERY_MINUTE_CALENDAR" "*:*:00"
assert_eq "$(OMABACKUP_ROOT="$PWD" bash -c 'source "$0/lib/schedule.sh"; schedule_calendar_to_cron "$1"' "$PWD" "$EVERY_MINUTE_CALENDAR")" "* * * * *"
assert_eq "$(OMABACKUP_ROOT="$PWD" bash -c 'source "$0/lib/schedule.sh"; schedule_calendar_to_cron "*:0"' "$PWD")" "0 * * * *"

SCHEDULE_LOSSY_RC=0
SCHEDULE_LOSSY="$(_cfg_env "$CH" config set sync-schedule '0 * 1 * *' 2>/dev/null)" || SCHEDULE_LOSSY_RC=$?

it "rejects a cron restriction that the calendar conversion would lose"
[[ $SCHEDULE_LOSSY_RC -ne 0 ]] && ok || fail "a monthly day restriction was silently changed into an hourly schedule"

it "round-trips supported monthly cron forms without changing their fields"
for ROUNDTRIP_CRON in '0 2 1 * *' '0 2 * 1 *' '0 2 1 1 *'; do
    ROUNDTRIP_CALENDAR="$(OMABACKUP_ROOT="$PWD" bash -c 'source "$0/lib/schedule.sh"; schedule_cron_to_calendar "$1"' "$PWD" "$ROUNDTRIP_CRON")"
    ROUNDTRIP_BACK="$(OMABACKUP_ROOT="$PWD" bash -c 'source "$0/lib/schedule.sh"; schedule_calendar_to_cron "$1"' "$PWD" "$ROUNDTRIP_CALENDAR")"
    assert_eq "$ROUNDTRIP_BACK" "$ROUNDTRIP_CRON"
done

SCHEDULE_OVERFLOW_RC=0
OMABACKUP_ROOT="$PWD" bash -c 'source "$0/lib/schedule.sh"; schedule_cron_to_calendar "$1"' \
    "$PWD" '*/18446744073709551617 * * * *' >/dev/null 2>&1 || SCHEDULE_OVERFLOW_RC=$?

it "rejects oversized schedule numbers instead of arithmetic wrapping"
[[ $SCHEDULE_OVERFLOW_RC -ne 0 ]] && ok || fail "an oversized schedule number was accepted after arithmetic overflow"

RAW_SCHEDULE_RC=0
_cfg_env "$CH" config set sync-schedule '*-*-* *:00/15:00' >/dev/null 2>&1 || RAW_SCHEDULE_RC=$?

it "does not expose the systemd expression as a user-facing schedule"
[[ $RAW_SCHEDULE_RC -ne 0 ]] && ok || fail "raw systemd calendar unexpectedly accepted"
assert_contains "$(cat "$CH/.config/systemd/user/omabackup-sync.timer")" "OnCalendar=*:0/15"

BAD_SCHEDULE_RC=0
_cfg_env "$CH" config set sync-schedule 'this is not a calendar' >/dev/null 2>&1 \
    || BAD_SCHEDULE_RC=$?

it "an invalid calendar never reaches the unit file"
[[ $BAD_SCHEDULE_RC -ne 0 ]] && ok || fail "invalid calendar unexpectedly passed"
assert_contains "$(cat "$CH/.config/systemd/user/omabackup-sync.timer")" "OnCalendar=*:0/15"

VALID_CONFIG="$(_cfg_env "$CH" config validate --json)"

it "config validate reports a valid machine-owned document"
assert_eq "$(printf '%s' "$VALID_CONFIG" | jq -r '.valid')" "true"

printf '%s\n' '{"schemaVersion":1,"destinations":[{"id":"local","type":"dir","path":"/tmp","keep":3,"enabled":true,"note":null,"unexpected":true}]}' >"$CH/dest.json"
INVALID_CONFIG="$(_cfg_env "$CH" config validate --json)"

it "config validate rejects unsupported destination fields"
assert_eq "$(printf '%s' "$INVALID_CONFIG" | jq -r '.valid')" "false"
assert_contains "$(printf '%s' "$INVALID_CONFIG" | jq -r '.errors[]')" "destinations.json is invalid"

printf '%s\n' '{"schemaVersion":999,"destinations":[]}' >"$CH/dest.json"
BAD_VERSION="$(_cfg_env "$CH" config validate --json)"
printf '%s\n' '{"schemaVersion":1,"destinations":[{"id":"same","type":"dir","path":"/tmp/a","keep":1},{"id":"same","type":"dir","path":"/tmp/b","keep":1}]}' >"$CH/dest.json"
BAD_DUPLICATE="$(_cfg_env "$CH" config validate --json)"

it "config validate rejects unsupported versions and duplicate destination ids"
assert_eq "$(printf '%s' "$BAD_VERSION" | jq -r '.valid')" "false"
assert_eq "$(printf '%s' "$BAD_DUPLICATE" | jq -r '.valid')" "false"

printf '%s\n' '{"schemaVersion":1,"destinations":[{"id":"local","type":"dir","path":"/tmp","keep":3,"enabled":true,"note":null}]}' >"$CH/dest.json"
REMOVE_RC=0
_cfg_env "$CH" config destination remove missing >/dev/null 2>&1 || REMOVE_RC=$?

it "destination remove rejects an unknown id without changing the document"
[[ $REMOVE_RC -ne 0 ]] && ok || fail "removing an unknown destination unexpectedly passed"
assert_eq "$(jq -r '.destinations[0].id' "$CH/dest.json")" "local"

GITHUB_RC=0
_cfg_env "$CH" config destination add github "$CH/github" 2 >/dev/null 2>&1 || GITHUB_RC=$?

it "destination add rejects the reserved github id"
[[ $GITHUB_RC -ne 0 ]] && ok || fail "reserved github destination unexpectedly passed"

printf '%s\n' 'OnCalendar=not a calendar' >"$CH/.config/systemd/user/omabackup-sync.timer"
BAD_FILE_SCHEDULE="$(_cfg_env "$CH" config validate --json)"

it "config validate reads timer files instead of trusting stale systemd state"
assert_eq "$(printf '%s' "$BAD_FILE_SCHEDULE" | jq -r '.valid')" "false"

printf '%s\n' '{"schemaVersion":1,"destinations":[{"id":"local","type":"dir","path":"/tmp","keep":3,"enabled":true,"note":null}]}' >"$CH/dest.json"
cat >"$CH/.config/systemd/user/omabackup-sync.timer" <<'UNIT'
[Timer]
OnCalendar=daily
Persistent=true
UNIT
BEFORE_TIMER="$(cat "$CH/.config/systemd/user/omabackup-sync.timer")"
printf '#!/bin/bash\nif [[ "$*" == *try-restart* ]]; then exit 1; fi\nexit 0\n' >"$CH/stub/systemctl"
chmod +x "$CH/stub/systemctl"
ROLLBACK_RC=0
_cfg_env "$CH" config set sync-schedule 'hourly' >/dev/null 2>&1 || ROLLBACK_RC=$?

it "a failed timer reload restores the previous schedule"
[[ $ROLLBACK_RC -ne 0 ]] && ok || fail "timer reload failure unexpectedly passed"
assert_eq "$(cat "$CH/.config/systemd/user/omabackup-sync.timer")" "$BEFORE_TIMER"

# tui_read_line's own accumulator used to be named "value" too, so a caller
# reading into a variable literally called "value" (options 1 and 6, the only
# two that did) had its answer silently swallowed by bash's local shadowing:
# the caller's "value" stayed unset and the next `[[ "$value" == ...]]` died
# with "unbound variable" the first time either prompt was actually driven
# interactively. Neither had a regression until now.
#
# Absence of "unbound variable" alone is a weak witness here: a broken fix
# that read the answer but then discarded it would pass that check too. This
# installs real timer units (cmd_enable's own `[[ -d "$UNIT_DIR" ]]` gate) and
# a systemctl stub that logs its argv, so the assertion is the actual effect
# -- systemctl was told to disable --now the real timer units -- not just
# text that happened to reach the terminal.
ENABLE_TOGGLE_HOME="$(_cfg_home)"
mkdir -p "$ENABLE_TOGGLE_HOME/.config/systemd/user"
ENABLE_TOGGLE_LOG="$ENABLE_TOGGLE_HOME/systemctl-call.log"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s"\nexit 0\n' "$ENABLE_TOGGLE_LOG" >"$ENABLE_TOGGLE_HOME/stub/systemctl"
chmod +x "$ENABLE_TOGGLE_HOME/stub/systemctl"
ENABLE_TOGGLE_TUI="$(_cfg_tui_home "$ENABLE_TOGGLE_HOME" $'6\noff\nq\n' "$ENABLE_TOGGLE_HOME/repo")"

it "the Automatic backups prompt reads its answer and actually disables the real timer units"
assert_not_contains "$ENABLE_TOGGLE_TUI" "unbound variable"
assert_not_contains "$ENABLE_TOGGLE_TUI" "timers are not installed"
assert_contains "$ENABLE_TOGGLE_TUI" "Automatic backups disabled."
assert_contains "$(cat "$ENABLE_TOGGLE_LOG" 2>/dev/null)" "--user disable --now omabackup-sync.timer omabackup-push.timer"

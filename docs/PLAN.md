# OmaBackup — plan and status

The living document. `CONTEXT.md` is the incident that started this;
`DESIGN.md` is the architecture and the review that reshaped it twice; this
file is where we are right now and what comes next. Update it at the end of
a work session, especially before switching agent or tool (Claude Code,
Codex, a fresh terminal, another machine) — it is what lets a cold session,
regardless of which coding agent is reading it, pick up where the last one
left off. Read this file first, in full, before touching any code.

Last updated: 2026-08-24.

---

## Roadmap

| # | Stage | Status |
|---|-------|--------|
| 0 | Fix `sync.sh`'s plugin-capture bugs in `omarchy-personal` (regression specs first) | **done** |
| 1 | `omabackup` repo created; group manifest; `collect`; `verify` (T1 coverage) | **done** |
| 2 | Normalized diff, `sync` (collect → publish → verify → commit), destinations, systemd timer | **done** |
| 3 | T3 — fast syntax/parse check in a disposable container | not started |
| 4 | `restore` with the version-coupling quarantine (§12.2 of DESIGN.md) | not started |
| 5 | QML plugin (`Panel.qml`) reading `verify --json` | **done**, installed live |
| 6 | T4 — visual restore check in a VM (QMP screendump) | not started |

Stages don't have to land in this order — 5 landed before 2 on purpose, to
prove the whole pipe works end to end (CLI → JSON → QML → the real bar) before
building out the destinations. That bet paid off: it caught a live-shell
install path issue (the manifest needed one `bar-widget` kind, not three) and
proved the isolated test harness actually isolates.

---

## Where things stand right now

### Repos

- **`~/Devs/omabackup`** (this repo) — public, GitHub, code only: the CLI, the
  QML plugin, the group manifest, the docs. `git log`: `626a40d` → `2cf9bd1` →
  `f4f3466` → `3c705d5` → `d7f63dc` → `6713239` → `741be00` → `8a329fa` →
  `e6db1c1` → … → `acc9c17` → `30532dd` → `d5e9751` → `58e3bbb` → `bedeea1` →
  `f0732db` → `b3e29d3` → `ed08571`, all pushed. 169 specs.
- **`~/Devs/omarchy-personal`** — private, GitHub, the user's actual dotfiles.
  This is `OMABACKUP_REPO`: where `sync` publishes staged content. It is NOT
  where OmaBackup's own code lives — never put backup *data* in the public
  repo, never put OmaBackup *code* in the private one.

### Stage 2 is committed, then corrected

`d7f63dc` landed the stage-2 work. Two rounds of review — Codex via the agent
relay, each finding verified and reproduced here before being fixed — turned up
**fifteen** defects, across five fix commits: `6713239` (collect/publish),
`741be00` (the sync flow), `8a329fa` (the excluded list), `e6db1c1` (paths the
destination repo ignores), `6aa8008` (the second review's seven). 81 specs pass.
See "What the reviews found" below; the short version is that `d7f63dc`'s own
commit message described a flow that could not execute, and that fixing each
silent failure is what exposed the next one.

### The first real `sync --commit` has happened

`omarchy-personal` is at `2d8e526 omabackup: sync 2026-08-24 13:29 UTC`, pushed,
working tree clean. 12 files: shell.json (the bar widget from stage 5), the
package and systemd lists, the plugin manifest, and four JSON files whose only
change is `jq -S` key order — a one-time cost, since both sides are normalized
from here on.

**The ceremony is over.** Later runs are ordinary `sync.sh`-style updates and do
not need a human gate the way that first one did.

Two things that deliberately did *not* go in, both correct:

- `configs/nvim/lazy-lock.json` — the manifest excludes it, and as of `8a329fa`
  the exclusion actually works. It is still *tracked* in `omarchy-personal` from
  the sync.sh era, so it sits frozen at its old committed state. Open question:
  `git rm --cached` it, or leave the stale snapshot?
- Three files under `configs/opencode/` the destination repo ignores — see
  defect 8. They are a real coverage hole, now reported as a warning on every
  sync rather than skipped in silence.

### Destinations: `bundle` and `push` exist, `gdrive` was cut

`ab5d352` built `omabackup bundle`: `git bundle --all HEAD` + `git archive
HEAD` (never the working tree — measured 1.0MB against 66MB, the difference
being untracked caches) + the tool itself + a self-sufficient `manifest.json`,
content-addressed by HEAD, self-verified by extracting and cloning offline on
every build. 416KB on this machine. `acc9c17` built `push`: destinations
config outside the repo (`~/.config/omabackup/destinations.json`, machine
identity, not project data), per-destination state with epoch-based backoff,
five-rule retention (the sharpest one: refuses to prune any directory missing
an `.omabackup-destination` stamp), and — the gap that mattered most — an
actual `git push`. There had never been one; every push this project made,
including several in this session, was typed by hand.

**`gdrive` as an API-backed destination was cut, not deferred.** DESIGN.md §3
originally listed `rclone copy` to a Drive remote as its own destination type.
Decided against: which storage a backup ends up on beyond git — pendrive,
external disk, NAS, a Drive/Dropbox folder someone else's daemon syncs — is not
this tool's decision to make, and chasing every cloud provider's API is not a
fight worth having. The OS already presents all of those as a path. `dir` is
the one destination type, and it is enough: `push` writes bytes to a path over
the filesystem, the same way regardless of what is mounted there, never over a
network API. A "removable drive" trigger is not a new type either — it is a
`dir` destination whose path is a mount point, fired by udev instead of the
timer. DESIGN.md §1, §3, §4 and §11.4 updated to match.

### What the reviews found (read before touching `sync`)

Fifteen defects, all reproduced before being fixed, all now covered by specs.
The lesson worth carrying: the suite was **40/40 green** the whole time, because
it exercised `publish_staging` as a shell function and never the command a human
types. `test/sync.test.sh` exists so that cannot happen again — every spec in
it drives the CLI the way the systemd timer will.

Read the ordering as a chain, not a list. Defects 7 and 8 were not in the first
review: 7 came from reading the diff the corrected tool produced, 8 from defect
5's error checking turning a long silence into a hard stop on the very first
real `--commit`. Defects 9–15 came from a *second* review of the first four fix
commits. Fixing a silent failure is how you find the next one.

And defect 9 is the one to remember: the fix for defect 4 was incomplete in
exactly the way defect 4 itself was, and **the spec written alongside it is what
hid that** — it edited the working tree but never staged, so it passed while
proving nothing. A green spec that does not exercise the real path is worse than
no spec, because it stops anyone from looking.

1. **`--commit` was unreachable, twice over.** The global flag loop killed it
   as an unknown flag; and even past that, the loop `shift`ed every argument
   away, so `cmd_sync "${1:-}"` always received an empty string. The commit
   branch had never once executed. Fixed with a two-level parser: the global
   loop owns only `--json`/`--groups`/`--help` and hands the rest, in order, to
   the command, which owns its own flags. `restore` will need the same shape.
2. **The `scripts` group was collected and then silently dropped.**
   `map_to_repo` refused `.local/bin`/`bin` with a comment claiming collect had
   already written them into the repo — it had not; collect only ever writes
   into staging. The manifest already declared the destinations as
   `trackedRepoPath`; publish now reads that table instead of duplicating one
   entry and refusing the rest.
3. **`verify` never ran on a plain `sync`.** It sat inside the `--commit`
   branch, behind the clean-tree early return — so with defect 1, it had never
   run as part of a sync at all. It now runs on every sync, once, after publish
   and before any commit decision, and a coverage failure exits non-zero even
   without `--commit`. The timer runs with no audience: broken coverage has to
   become a failed unit, not a green backup nobody reads.
4. **`git add -A`** would have swept a human's mid-review edits into a commit
   labelled `omabackup: sync`. `publish_staging` now records exactly the files
   it wrote, and both the dirty check and `git add` are scoped to that list.
5. **No git call was checked.** The script runs `set -uo pipefail` without
   `-e`, so a failed `commit` fell straight through to printing `committed` —
   the one message a backup tool must never print falsely.
6. **"Tracked" meant "present in the directory"** (`find`), not tracked by git.
   Junk in the repo directory pulled its live counterpart in and then
   perpetuated itself. It asks `git ls-files` now, and refuses to guess outside
   a git worktree rather than falling back to the listing.
7. **The manifest-wide `excluded` list never reached rsync.** Its entries are
   full paths (`~/.config/nvim/lazy-lock.json`) and were handed over with only
   the leading `~/` stripped — but rsync matches against the transfer root, so
   under a root of `~/.config/nvim` the pattern `.config/nvim/lazy-lock.json`
   matched nothing. The file the manifest calls "constant diff noise" was backed
   up on every run. A group's own relative `exclude` patterns always worked,
   which is why this hid. Patterns are now built per path, relative to the root
   and anchored.
8. **A path the destination repo ignores was silently never stored.**
   `git add -A` skipped ignored paths without a word. On this machine that is
   three files under `configs/opencode/` — and the loop is worth remembering:
   `~/.config/opencode/.gitignore` is itself backed up, landing inside the
   dotfiles repo where its rules then ignore its own siblings, including the
   copy of itself. Backing the file up is what stops it being stored. They are
   now dropped from the commit *and reported*, never `git add -f`: the
   .gitignore is the user's, and a backup tool does not overrule it. Files the
   repo already tracks are exempt, since ignore rules do not apply to them —
   there is a spec for that specifically.

From the second review (`6aa8008`), on the fixes above:

9. **`git commit` still committed the whole index.** Scoping `git add` was half
   the job: a bare `git commit` commits everything staged, so work the user had
   already `git add`ed rode along under this tool's message. Both calls carry
   the pathspec now. See the note above about the spec that hid this.
10. **`git status`'s exit code was never checked.** A git that fails prints
    nothing, and empty output looks exactly like a clean tree — so any failure
    became "up to date" and exit 0. Specs use a `git` shim that fails on one
    subcommand; it is the only way to make git fail deterministically.
11. **`publish_staging` swallowed write failures** and still ended on its
    success `printf`. It counts them, returns non-zero, and `sync` refuses to
    commit a partial backup.
12. **`--groups` with no value hung the process forever.** `shift 2` with one
    argument left fails, so `$#` never reached zero. It also swallowed the next
    flag as its value, losing `--commit` from `sync --groups --commit`.
13. **`git ls-files` without `-z`** quotes non-ASCII names, so a tracked
    `ação.sh` came back as `"scripts/local-bin/a\303\247\303\243o.sh"` and
    silently stopped being backed up. Not hypothetical in this home directory.
14. **A path both declared and `excluded` was collected in full** — pattern
    translation only covered descendants of the transfer root, so naming the
    root itself was resolved silently in favour of copying.
15. **`find` without `-print0`** in `publish_staging` split a filename
    containing a newline into two paths.

### Bugs found and fixed in the stage-2 pass itself (read before touching `publish_staging`)

1. **Staging must be wiped every `collect`, not accumulated.** The desktop
   group's first (buggy) version staged 63 stray files — every `.desktop`,
   icon `.png`, and `mimeinfo.cache` under `~/.local/share/applications`, not
   just the ones already tracked. Fixing the bug in `map_to_repo` alone was
   not enough: the stale files were still sitting in
   `~/.local/state/omabackup/staging` from the earlier run and `publish`
   dutifully republished them. `cmd_collect` now does `rm -rf "$STAGING"`
   before rebuilding it. Staging represents "what should be backed up right
   now", not a cache.
2. **`trackedOnly` is a per-*path* decision, not a per-*group* one.** The
   `desktop` group mixes a directory that should only pull already-tracked
   names (`~/.local/share/applications`) with plain files that should always
   copy (`mimeapps.list`, `user-dirs.dirs`). A group-level flag broke the
   plain files. Fixed by letting a `paths[]` entry be either a bare string or
   `{"live": "...", "trackedRepoPath": "..."}`; `trackedRepoPath` is what
   `collect_tracked_only` checks membership against, replacing the earlier
   (wrong) assumption that it should be `$OMABACKUP_REPO`'s top level.

### The live plugin install

`brenoperucchi.omabackup` is installed at
`~/.config/omarchy/plugins/brenoperucchi.omabackup/` (via
`omarchy plugin add https://github.com/brenoperucchi/omabackup.git --enable --yes`)
and added to the bar (`omarchy bar move brenoperucchi.omabackup right`). It
resolves the CLI from that same directory's `bin/omabackup` and currently
reports "covered" against this machine. **After pushing a code change here,
reinstalling means re-cloning** — there is no symlink between this working
copy and the installed one. For iteration, prefer the isolated harness (next
section) and only reinstall (`omarchy plugin remove` +
`omarchy plugin add ... --yes`, or `git -C ~/.config/omarchy/plugins/brenoperucchi.omabackup pull`)
when you actually need to see it live.

### The isolated QML test harness

A scratch directory (currently under `/tmp/.../scratchpad/qsharness`, not
checked in) that symlinks `Ui/` and `Commons/` from
`/usr/share/omarchy/shell/` and loads `Panel.qml` behind a stub `bar` object,
run as its own `quickshell -n -p <dir>` process. It exists so QML can be
tested without ever touching the live shell — a QML error can take the whole
`quickshell` process down (bar, dock, menu at once), which is exactly the
failure this harness is built to keep off the real desktop. One did crash
during testing (see DESIGN.md §14): the harness process died, the live shell
never noticed. If it is gone when a new session starts, recreate it — it is
cheap and disposable, not worth version-controlling.

---

### It runs by itself now

Both timers are live on this machine: `omabackup-sync` every 15 min
(`sync --commit`), `omabackup-push` hourly. Installed with `omabackup install`,
which is the one manual step that exists and cannot be removed — `omarchy plugin
add` runs no hook from a plugin, deliberately, so the timers can never install
themselves. Which is exactly why *not* being scheduled is a reported state:
`verify` warns `nothing is scheduled to run the backup` and `status --json`
carries `.scheduler.active`. A backup nothing runs is a backup that does not
happen, and that must never be silent.

Measuring to pick the interval paid for itself twice: `sync` took **33.6s**,
of which publish was 27 — one `rsync` spawn per staged file, ~44ms each against
`cp`'s 0.5ms. Now 4.3s. And the same measurement exposed that publish walked
staging with `find -type f`, which excludes symlinks, so every staged link had
been dropped in silence since the beginning.

## Immediate next actions

1. **The secret scanner (DESIGN.md §6).** Agreed as defence in depth rather
   than a gate, but it is now the only thing between an unattended hourly push
   and a credential that lands in a config file. The `secrets` group is
   `enabled: false`, so nothing collects credentials on purpose — the risk is a
   token pasted into something already covered.
2. **Configure a real `dir` destination**, once there is an actual path to name
   (external disk, NAS mount, a Drive folder synced by something else).
   `~/.config/omabackup/destinations.json` is deliberately still absent: there
   is no path to point it at that would not be invented. `github` works and
   runs hourly meanwhile.
3. **Removable-drive trigger.** A udev rule calling `omabackup push <id>` when a
   `dir` destination's mount point appears (DESIGN.md §4.4). Not a new
   destination type.
4. Expand `Panel.qml` to show destinations and the schedule — `status --json`
   already carries both `destinations` and `scheduler` for it to read.

## Open questions for the user, not yet decided

- What path should the first `dir` destination actually point at?
- Should the systemd timer auto-commit (`sync --commit` unattended) or only
  auto-collect-and-diff, leaving commit to a manual action/keypress until
  there is more trust in the pipeline? Same question now applies to `push`
  separately, since it runs on its own timer.
- `omabackup`'s two oldest commit messages are in Portuguese (the rest of the
  repo was translated retroactively). Rewriting history is now a worse deal
  than it was: the installed plugin is a clone of this branch and pulls from
  it, so a force-push breaks it for zero gain. Leaning toward leaving them as a
  record of how the project started.
- `configs/nvim/lazy-lock.json` is excluded by the manifest but still tracked
  in `omarchy-personal` from the sync.sh era, frozen at a stale state.
  `git rm --cached` it, or keep the old snapshot?
- The three `configs/opencode/` files the repo ignores: adjust that
  `.gitignore` so the backup can store them, accept the hole and let the
  warning stand, or declare them excluded so the warning stops being noise?

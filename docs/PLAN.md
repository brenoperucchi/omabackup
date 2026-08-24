# OmaBackup — plan and status

The living document. `CONTEXT.md` is the incident that started this;
`DESIGN.md` is the architecture and the review that reshaped it twice; this
file is where we are right now and what comes next. Update it at the end of
a work session, especially before switching to a fresh Claude Code session
rooted in this directory — it is what lets that session pick up cold.

Last updated: 2026-08-24.

---

## Roadmap

| # | Stage | Status |
|---|-------|--------|
| 0 | Fix `sync.sh`'s plugin-capture bugs in `omarchy-personal` (regression specs first) | **done** |
| 1 | `omabackup` repo created; group manifest; `collect`; `verify` (T1 coverage) | **done** |
| 2 | Normalized diff, `sync` (collect → publish → verify → commit), destinations, systemd timer | **in progress** |
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
  `e6db1c1`, all pushed. 67 specs.
- **`~/Devs/omarchy-personal`** — private, GitHub, the user's actual dotfiles.
  This is `OMABACKUP_REPO`: where `sync` publishes staged content. It is NOT
  where OmaBackup's own code lives — never put backup *data* in the public
  repo, never put OmaBackup *code* in the private one.

### Stage 2 is committed, then corrected

`d7f63dc` landed the stage-2 work. Reviewing that commit — Codex via the agent
relay, then verified line by line and reproduced here — found **eight** defects
in it, fixed across four commits: `6713239` (collect/publish), `741be00` (the
sync flow), `8a329fa` (the excluded list), `e6db1c1` (paths the destination repo
ignores). 67 specs pass. See "What the review found" below; the short version is
that `d7f63dc`'s own commit message described a flow that could not execute.

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

### What the review of `d7f63dc` found (read before touching `sync`)

Eight defects, all reproduced before being fixed, all now covered by specs. The
lesson worth carrying: the suite was **40/40 green** the whole time, because it
exercised `publish_staging` as a shell function and never the command a human
types. `test/sync.test.sh` exists so that cannot happen again — every spec in
it drives the CLI the way the systemd timer will.

Defects 7 and 8 were not in the original review. They surfaced *because* of the
first six fixes — 7 from actually reading the diff the corrected tool produced,
8 from defect 5's error checking turning a two-year silence into a hard stop on
the first real `--commit`. Fixing a silent failure is how you find the next one.

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

## Immediate next actions

1. **Reinstall the live plugin.** `~/.config/omarchy/plugins/brenoperucchi.omabackup`
   is a clone pinned at `3c705d5` — five commits behind, so the bar is running
   the CLI from before every fix above. `git -C ... pull` is enough. That pin is
   also what `lists/omarchy-plugins.txt` recorded in `2d8e526`, so the next sync
   after reinstalling will correctly update it.
2. Add the other destinations from DESIGN.md §3 (`rclone` for Drive, a plain
   directory, a removable-drive watcher) — `github` (the git commit itself)
   is the only one that exists so far.
3. Write the systemd user unit + timer that calls `omabackup sync --commit`
   on a schedule, replacing the QML `Timer`'s role as anything more than a
   cheap read-only `verify` poll (DESIGN.md §11.2: the timer must be primary,
   the plugin is just its face). `sync` now exits non-zero on broken coverage,
   so the unit fails visibly instead of reporting a green backup.
4. Only after 1–3: expand `Panel.qml`'s UI to show destinations and the
   schedule, since there would finally be real data for those views to show.

## Open questions for the user, not yet decided

- Which of the four destinations (github/gdrive/dir/removable) beyond GitHub
  should actually be wired up first?
- Should the systemd timer auto-commit (`sync --commit` unattended) or only
  auto-collect-and-diff, leaving commit to a manual action/keypress until
  there is more trust in the pipeline?
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

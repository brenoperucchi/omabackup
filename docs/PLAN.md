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
  `f4f3466` → `3c705d5`, all pushed.
- **`~/Devs/omarchy-personal`** — private, GitHub, the user's actual dotfiles.
  This is `OMABACKUP_REPO`: where `sync` publishes staged content. It is NOT
  where OmaBackup's own code lives — never put backup *data* in the public
  repo, never put OmaBackup *code* in the private one.

### Stage 2 is committed, then corrected

`d7f63dc` landed the stage-2 work. A review of that commit (Codex via the agent
relay, then verified line by line here) found six defects in it, fixed across
two commits: `6713239` (collect/publish) and the one that follows it (the sync
flow). 59 specs pass. See "What the review found" below — the short version is
that `d7f63dc`'s own commit message described a flow that could not execute.

### Pending in `omarchy-personal` — regenerate it, do not review it as it stands

Running `OMABACKUP_REPO=~/Devs/omarchy-personal ./bin/omabackup sync` (no
`--commit`) has already written into that repo's working tree: 13 modified
files, nothing untracked. **Nobody has run `--commit` yet** — nobody *could*,
which is defect 1 below.

That working tree was written by the buggy `publish`, so **do not review it as
the tool's output**. It is missing the entire `scripts` group (defect 2), and
anything it pulled in through a tracked-only path was decided by directory
listing rather than the git index (defect 6). Re-run `sync` with the corrected
code first, then review the diff that produces. Get an explicit go-ahead before
the first real `--commit` through this tool; after that first one, later runs
are just normal `sync.sh`-style updates and don't need the same ceremony.

### What the review of `d7f63dc` found (read before touching `sync`)

Six defects, all reproduced before being fixed, all now covered by specs. The
lesson worth carrying: the suite was **40/40 green** the whole time, because it
exercised `publish_staging` as a shell function and never the command a human
types. `test/sync.test.sh` exists so that cannot happen again — every spec in
it drives the CLI the way the systemd timer will.

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

1. Re-run `sync` against `~/Devs/omarchy-personal` with the corrected code and
   review the diff it produces — the working tree there right now is the buggy
   publish's output, not the tool's. Then get the user's go-ahead, run
   `sync --commit` (which finally works), confirm the commit and push.
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
  repo was translated retroactively). Rewrite history (force-push, low risk
  this early) or leave them as a record of how the project started?

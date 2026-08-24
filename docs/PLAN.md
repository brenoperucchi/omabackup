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

### Uncommitted in `omabackup` (stage 2, in progress)

```
 M bin/omabackup            cmd_sync, per-path trackedOnly, staging wipe fix
 M groups.default.json      desktop/scripts use {live, trackedRepoPath} paths
 M test/collect.test.sh     regressions for the two bugs below
?? lib/publish.sh           staging -> repo mapping (mirrors sync.sh's layout)
?? test/publish.test.sh     16 specs for the mapping
```

40/40 specs pass (`./test/run.sh`). Not yet committed — do that before anything
else in the next session, referencing the two bugs this pass found (below).

### Pending in `omarchy-personal` (needs a human decision, not a next step)

Running `OMABACKUP_REPO=~/Devs/omarchy-personal ./bin/omabackup sync` (no
`--commit`) has already written into that repo's working tree. `git status`
there shows 13 legitimate modified files (shell.json, package lists, systemd
lists, nvim/opencode lockfiles, the plugin manifest with sha pins) and nothing
untracked. **Nobody has run `--commit` yet.** Review that diff with the user
and get an explicit go-ahead before the first real commit through this tool —
after that first one, later runs are just normal `sync.sh`-style updates and
don't need the same ceremony.

### Bugs found and fixed this pass (read before touching `publish_staging`)

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

1. Commit the stage-2 work above (`bin/omabackup`, `groups.default.json`,
   `lib/publish.sh`, the two test files) with a message citing both bugs and
   the specs that caught them.
2. Get the user's go-ahead on the pending `omarchy-personal` diff, run
   `sync --commit`, confirm the commit and push look right.
3. Add the other destinations from DESIGN.md §3 (`rclone` for Drive, a plain
   directory, a removable-drive watcher) — `github` (the git commit itself)
   is the only one that exists so far.
4. Write the systemd user unit + timer that calls `omabackup sync --commit`
   on a schedule, replacing the QML `Timer`'s role as anything more than a
   cheap read-only `verify` poll (DESIGN.md §11.2: the timer must be primary,
   the plugin is just its face).
5. Only after 2–4: expand `Panel.qml`'s UI to show destinations and the
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

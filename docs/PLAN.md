# OmaBackup — plan and status

The living document. `CONTEXT.md` is the incident that started this;
`DESIGN.md` is the architecture and the review that reshaped it twice; this
file is where we are right now and what comes next. Update it at the end of
a work session, especially before switching agent or tool (Claude Code,
Codex, a fresh terminal, another machine) — it is what lets a cold session,
regardless of which coding agent is reading it, pick up where the last one
left off. Read this file first, in full, before touching any code.

Last updated: 2026-08-31.

---

## Roadmap

| # | Stage | Status |
|---|-------|--------|
| 0 | Fix `sync.sh`'s plugin-capture bugs in `omarchy-personal` (regression specs first) | **done** |
| 1 | `omabackup` repo created; group manifest; `collect`; `verify` (T1 coverage) | **done** |
| 2 | Normalized diff, `sync` (collect → publish → verify → commit), destinations, systemd timer | **done** |
| 3 | T3 — fast syntax/parse check in a disposable container | not started |
| 4 | `restore` with the version-coupling quarantine (§12.2 of DESIGN.md) | **done** |
| 5 | QML plugin (`Panel.qml`) — coverage, groups, destinations, schedule | **done**, installed live |
| 6 | T4 — visual restore check in a VM (QMP screendump) | **done**, validated 2026-08-29 |

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
  `f0732db` → … → `2b57015` → `6981927` → … → `2ab0ae1`, all pushed. 254 specs.
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
self-verified by extracting and cloning offline on every build. 416KB on this
machine. Content-addressed at first by HEAD alone; a later round widened the
cache key to HEAD + the tool's own fingerprint + every ref + the manifest's
hash, so a timer firing with nothing new to say — same code, same repo state
— still does no new work, and a tool upgrade with the repo unchanged still
does. `acc9c17` built `push`: destinations
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

### The panel is finished, against the mockup

`Panel.qml` now answers the four questions DESIGN.md §1 asked of it. The mockup
is at https://claude.ai/code/artifact/59338df5-c4d4-4ebc-95dd-e107242ae80c —
worth opening before touching the file, since it is the only place the intended
shape is drawn.

| view | state |
|------|-------|
| verification | the findings list, since stage 5 |
| destinations | `cd70fb4` — id, type, last sent, error/backoff |
| schedule | `cd70fb4` + `ebd4bed` — not scheduled, never run, out of date |
| groups | `2ab0ae1` — label, coverage, mode, coupling |

"Estado do Omarchy" is a group row in the mockup, not a section of its own.

Three of the mockup's seven widget states were deliberately **not** built, and
should stay unbuilt unless the reasoning changes:

- **Com alterações** — its premise died when the commit became automatic. There
  is no longer a window in which uncommitted changes sit waiting for review.
- **Enviando** — transient; the panel polls, it does not watch.
- **Aguardando volume** — needs the removable `dir` destination, which does not
  exist because no path has been named to point it at.

**Pré-upgrade** is missing and is worth building, but it is CLI work rather than
QML: the mockup itself records that `omarchy-update` exposes no pre-update hook,
so only a pacman `PreTransaction` hook arrives before the mutation. §4 calls it
the highest-value item in the product. It competes with `restore`, and `restore`
should win — a pre-upgrade backup nobody can restore is worth less.

The panel also gained a state the mockup never had, because it was discovered
after the mockup was drawn: **not scheduled**. `omarchy plugin add` runs no hook,
so a fresh install has no timers at all.

### Three mistakes this project keeps making

Four review rounds have found 45 defects. Nine of them were introduced *while
fixing* another defect, and they sort into three shapes. They are written down
because recognising the shape is faster than rediscovering the instance.

**1. A fact stated twice.** Every duplicated fact eventually drifts, and the
drift is silent because both copies still look right on their own.

- `map_to_repo` repeated a destination the manifest already declared — the
  whole `scripts` group vanished between staging and the repo.
- `git add` carried the pathspec and `git commit` did not — a scoped add and an
  unscoped commit.
- `_dir_is_ours` and `prune_bundles` each described this tool's own filename —
  adding the short sha to one left the other behind, and retention stopped.
- `Persistent=true` and the comment above it described different behaviour.

The fix is never "update both". It is one definition, referenced twice.

**2. An exit status discarded, so "it failed" and "nothing found" become the
same answer.** Four instances of one mistake, three of them in a security gate:

- `git status` failing read as "up to date", exit 0.
- `git grep` with a bad pattern read as "no secrets".
- `git rev-list` on an unreadable repo read as "no commits", read as clean.
- `jq` on an unreadable deny-list read as "no patterns", read as clean.

Command substitution and `mapfile < <(...)` both throw the status away. Capture
it, or state plainly why not caring is safe.

**3. A green spec that never exercises the real path.** Five times, and the
worst of them hid the defect it was written for:

- The suite was 40/40 while `--commit` could not run at all — it tested
  `publish_staging` as a function and never the command a human types.
- The spec for "unrelated work stays out of the commit" edited the working tree
  and never staged, so it passed against the bug it was written for.
- The stamp spec called `prune_bundles` directly, never through the driver that
  defeated it.
- The quoting spec asserted the string contained quotes instead of asking
  systemd whether it accepted the unit.

Drive the CLI. Ask the real system. And when an assertion could only ever pass,
add the case that makes it fail.

### On reviews

Scope them small. A review asking for six areas at once was killed by the
executor's own 600s turn limit and returned nothing; the same target cut to two
files and six concrete questions came back in four minutes with a defect nobody
here would have found — that `git grep <rev>` reads a commit's tree and never
its message, while `git bundle --all` packs both.

Working through the questions written *for* a review, while it runs, has found
about as much as the reviews themselves.

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

### The deny-list scanner is in (§6 closed)

`secrets.deny.json` (versioned, unlike destinations — secret shapes are generic
and §6 wants the exceptions reviewable) + `lib/secrets.sh`, gating `push` for
every destination including `github`, since the git push carries the same commit
the bundle does. It **blocks**, never warns: §6's reasoning was that a leak is
irreversible and a warning nobody reads is lesson #1, and that got stronger once
push became an unattended hourly timer — there is nobody at 03:00 to read one.

Scanned with `git grep` against HEAD, not the working tree: HEAD is exactly what
both destinations send. Nine patterns, each requiring a `reason` (a rule nobody
can justify is a rule somebody forces past). Half the specs are false-positive
cases — a chromium `--password-store` flag, `hide_token_restore`, a variable
reference, an empty default, age ciphertext — because a scanner that fires on
ordinary config teaches you to reach for `--force`, which is the same failure one
step later. Clean against the real 739-file repo.

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

### Restore exists now

`omabackup restore <artifact.tar.zst>` plans; `--apply` writes. On this machine
the plan is 601 files across ten groups, plus five generated lists it names and
refuses to act on -- restoring a package list means installing software, which
is not a file copy and is not something this tool does on anyone's behalf.

Three things shape it, and all three came out of §12:

- **The artifact's own manifest drives it — with one floor.**
  `tool/groups.default.json` ships inside every bundle for exactly this. A
  restore driven by whatever manifest the machine happens to carry would look
  for groups the artifact never had and place files by rules written after
  it. But an artifact's own `coupled` flag is not trusted DOWNWARD: a later
  review found that an artifact could simply omit `coupled` for a group its
  own `manifest.json` calls coupled — the two are not independent, both
  written by the same build — and restore past quarantine that way. This
  machine's own locally-installed schema, captured before the artifact's copy
  shadows it, is used as a floor: it can push a recognized group's `coupled`
  up to true, never down.
- **The verdict is taken before anything is WRITTEN, and always against THIS
  machine, never `--into`'s target.** This went back and forth: an earlier
  version computed it against `--into`'s target on the reasoning that a
  `--into` restore is "about wherever the restore actually lands," which
  broke the more common use of `--into` worse than the bug it fixed —
  pointing it at an empty scratch directory read as watermark 0, the
  PERMISSIVE case, so previewing what `--apply` would do applied MORE than a
  real restore onto the operator's own machine would have. `version` and
  `channel` are unavoidably the real machine's regardless (`omarchy-version`/
  `omarchy-channel-current` are system commands, not `$HOME`-relative), so
  `--into` was never going to simulate a different Omarchy install, only a
  different destination for one. (The artifact is extracted and verified
  first, which is reading -- the promise is about deciding, not about
  touching disk.) `same` (identical
  watermark: coupled groups and migration markers both apply), `behind`
  (inside the range, this machine has fewer migrations than the backup --
  typically a fresh install with no migrations directory yet: coupled groups
  and markers both apply, matching the schema the config is written for),
  `forward` (inside the range, further along: coupled groups apply, markers do
  not -- `omarchy-migrate` exists to walk that distance), `quarantine`
  (outside the declared range: nothing from the coupled block applies).
  August's failure is refused by construction rather than discovered hours
  later. `behind` is not in DESIGN.md §12.3, which only names `==`, `>`, and
  "outside the range" -- the first version of this file treated `<` as a kind
  of downgrade and quarantined it, which quarantined the PRIMARY recovery
  scenario (new machine, valid backup, same version) with the markers that
  would fix the watermark held inside the very block that got quarantined. A
  second run gave the same verdict forever.
- **Nothing is written unless asked, and what is replaced is kept.** A backup
  that cannot be taken cancels the write. Two restores get separate
  directories -- named by `mktemp` now rather than by the second, since two in
  the same second used to share one and the second would overwrite the
  first's originals in the one place that exists to keep them. A destination
  that resolves outside the target home, once every symlink and `..` in it is
  followed, is refused outright as `escape` -- never written, regardless of
  verdict or group.

`map_to_repo` flattens `trackedRepoPath` groups, so if two declared
directories ever shared a destination, a file there could not be traced home.
Restore detects that and says `ambiguous` instead of guessing, via two
collision maps kept together -- one keyed by repo-side prefix (two groups
naming the same `trackedRepoPath`), one by the expanded live destination (two
DIFFERENT prefixes that both declared the same `live` directory). Neither
subsumes the other: an earlier version had only the first, and lost the
second case -- two distinct repo locations agreeing on one live path printed
as an ordinary `restore` row for the same file, with nothing to catch it. No
group in the shipped manifest triggers either -- `scripts` declares
`~/.local/bin` and `~/bin` with distinct destinations.

### Restore's trust boundary, hardened (2026-08-26/27)

A PoC found `restore` executing an artifact's own embedded `tool/bin/omabackup`
as part of proving it "verifies" -- with the operator's full privileges, in
plan mode, before `--apply`. Full reasoning, the alternatives considered
(sandboxing, signing) and why they were set aside, in DESIGN.md §15. In brief:
restore no longer runs an artifact's embedded binary at all, checked with a
mandatory (no default) `run-embedded` argument threaded through
`_verify_extracted`/`verify_bundle` so a future caller must decide explicitly
rather than inherit a default.

Two independent adversarial review passes on that fix (and each other) then
found, and this session closed, six more:

- A cache-hit reused an artifact from disk without re-proving it, which
  reopened the SAME execution hole through `~/.local/state/omabackup/bundles/`
  instead of a handed-over artifact -- closed with the same `run-embedded`
  parameter, `0` for cache-hit, `1` only for output this exact call just built.
- A tampered CACHED bundle, no longer executed, was still SERVED --
  `verify_bundle`'s data-only checks cannot see a swapped tool with
  recomputed `SHA256SUMS`. Closed with a fifth check specific to cache-hit:
  the cached tool's own fingerprint must match what `$OMABACKUP_ROOT` would
  produce right now.
- `tar -xf <(zstd -dc ...)` discarded zstd's own exit status; a valid frame
  followed by trailing garbage extracted clean. Fixed with a real pipe under
  `pipefail`.
- `groups_ids`/`group_paths` fed a process substitution directly, whose exit
  status is not observable at the `done` that closes it; an unparseable
  manifest read as "nothing to restore" instead of a refusal.
- A missing `coupled` field in the artifact's own bundled schema walked past
  quarantine -- the artifact's `manifest.json` and its `groups.default.json`
  are not independent for an attacker who built both. Fixed with a floor:
  this machine's own installed schema can push a recognized group's `coupled`
  up, never down.
- A non-integer watermark (a stray `junk.sh`, or a manifest field written
  wrong) fell back to `0`, the most PERMISSIVE reading there is. Now refused,
  joining the existing `unreadable` sentinel check, on both the build side and
  the restore side.
- A filename with an embedded tab or newline could inject a second, forged
  TSV row into the plan -- a quarantined file's row split at the newline, and
  the remainder read back as its own `restore` row for the same destination.
  Refused as `escape` at every row-emission site that builds a name from
  `find` output.

Also solved a standing mystery: a commit named just "base" (`142ffb1`) had
appeared on `main`, authored under this repo's own git identity, that nobody
could explain. It was this test suite: dozens of fixtures build a throwaway
repo via `mktemp -d` and then `git -C "$r" commit -qm base` against it, and
`git -C ""` — confirmed directly — does not refuse an empty path, it silently
operates on the CURRENT directory instead. When `mktemp -d` genuinely failed
(the same `/tmp` inode exhaustion already on record above), whatever was
sitting uncommitted in this repo's own working tree got committed for real.
Reproduced a second time, live, while fixing it -- caught before it was ever
pushed. `mktemp` is now overridden as a shell function in `test/run.sh`,
before any spec is sourced, that kills the whole test run (not just its own
subshell -- `exit` alone does not reach past `$(...)`) the moment it fails.

## Immediate next actions

1. **Configure a real `dir` destination**, once there is an actual path to name
   (external disk, NAS mount, a Drive folder synced by something else).
   `~/.config/omabackup/destinations.json` is deliberately still absent: there
   is no path to point it at that would not be invented. `github` works and
   runs hourly meanwhile.
2. **Removable-drive trigger.** A udev rule calling `omabackup push <id>` when a
   `dir` destination's mount point appears (DESIGN.md §4.4). Not a new
   destination type.
3. **T3** (stage 3) remains the next independent verification after the
   configuration surfaces: a syntax check in a disposable container.

### Configuration and the real VM test (design review, 2026-08-29)

Two possible next steps were reviewed after the restore panel was completed:
an editable Settings surface and a real Omarchy/QEMU restore test. They should
remain separate concerns.

The proposed configuration boundary is a CLI-owned `omabackup config` command
with an ANSI/TUI mode for a recovery tty or SSH session. It should validate and
atomically update the existing machine-owned configuration (`env`,
`destinations.json`, and the systemd timer settings), while keeping the public
group manifest and the secret scanner outside the editable settings surface.
The QuickShell panel can later provide a Settings UI by invoking that command
through `Quickshell.Io.Process`; it must not edit those files directly. The
current Config block remains a read-only status summary until that command
exists.

The proposed T4 harness is a persistent, disposable virtual machine: use the
host's QEMU/KVM directly (KVM and OVMF are already available here), build or
refresh one clean golden image, boot a copy-on-write overlay for each run,
forward SSH from QEMU, copy in a real artifact, run `restore --apply` in the
guest, then assert the restored files, Omarchy state, and QuickShell/Hyprland
startup before discarding the overlay. `qcow2` is only the convenient
copy-on-write disk format for that overlay, not a requirement of the test
design. Libvirt, containers, and `systemd-nspawn` remain unnecessary for this
single reproducible graphical-VM workflow; a container can still serve as a
fast CLI-only test later. Reinstalling Omarchy for every run is not part of the
restore test; an optional installer-E2E job can test the ISO or provisioning
path separately. The first manual panel test still happens on the live host,
using a disposable restore target where possible.

### Execution plan: VM first, then configuration surfaces

The order is intentionally based on risk and dependency, not on visual
visibility. The restore path is already implemented but has not yet been
observed end to end on a clean Omarchy. The panel and configuration surfaces
must not become a second source of truth before that path is exercised.

#### 0. Live smoke test — no code

Use the installed panel and a real artifact to walk through overview →
artifacts → target → plan → terminal handoff. First use a disposable target;
record any appearance, scroll, command, or target-selection problem. This is a
human UX check, not a substitute for the VM.

#### 1. T4/QEMU proof of restore — first implementation

Create `test/vm/` with a documented QEMU/KVM runner, a golden Omarchy image,
SSH readiness, artifact transfer, restore execution, assertions, timeout and
cleanup. The normal run boots a copy-on-write overlay and never modifies the
golden image. Its acceptance checks are:

- the guest boots and accepts the test SSH key;
- the real artifact is accepted and `restore --apply` completes;
- expected files and the restore journal exist in the guest;
- the guest's Omarchy state, QuickShell and Hyprland reach the expected state;
- logs and a screenshot are preserved on failure, and the overlay is removed
  after the run.

Creating or refreshing the golden image is a separate, slower operation. An
ISO/installer automation test is optional and must not be coupled to every
restore run.

**Completed 2026-08-29:** the runner and its contract probes now exist in
`test/vm/run.sh`, `test/vm/README.md`, and `test/vm.test.sh`. The runner uses a
strict pinned SSH host key, one absolute deadline, QMP screenshot evidence,
durable restore-journal assertions, archive-aware regular-file/symlink checks,
and live `loginctl`/Wayland/Hyprland checks after SDDM restart. The opt-in
`test/vm/build-golden.sh` follows Omarchy's unattended `cidata` installer
contract to create a fresh unencrypted `qcow2` fixture and provision the SSH
test user. The builder verifies the official ISO checksum, provisions SDDM
autologin, checks the graphical session, powers the guest off cleanly, then
boots the same disk in a fresh QEMU process and repeats the SSH/graphical
checks before accepting it. The contract suite passes its preflight, retry,
pinned-SSH, deadline, archive, graphical-readiness, and QMP-evidence checks,
`qemu-img check` reports no errors on the golden, and the real T4 passed with
the current bundle: 608 files restored,
the one documented absolute symlink escape refused, journal/hash/type checks
clean, QuickShell and Hyprland active with an `omarchy-bar` layer, and a
non-uniform 1280x800 QMP screenshot saved under `~/VMs/omabackup/results/`.
An earlier golden exposed the installer encryption-default issue and was
discarded from acceptance; the final golden was rebuilt without the credential
field that triggered it. The screenshot is retained as human-review evidence;
the automated visual contract is the live compositor, monitor, and
`omarchy-bar` checks rather than a claim that pixel diversity proves the right
desktop. Configuration work can now start.

The builder's cold boot uses a fresh copy of the same OVMF vars template as
the restore runner, so a transient installer NVRAM entry cannot hide a broken
golden. Provisioning SSH calls have an absolute deadline, the host-key file is
swapped only after all builder checks pass, and failed QEMU processes receive a
TERM/KILL cleanup escalation.

#### 2. Configuration contract — design before interface

Define the schema and invariants for machine-owned settings without changing
the public group manifest or the secret deny-list. The initial scope is the
repo path, `dir` destinations, retention, timer intervals, and the enabled
switch. Keep compatibility with the existing `env`, `destinations.json`, and
systemd units; do not introduce a second parallel config format merely to draw
a Settings screen.

The command name is `omabackup config`:

- `omabackup config` opens the interactive ANSI/TUI when attached to a tty;
- `omabackup config show --json` is the read-only machine-readable view;
- explicit subcommands may be added for scripts and future QuickShell calls;
- every mutation validates first, writes atomically, and reports the resulting
  systemd state.

**Completed 2026-08-29:** the contract is implemented in `lib/config.sh`.
`config show --json` is read-only; repo and destination mutations preserve
unrelated environment lines and use atomic mode-600 writes; timer edits accept
simple five-field crontab schedules, translate them to systemd `OnCalendar`,
preserve the rest of each unit, and roll back when daemon reload/restart fails.
The systemd expression is retained only in the diagnostic
`schedules.calendar` JSON field. Unknown destination fields, types, paths, and
retention values are rejected.

#### 3. CLI configuration implementation

Implement and regression-test `config` against temporary homes and stubbed
systemd. It must work over SSH/recovery tty without QuickShell, never source
user-controlled configuration as shell code, preserve unrelated hand edits,
and make invalid or incomplete settings impossible to activate silently.

**Completed 2026-08-29:** `bin/omabackup config` provides `show`, `validate`,
repo/schedule/enabled setters, and destination add/remove. The non-interactive
path is covered against temporary homes and stubbed systemd; the initial
non-interactive regression contract had 45 passing assertions, including
malformed JSON, spaces, atomic preservation, crontab-to-systemd conversion,
invalid schedules, and timer rollback. The complete Config suite now also
covers the interactive TUI.

#### 4. ANSI/TUI implementation

Build the interactive interface on top of the CLI contract, not beside it.
Use plain terminal control/ANSI primitives already available on the base
system; keep a non-interactive path for automation. Test navigation, cancel,
validation failures, spaces in paths, no destination, and disabled timers.

**Completed 2026-08-29:** the TUI is a thin ANSI menu over those same CLI
subcommands, so it shares validation and atomicity instead of duplicating them.
It offers guided minute/hour/day/week choices, shows the resulting crontab,
generates a destination name when the user leaves it blank, lets the user
choose a destination by number or name, and explains retention as “keep the N
newest bundles”. Restore uses the same terminal-owned TUI style: numbered
artifacts, a safe preview target by default, an explicit home confirmation, and
no destination id prompt. It is usable over a recovery tty/SSH session, while
scripts and QuickShell use the explicit non-interactive commands.

#### 5. QuickShell Settings surface

Follow the existing Omarchy network-settings pattern: the panel's Config block
stays a compact read-only summary and gets a `Settings…` action in the fixed
footer. That action opens `omabackup config` in `omarchy-launch-tui`, just as the network panel's
`Custom` option hands DNS configuration to the Omarchy CLI. When the terminal
closes, the panel refreshes `status --json` and shows the new state. QML remains
a client: it does not write config files, run `systemctl`, or reimplement
validation. A full in-panel form is unnecessary unless real use later shows a
specific setting that benefits from inline editing.

**Completed 2026-08-29:** `Panel.qml` has a compact read-only `Current settings`
summary and a `Settings…` action that fades the QuickShell panel before
launching `omarchy-launch-tui` with `omabackup config`; Restore follows the
same handoff with `omabackup restore`, so both are the same terminal-owned ANSI
surface. Machine-action processes have an absolute timeout; the terminal
handoff remains alive for the whole user TUI session and refreshes on exit. The
expanded summary scrolls its rows into the capped panel viewport. The panel's
runtime version comes from the manifest through `status --json`, is shown as
an explicit `OmaBackup 0.2.1` action, and copies only that version to
Quickshell's Wayland clipboard when clicked. The fixed footer keeps `Restore…`
and `Settings…` together, while the body remains ordered as status/actions,
runtime identity, verification/coverage, destinations, and read-only settings.
The headless QML probes cover the handoff lifecycle, clipboard assignment and
layout; the source contract covers the command/app-id wiring, disabled state,
and timeout path; 15 panel assertions pass.

#### 6. Final verification and delivery

Run the complete shell suite, the QML probes, the VM test, and a live reload
only after each reviewable unit is complete. Update this plan with observed VM
results, keep the QEMU harness reproducible, and deploy the panel only after
the CLI and UI tests pass.

**Completed 2026-08-29:** `./test/run.sh` passed with **779 passed, 0
failed**; the focused configuration and panel checks passed with 45 and 15
assertions respectively. The real guest check passed with
`golden-clean.qcow2`, including restore, Omarchy state, QuickShell, and
Hyprland, with screenshot evidence at
`/home/brenoperucchi/VMs/omabackup/results/restore-20260829T220743Z.ppm`.
Two separate attempts against stale/flaky image state timed out before SSH
(one `golden-clean` boot and the old `golden-final-v2` fixture); their serial
evidence is retained by the runner and does not change the successful guest
run above. The active plugin clone was synchronized from this worktree and
reloaded with `omarchy-restart-shell`; checksums, `status --json`, and a
no-op `config` TUI smoke test all passed. The final review closed the timeout,
disabled-button, Settings-label, fade/refresh, and dead in-panel restore
findings, including the correction that prevents a long-lived terminal
session from being mistaken for a timeout and refreshes after a non-zero
launcher exit; the panel now has no `--apply` path of its own. The full
Panel visual click-through remains a desktop-only check because its Omarchy
`qs.Ui` imports are not available to the standalone headless probe; the live
shell reload loaded the plugin without a QML load error, and the focused
geometry/protocol probes passed.

### Follow-up UX correction (2026-08-29)

The first configuration surface exposed raw systemd calendar expressions and
asked for an invented destination id/retention number without explaining the
terms. The first panel handoff also left Settings and Restore visually over
the QuickShell card while the terminal opened, and an expanded summary could
grow below the viewport. This pass moved the user-facing schedule to guided
crontab choices, made destination ids optional and selectable by number,
defined retention as the number of newest bundles to keep, routed Restore and
Settings through the same terminal TUI, delayed the launch until the panel's
fade completes, kept the long-lived terminal handoff outside the
CLI-operation timeout, and scrolls the expanded summary to its rows.
Regression coverage now includes schedule round-tripping,
destination auto-naming/retention, the capped Settings scroll, handoff wiring,
and disabled/timeout source contracts.

### UX requirements round — configuration and restore TUI (2026-08-29)

The next work unit is a user-experience correction, not a new configuration
format. The CLI contract and the QuickShell handoff remain the single source
of truth; this round changes how the terminal surface explains and recovers
from states that are currently too easy to misunderstand.

The screenshot exposed these problems in the current configuration TUI:

- an empty `repo:` value gives no indication whether the repository is missing
  or merely unreadable;
- normal status shows raw systemd `OnCalendar` syntax instead of a schedule a
  person can understand;
- menu labels such as “destination”, “timers” and “previous backups” expose
  implementation terms without explaining their consequence;
- an empty or invalid choice produces `Unknown choice:` and then a
  `Press Enter to continue...` dead end instead of keeping the user in the
  menu;
- the same recovery and cancel behavior is not yet consistent across config
  and restore.

The Restore handoff is also in scope. A reproducible current-state case is:
`omabackup restore` launched through `omarchy-launch-tui` finds no valid bundle,
prints `No valid backup bundles were found.` and exits with status 1; the
terminal launcher then closes its window. The desired behavior is to keep the
user in an actionable OmaBackup TUI state for recoverable conditions (no
destination, no bundle, unreachable destination, invalid selection, or a
failed preview), explaining what happened and offering the next action. The
terminal may close normally only after an explicit quit/cancel or after an
unrecoverable launcher failure has been shown to the user.

The requirements to approve before implementation are:

1. **Status first.** Show explicit values or `Not configured`, never a blank
   field. Use plain labels such as repository, backup folders, backup schedule,
   send schedule, and automatic backups. Raw systemd calendar values belong in
   an optional diagnostic/advanced view only.
   The repository status must also say whether the configured repository has
   an `origin` remote and therefore whether the implicit GitHub destination is
   active. GitHub must remain part of the existing repository/remote model,
   not become a second destination id that can drift from the actual remote.
2. **One predictable menu.** Group actions by intent: repository, backup
   folders, backup schedule, send schedule, restore, and automatic backups.
   `q`/Escape cancel or exit consistently, Enter accepts the documented
   default, and invalid input returns to the same prompt with the valid range.
3. **Guided schedules.** Offer every-N-minutes, hourly, daily, and weekly
   choices with human examples and current-value defaults. Keep custom cron as
   an explicitly advanced option; the backend continues converting it to
   systemd without exposing `OnCalendar` in the normal flow.
4. **Friendly destinations.** Ask for a folder path, generate the internal id
   automatically unless the user deliberately expands advanced options, list
   configured folders by number and readable name, and describe retention as
   “keep the N newest backups”. No user should need to know a destination id
   to add, remove, or select one.
5. **Restore as the same interaction model.** Restore must use the same
   headings, spacing, numbered choices, cancel behavior, error recovery, and
   confirmation language as Settings. “No backups found” must explain how to
   configure a folder or return to the menu; it must not flash a terminal and
   disappear. Target choices must explain preview versus this machine, and the
   destructive home confirmation remains explicit.
6. **Panel handoff.** Settings and Restore keep the existing fade-before-launch
   behavior. When the terminal TUI exits, the panel refreshes status and
   surfaces any non-zero result without leaving a permanently busy or hidden
   state.
7. **Regression contract.** Add permanent tests for empty input, invalid input,
   no repository, no destination, no bundle, unreachable destination, a failed
   restore preview, explicit cancel, successful quit, and the exact
   `omarchy-launch-tui` handoff. Include a GitHub remote-present and
   GitHub-remote-missing case, asserting that the TUI reports the distinction
   and that `push` keeps its current implicit-origin behavior. The complete
   `./test/run.sh` suite and the VM restore check remain required before this
   work is considered complete.

The current UI language is English; unless the user requests a full
translation, keep this round in English for consistency with the panel and
CLI, while making the wording user-oriented.

### Restore TUI gate completed — 2026-08-30

- Recoverable no-bundle, listing, preview, target, and apply failures now keep
  the terminal open with retry/Settings/quit actions; explicit `q` remains a
  successful cancel.
- Restore freezes the resolved target, uses a private descriptor-backed
  snapshot, bounds the snapshot to the size measured on the opened inode, and
  keeps the shared artifact path in the journal. Terminal metadata and child
  output are sanitized before display.
- The remaining regular-file/FIFO race between Bash's `-f` check and `open` is
  documented as a residual availability risk of this shell implementation;
  the integrity contract is the already-open regular inode. The real bug found
  in arbitration—copying a growing source past the previewed size—is covered
  by a permanent append regression and fixed with bounded `head -c` copying.
- Restore gate: `./test/run.sh restore.test.sh` — **244 passed, 0 failed**.
  Both fixed Herdr reviewers returned `LIMPO` after the final test-label
  correction; the official arbitration is recorded under
  `.herdr/ask/omabackup-4/`.
- Next slice: finish the friendly shared Config/Restore interaction without
  creating a second destination id or changing push's implicit-origin behavior.

### GitHub/origin visibility gate completed — 2026-08-30

- The old push behavior is preserved: `cmd_push` still derives GitHub from the
  repository's implicit `origin`, keeps it out of `destinations.json`, includes
  it in the default push set, and skips it when a named destination is chosen.
- `config show --json`, `status --json`, the human config view, and the ANSI
  Settings view now expose the effective origin push URL, distinguish a missing
  remote, and keep `configured`/`active` independent from timer availability.
  A common-repository `.git` directory remains the explicit contract; linked
  worktrees remain outside this slice.
- Remote credentials are redacted from displayed URLs, failed `git push`
  details, newly persisted destination errors, and legacy state projected into
  status JSON. Multiple Git `pushurl` values retain the stable scalar contract:
  the first target is shown and the UI says that Git may use more.
- Permanent regressions cover push URL versus fetch URL, exact credential
  redaction, failed-push stderr/state leakage, legacy state, multi-pushurl
  setup, default versus named destination selection, missing origin, and
  configured origin with unavailable timers.
- Focused gates: `./test/run.sh config.test.sh` — **83 passed, 0 failed**;
  `./test/run.sh destinations.test.sh` — **61 passed, 0 failed**. Both fixed
  Herdr reviewers returned `LIMPO` after the final correction round; the
  review warning was explicitly re-sent and both reread `.herdr/reviewer.md`.
- The follow-up interaction work is recorded as completed below.

### Friendly Config/Restore interaction gate completed — 2026-08-30

- Config and Restore now share a terminal-owned ANSI interaction model with
  status-first wording, explicit `Not configured`/unreachable states,
  recoverable invalid input, `q` cancellation, and no-bundle retry/Settings/
  quit actions. Restore keeps preview and apply failures visible instead of
  allowing the terminal launcher to flash and disappear.
- Folder destinations are shown and removed by ordinal, with readable paths
  and “keep the N newest backups” retention wording. Internal ids are
  generated automatically, and the reserved implicit GitHub origin cannot be
  entered as a duplicate destination.
- Schedule editing is guided by minutes, hours, days, and weeks, derives the
  current value as the default, and keeps custom cron as an advanced path.
  Supported cron forms round-trip through the systemd timers; every-minute and
  monthly forms are covered, while lossy conversions are rejected.
- The QuickShell Settings and Restore actions fade the panel before launching
  the same terminal-owned flow. Completion IPC carries the action, exit code,
  and generation token; the wrapper owns the heartbeat, signal status, and
  finite recovery path, so the panel refreshes without getting stuck busy.
  The displayed manifest version is still a clipboard action, not editable
  configuration.
- Human-facing config, destination, schedule, and restore metadata is
  sanitized before terminal rendering; machine-readable JSON and command
  arguments remain unchanged. Permanent tests cover control characters,
  overflow, stale callbacks, signal exits, and launcher failure paths.
- Focused gates: `config.test.sh` — **135 passed, 0 failed**;
  `destinations.test.sh` — **75 passed, 0 failed**;
  `panel.test.sh` — **32 passed, 0 failed**;
  `vm.test.sh` — **23 passed, 0 failed**;
  `restore.test.sh` — **251 passed, 0 failed**. Rounds 8–11 found concrete
  issues; each fix gained a permanent regression that failed before the fix.
  The final corrections cover destination validation, wrapper cleanup/IPC
  bounds and signal forwarding, relative golden canonicalization, calendar
  fallback wording, immediate Escape handling in both TUIs, inherited signal
  dispositions, termios/trap restoration, and the PGID discovery race.
- The fixed reviewers completed the final confirmation in round 12: both
  `omabackup-rev` and `omabackup-rev-2` returned **APPROVE**. The genuine
  signal-semantics disagreement in round 10 was sent to `herdr-ask`; its
  findings were implemented and then re-reviewed by the same fixed pair. The
  operational warning was re-sent in the confirmation request, and both
  reviewers were instructed to reread `AGENTS.md`'s Reviewer colleagues and
  `.herdr/reviewer.md`'s Isolamento section.
- Final verification is complete: `./test/run.sh` — **985 passed, 0 failed**;
  Bash syntax and `git diff --check` are clean. The real VM gate passed again
  on 2026-08-30 using the accepted `golden-final-v2.qcow2` fixture with its
  pinned SSH key: the real artifact restored in the Omarchy guest, the journal
  and file/type/hash checks passed, QuickShell and Hyprland became active with
  an `omarchy-bar` layer, and QMP produced screenshot evidence at
  `/home/brenoperucchi/VMs/omabackup/results/restore-20260830T090504Z.ppm`.
  The runner used the matching `known_hosts` fixture on port 2223 because the
  older `known_hosts-final` belongs to a previous image state; SSH remained
  strict and pinned during the successful run.
- The parent configuration/restore work is **complete**. Settings and Restore
  continue to use one terminal-owned ANSI flow, with no second config format
  and no panel-owned restore path; the QuickShell handoff remains a bounded,
  refreshable launch around that flow.

### Live plugin redeploy — 2026-08-30

- The live symptom had two operational causes, not a missing GitHub code path:
  the installed clone was still at `81409c9`/`0.2.0`, and the new
  `bin/omabackup-tui` existed only as an untracked development file. Git-based
  installation therefore omitted the wrapper that the Panel uses for both
  Settings and Restore. A permanent Panel regression now requires that the
  wrapper is tracked and executable; it failed before publication and passes
  after it.
- Commit `9e5f0ed` bumps the manifest to `0.2.1`, tracks the wrapper, and was
  pushed to `origin/main`. The installed clone was safely fast-forwarded after
  its previous loose changes were preserved in the recoverable stash
  `pre-omabackup-0.2.1 deployment snapshot`, then reloaded successfully:
  `9e5f0ed is live`.
- The machine config had `OMABACKUP_REPO=` even though
  `~/Devs/omarchy-personal` is the configured private dotfiles repository. The
  live CLI was set back to that path through `omabackup config set repo`; the
  resulting status is `tool.version: 0.2.1`, GitHub `configured: true`,
  `active: true`, and `origin -> https://github.com/brenoperucchi/omarchy-personal.git`.
- A live PTY smoke through the installed `bin/omabackup-tui` reached the Restore
  TUI, displayed the actionable `No backups found` recovery screen, accepted
  `q`, and exited cleanly instead of flashing and closing. The panel was
  reloaded after the configuration change. Full suite after the packaging
  regression: **985 passed, 0 failed**.

### Restore/Settings lockup, config naming, and a git-init bootstrap — 2026-08-31

- **The IPC bug the panel redeploy didn't catch.** After the 2026-08-30
  redeploy, the live symptom recurred in a different shape: opening Restore or
  Settings from the panel worked, but returning to the panel afterward left
  both buttons disabled with no way back in short of the 900s recovery timer.
  Root cause: `bin/omabackup-tui`'s `_notify()`/`_heartbeat()` sent completion
  IPC as `omarchy-shell shell call brenoperucchi.omabackup tuiFinished ...` —
  an indirection that does not exist. `omarchy-shell --help` documents the
  real contract as `omarchy-shell <target> <method> [args...]`; the `shell
  call ...` form always returns the literal string `unknown` and never
  reaches `Panel.qml`'s `IpcHandler`, confirmed live against the running
  panel. `externalBusy` therefore never cleared. Fixed by sending the direct
  form for both `_notify` and `_heartbeat`. The existing regressions used
  `assert_contains`, which still passed on the broken, longer string; both
  were tightened to `assert_eq`, and a real heartbeat-argv regression was
  added (the old one's fake `sleep` never returned, so that line was never
  reached by any test).
- **A second, independent, pre-existing bug found by writing a regression for
  the first one.** `lib/tui.sh`'s `tui_read_line()` had its own local
  accumulator named `value`. `cmd_config_tui`'s "Backup repository" and
  "Automatic backups" prompts both called `tui_read_line value` — the exact
  name — so bash's local-shadowing silently swallowed the answer: the
  caller's `value` stayed unset, and the first `set -u` read of it crashed
  with `value: unbound variable`. Neither prompt had ever been exercised
  interactively by a test before now. Fixed by renaming the internal
  accumulator, then hardening `tui_read_line` to explicitly refuse any
  destination name colliding with its own current locals (`case ... return
  1`, the same "make bash itself refuse to run" discipline `_verify_extracted`
  already uses) — review confirmed a bare rename only narrows the collision
  class, it doesn't close it. New `test/tui.test.sh` covers the primitive
  directly.
- **Config menu naming.** `Repository` was confusing because it implied only
  a git checkout would do, and separately shared no visible relationship with
  `Backup folders` (the plain, non-git `dir` destinations used for Restore) —
  two different concepts, similarly named. Renamed to `Backup repository`;
  `Backup folders — add/remove a folder` (options 2/3) stayed plural, matching
  the status header and `config show`, after a review round flagged that a
  singular/plural split put two labels for the same collection on one screen.
- **git-init bootstrap, and three rounds of hardening it.** The user asked
  whether `OMABACKUP_REPO` could work without `.git`. Investigation and an
  `herdr-ask` design round (`omabackup-8`) confirmed git stays required —
  `sync`'s commit, `bundle_cache_path`'s content addressing, `bundle_name`'s
  determinism, the secrets scanner's history half, and `dest_has_github` all
  depend on it — but landed on both reviewers independently recommending the
  same low-risk alternative: offer to `git init` a chosen folder that isn't a
  repo yet, instead of just failing. Implemented in `cmd_config_tui`'s
  "Backup repository" prompt, then hardened over three review rounds
  (`omabackup-15/16/17`, the last one user-authorized past the normal 2-round
  cap):
  - The initial guard (`! -d "$path/.git"`) was wrong in both directions: a
    linked worktree or bare repo has no `.git` *directory* (file, or absent
    entirely), so the offer fired and `git init` just reinitialized the
    existing repo, printing a false "Initialized..." beside the real
    rejection; and a subdirectory of an existing repo has no `.git` of its
    own either, so `git init` could nest a second repo that `config set repo`
    then silently accepted. Fixed with `git rev-parse --git-dir`, which
    resolves upward the way git itself does.
  - `rev-parse --git-dir` only checks ancestors, not descendants, so it said
    nothing about a broad, unrelated, non-empty directory that merely isn't
    inside any repo — reproduced live against `$HOME` itself. Fixed by also
    requiring the target be empty, closing the class without guessing at a
    blocklist of dangerous paths.
  - The trackedOnly-coverage warning that fires after a successful init
    originally named only the live path ("`~/.local/bin` ... commit something
    there") — not actionable, since `collect_tracked_only` reads `git
    ls-files` under `trackedRepoPath` **inside the backup repo**, which the
    live path usually isn't a git repository of at all. Fixed to name both.
    Also added the `select(.enabled != false)` filter every other per-group
    query in this codebase already has.
  - The empty-directory check itself had two more holes, both reproduced live
    and found independently by both reviewers in round 3: `find`'s default
    `-P` policy doesn't follow a symlink given as its own starting argument,
    so a writable symlink to a non-empty tree read as empty while `-d`,
    `git -C`, and `git init` all followed it; and `find`'s stderr was
    discarded with only stdout checked, so a directory `find` could not even
    read (permission denied, or `find` missing from `PATH`) also read as
    "empty" instead of "unknown". Fixed by canonicalizing the target once
    with `realpath -e` and reusing that same resolved path for every check
    and for `git init` itself, and by checking `find`'s exit status alongside
    its output. A third finding (the prompt blocks on input indefinitely,
    with nothing re-checked immediately before the actual `git init`) was
    closed by extracting the three-part check into
    `_config_repo_init_eligible` and calling it again right before the
    mutating step.
  - Full suite after all of the above: **1033 passed, 0 failed**.

### Small follow-up: Restore button color, a coverage gap, manifest 0.2.2 — 2026-08-31

- The footer's Restore button was hardcoded to `Color.muted` regardless of
  state, a leftover from a pre-Button-component `color: cond ? Color.muted :
  Color.muted` no-op that predates this repo's history and was never actually
  distinguishing enabled from disabled by color -- unlike Settings right next
  to it, which already switched to `Color.accent` when enabled. A fully
  enabled Restore read as permanently faded. Fixed to match Settings' own
  pattern; new source-string regression scoped to just `restoreButton`'s
  block (a looser, file-wide check would have passed even on the old code,
  since `settingsButton` already had the correct string elsewhere).
- Auditing test coverage per config-menu option surfaced one real gap: option
  5 ("Send schedule") shares its entire code path with option 4 (`4|5) ...
  choice==4 ? sync : push ...` in `cmd_config_tui`), but only option 4 had
  ever been driven interactively -- option 5's own branch (`push-schedule`,
  "Send schedule saved.", `omabackup-push.timer`) was only ever reached
  through the non-interactive `config set push-schedule` CLI form. Same
  asymmetric-coverage shape as the `tui_read_line` and git-init bugs above.
  New interactive regression closes it, in its own fixture rather than the
  shared `$CH` used by nearby specs (driving option 5 there would have
  overwritten `omabackup-push.timer` out from under a later spec that depends
  on its value).
- Manifest bumped `0.2.1` -> `0.2.2`. This batch (cosmetic fix + test-only
  changes + version bump) was not sent through a blind review round given its
  low risk, unlike the substantive logic changes above.
- Full suite: **1036 passed, 0 failed**.

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

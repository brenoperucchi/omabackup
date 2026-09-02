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
  changes + version bump) was committed and pushed without a blind review
  round first, given its apparent low risk. The user asked for one
  afterward anyway (`omabackup-18`, reviewing the pushed commit directly)
  and it was worth it:
  - Both reviewers independently converged on the same finding
    `omabackup-rev-2` had already raised for `omabackup-17`:
    `_cfg_tui_home` feeds the TUI a fixed keystroke script over a PTY via
    `script -qec` with no timeout. A keystroke count that falls out of phase
    with what the TUI actually shows hangs indefinitely instead of failing
    -- measured live at 3h34 stuck, freed only by `kill -9` on the wedged
    child. Fixed by wrapping it in `timeout --foreground --kill-after=5s
    15s`, the same pattern `test/vm.test.sh`'s own runner already uses.
  - The new Restore-button regression's `awk` block-extraction matched the
    closing brace at one literal indentation depth; a reindent would have
    made it run to EOF and silently pull `settingsButton` in too (which
    already had the string being checked for), passing even with
    `restoreButton` regressed back to broken. Fixed to match at any
    indentation.
  - The new "Send schedule (5)" regression was named "not just sync" but
    never asserted sync stayed untouched -- a regression that wrote to
    both timers would have passed. Added the missing assertion, and
    trimmed a stray blank keystroke that was being silently absorbed by
    the main menu as an invalid choice.
  - Fixed in a follow-up commit, not an amend.
- Full suite: **1036 passed, 0 failed** before the `omabackup-18` follow-up,
  **1037 passed, 0 failed** after it.

### Bar icon iteration, a GitHub button, and a timeout fix that didn't (`omabackup-19`) — 2026-09-01

- The bar icon changed several times live, at the user's direction, comparing
  each candidate against the actual installed font: `fa-save` (generic) ->
  `fa-layer-group` (rendered as a blank box -- the installed JetBrainsMono
  Nerd Font only carries the classic Font Awesome block, confirmed via
  fontTools) -> `fa-code-branch` -> Material Design's `md-sync` /
  `md-sync_circle` / `md-database_sync` / `md-folder_sync` -> back to
  `md-sync`, the final choice. `dimmed: root.covered` (a fixed 0.45 opacity
  from the shared `WidgetButton`) was replaced with a direct
  `opacity: root.covered ? 0.75 : 1.0` -- confirmed live as nearly invisible
  against the user's transparent bar. `fontSize` went from `Style.font.caption`
  (10px, in a 21px slot) to a literal 16, later corrected to `Style.font.heading`
  (see below).
- The `github` destination (implicit via `OMABACKUP_REPO`'s `origin`, DESIGN.md
  §3) moved from a non-clickable chip in the Destinations list to its own
  button in the top action row, right-justified next to "Back up
  now"/"Check again". Clicking it opens the **local** repository in the file
  manager (`Util.execArgv(["xdg-open", root.config.repo])`, the shared
  injection-safe launcher first-party plugins already use) -- deliberately
  not github.com, since that would start a network trip from a read-only
  status button with no confirmation. The Destinations section below is now
  only about `dir` destinations (`root.otherDestinations`) and hides once
  none exist.
- Also: Hyprland's `decoration:rounding` was changed from 12 to 0 in
  `~/.config/hypr/looknfeel.lua`, at the user's request, to make every panel
  square -- this is a system-wide setting read live by the shared
  `Style.cornerRadius` token, not something a single plugin can override
  (`KeyboardPanel`'s own `BorderSurface` hardcodes `radius: Style.cornerRadius`
  with no exposed override property). Confirmed both Time Machine and OmaVault
  read the identical token; OmaVault's square-looking demo gif reflects its
  author's own (low/zero) rounding setting, not anything the plugin did
  differently.
- Review round `omabackup-19` (15-commit batch since `omabackup-18`) found one
  real regression the two rounds before it had both praised as fixed:
  `_cfg_tui_home`'s `timeout --foreground` (`fee0888`) does not actually bound
  anything. `--foreground` stops `timeout` from creating its own process
  group, so it can only signal its direct child (the wrapping `bash -c`) --
  `script` and the TUI inside it are grandchildren, survive as orphans still
  holding the pipe open, and the command substitution hangs exactly as
  before. `omabackup-rev-2` reproduced this live (stuck >2 minutes with the
  "fixed" code) and proved dropping `--foreground` closes it (rc=124 at
  ~17s). Fixed for real this time, plus a permanent regression that pins the
  actual elapsed time, not just the marker text, since asserting the text
  alone is exactly what let the broken version look fixed for two review
  rounds. Also fixed: the GitHub button's status (error / last-sent age) had
  moved from always-visible chip text to a tooltip that `qs.Ui.Button` only
  shows on mouse hover, never on keyboard focus -- restored as visible text
  alongside the tooltip, not instead of it.
- **Known gap, not fixed this round:** the 35-assertion `panel.test.sh` gate
  never actually instantiates `Panel.qml` itself -- `_qml_probe` only loads
  standalone probe files, and `Panel.qml` is otherwise just grepped as a
  string. A broken `Util.execArgv` call, a `dir` destination lost or
  duplicated by the `otherDestinations`/`githubDestination` split, or a
  straight syntax error in any of this round's new lines could in principle
  pass 35 green checks undetected. Live reloads on the real installed plugin
  and the user's own screenshots are the only evidence any of this actually
  works today. Building a harness that instantiates the real `Panel.qml`
  with synthetic `dir`/`github` destinations and intercepts the click argv is
  real, separate work -- flagged, not attempted here.
- Full suite: **1039 passed, 0 failed**.

### Settings TUI: closing the "dead end" gaps in options 1/4/5/6 — 2026-09-01

The user reported setting "Backup repository" to a directory that did not
exist yet and hitting a raw `repo must point at an existing git repository`
with no way forward from inside the TUI. That widened into an explicit
request: audit both the Settings and Restore TUIs for every point where the
flow just fails instead of offering a path to success, before fixing broadly.

The audit found Restore already at the target standard --
`_restore_tui_recovery` wraps every failure in "Try again / Open backup
settings / Cancel", so nothing there needed to change. The Settings TUI's
main loop was equally robust at the mechanical level (never crashes, always
returns to the menu), but three concrete points repeated a non-interactive
CLI's raw `die` text and stopped, with no menu path to the fix:

- **Options 4/5/6 (Backup schedule, Send schedule, Automatic backups)** all
  die the same way on a repo-configured machine that never ran `omabackup
  install`: `"timers are not installed yet -- run: omabackup install"` --
  and there was no "install" option anywhere in the 1-6 menu, so a new user
  working through the obvious order (1 -> 4/5/6) hit a wall only a shell
  could clear. Fixed with `_config_tui_offer_install` (lib/config.sh): on
  that specific message, offer to run `omabackup install` right there and
  retry the original schedule/enabled change. Viable because `cmd_install`
  only needs `OMABACKUP_REPO`, already on disk by the time option 1 has run
  (bin/omabackup loads `~/.config/omabackup/env` at startup; an
  already-set variable always wins over it).
- **Option 1, a repository path that does not exist at all** -- the
  originating report. The existing git-init offer only fired for a directory
  that already exists; a path with nothing at it fell straight through.
  None of the existing-directory hazards (already a repo, nested repo,
  `$HOME`-sized directory) apply to a path with nothing there yet, so the new
  branch only has to guard `mkdir -p` itself failing. The trackedOnly-groups
  coverage note that used to live inline in the git-init branch was pulled
  out into `_config_repo_tracked_only_note` so both branches share it instead
  of duplicating ~25 lines of jq.
- **Option 1, after either successful `git init`** -- the second half of the
  originating request: offer to also create a private GitHub repository via
  `gh repo create --private --source=<path> --remote=origin` (no `--push`;
  the repo is empty right after init anyway, and the next sync/push cycle
  sends real content). Gated on `gh` being installed and authenticated,
  checked with `gh auth token` -- a local credential-store read, not a
  network round trip, matching this file's existing "never probe the network
  just to decide whether to show a prompt" posture. Silent (no prompt at all)
  when gh is missing or unauthenticated: unlike the install offer, there is
  no dead end to rescue here, just a convenience on top of an already-usable
  local repository. `$GH` (`bin/omabackup`, next to `$SYSTEMCTL`) is
  overridable via `OMABACKUP_GH`, the same stub-injection pattern the
  systemd-timer tests already use.
- 28 new regressions in `test/config.test.sh`, each confirmed to fail against
  the pre-fix code (`git stash` the two source files, rerun, restore) before
  being counted as done: accept/decline/fail for the install offer (both
  schedule and enabled), accept/decline/fail/unavailable/unauthenticated for
  the GitHub offer (both the existing-directory and newly-created-directory
  branches), and accept/decline/mkdir-failure for the create-directory offer
  itself. `_cfg_tui_home` gained a 4th optional argument for a `gh` stub path
  and defaults `OMABACKUP_GH` to a path nothing creates, so every git-init
  keystroke script written before the GitHub offer existed keeps working
  unchanged -- the same "keystroke count falls out of phase" failure mode
  `_cfg_tui_home`'s own timeout bug (above) was about, avoided here by
  keeping the new prompt opt-in per test rather than always-on.
- Full suite: **1085 passed, 0 failed**.

#### Review round `omabackup-20`: a nested-repo hole, a lost-write race, and a non-standard `gh` invocation

Both reviewers found real, independent problems in the round above, converging
from different angles on the same underlying ordering defect:

- **`omabackup-rev`, CONFIRMADO** -- the "doesn't exist yet" branch's `[[ ! -e
  ]]` check says nothing about the path's ANCESTORS. A target like
  `~/existing-repo/new-subdir` (the leaf absent, the parent already a git
  repository) passed straight through, and accepting the offer would nest a
  second repository inside the first -- exactly the hazard rounds 15-17 closed
  for a target that already exists, unguarded here for one that does not yet.
  Fixed with `_config_repo_create_eligible` (lib/config.sh): walks up from the
  target to the nearest EXISTING ancestor (there is always at least one, `/`)
  and asks `git rev-parse --git-dir` about that instead, since git itself
  cannot be asked about a path that is not there. Also closes the race
  `omabackup-rev` flagged in the same finding -- `mkdir -p` treats an
  already-existing directory as success rather than failure, so a second
  `_config_repo_init_eligible` gate now runs on what `mkdir -p` actually
  produced, right before `git init`, instead of trusting the pre-mkdir check.
- **CONFIRMADO from both reviewers, independently** -- `git init` succeeded,
  then the flow blocked on the optional GitHub offer (a prompt, then a real
  `gh` shell-out), and only after that returned did `config set repo` persist
  OMABACKUP_REPO. An interruption during either step left a valid, freshly
  initialized local repository -- and possibly a real private GitHub
  repository with origin already wired -- with OMABACKUP_REPO never saved, and
  no way back in: a second attempt at the same path no longer offers to init
  it, since it is already a repository by then. Fixed by moving `config set
  repo` to run immediately after `git init` succeeds, before the GitHub offer
  -- the offer is now strictly additive on top of an already-consistent,
  already-persisted state. Proven with a new regression that has the `gh`
  stub check, at the exact moment its own `auth token` availability call
  runs (before its prompt is even shown), whether OMABACKUP_REPO is already
  on disk.
- **`omabackup-rev-2`, well-evidenced, treated as valid** -- `gh repo create
  --private --source=<path> --remote=origin` omitted the repository name.
  `gh repo create --help` (gh 2.98.0, this machine) documents the
  non-interactive form as requiring name + one of `--public/--private
  /--internal`; without it, in the exact window identified above, the door
  was open for `gh` to read from the same stdin the TUI itself was using.
  Confirmed non-interactive on the failure path only (deliberately not
  probed on the success path, to avoid creating a real repository just to
  check). Fixed by passing `"$(basename -- "$path")"` as the name --
  literally gh's own documented example.
- **Fixed, not from a specific numbered finding but the same root cause** --
  `_config_tui_offer_install`/`_config_tui_offer_github` printed their
  underlying command's output directly, but `cmd_config_tui`'s loop clears
  the whole screen (`tui_header`'s `ESC[2J`) before the next prompt draws, so
  on failure that diagnostic was gone before a real user could read it --
  and, specifically for install, the `notice` that survived the redraw was
  the ORIGINAL "timers are not installed yet -- run: omabackup install",
  telling the user to run the exact command that had just failed, with less
  information than before the offer existed. Both helpers now set a
  `CONFIG_TUI_INSTALL_OUTPUT`/`CONFIG_TUI_GITHUB_OUTPUT` global (the same
  convention `CONFIG_TUI_SCHEDULE` already uses) instead of printing, and
  both call sites fold it into a durable `notice`/prefix on both success and
  failure.
- Also fixed, cheap and low-risk: the two `_config_tui_offer_github` call
  sites now honor its documented `rc==3` ("terminal went away") the same way
  its install sibling already does, instead of silently falling through as
  if declined; and `_config_repo_tracked_only_note` now `return 0`s
  explicitly instead of relying on its last conditional's own exit status,
  which happened to be 1 whenever there was nothing to report -- harmless
  today (no `set -e`, no caller checks `$?`), flagged as a latent trap for
  whenever either changes.
- 5 new regressions (2 for the nested-repo/ordering fixes above, 3 covering
  the argv and notice-content changes the other fixes needed); the existing
  batch's `gh repo create` argv assertions and the two "installed and
  scheduled" assertions were updated to match the corrected invocation and
  the now-durable success notice.
- Full suite: **1090 passed, 0 failed**.

#### Review round `omabackup-21` (correction round 2 of 2): a real argv bug, and two testing-rigor gaps

`omabackup-rev-2` re-verified every round-20 fix independently (ran
`_config_repo_create_eligible` by hand against 8 constructed paths, traced
the reordering through every branch it could have broken) and approved with
no new findings. `omabackup-rev` found three real gaps in round 20's own
fixes:

- **P2, a real bug** -- the just-fixed `gh repo create` call still put the
  repository name FIRST, unterminated: `gh repo create <name> --private
  --source=... --remote=origin`. A directory whose basename starts with `-`
  (reproduced live with one literally named `--help`) is then read by `gh`
  as an OPTION instead of the positional name -- `gh repo create --help
  --private --source=... --remote=origin` just prints `gh`'s own help and
  exits 0 without creating or validating anything, and the helper reported
  that exit code as success. Fixed by moving every flag before the name and
  terminating option parsing with `--`, the same pattern this file already
  uses everywhere else a value could start with `-` (`git init -q --
  "$path"`, `rm -f -- "$tmp"`). New regression drives this through a real
  directory named `--help` and asserts the resulting argv.
- **P3, testing rigor** -- the round-20 regressions proving diagnostic output
  survives to the user (the install/GitHub failure notices) only checked
  substring presence anywhere in `_cfg_tui_home`'s raw PTY transcript. The
  PRE-fix code also printed that same text, transiently, right before the
  next `tui_header` cleared it -- so those assertions would have passed
  identically against the broken version; they proved nothing about
  survival past the clear. Fixed by adding `_cfg_tui_last_frame` (bash's own
  greedy `##` prefix removal against the literal `ESC[2J` byte sequence,
  isolating everything printed after the LAST clear) and pointing the two
  affected assertions at it instead of the raw transcript.
- **P3, testing rigor** -- the round-20 nested-repo regression only covered
  `_config_repo_create_eligible`'s ancestor check, not the second half of
  that same fix: the `_config_repo_init_eligible` gate that runs on what
  `mkdir -p` actually produced, right before `git init`, closing the race
  where `mkdir -p` treats an already-existing (and possibly since-populated)
  directory as success rather than failure. New regression shadows `mkdir`
  itself on `PATH` (it has no override variable of its own, unlike
  systemctl/gh) via a 5th argument added to `_cfg_tui_home`, with a stub
  that behaves exactly like the real `mkdir -p -- <path>` except for one
  specific race-marker target, where it also drops a file into the
  directory before returning success -- proving the second gate actually
  fires, not just that the underlying primitive works in isolation.
- 4 new regressions; both reviewers agreed this is the natural stopping
  point (`omabackup-rev-2`: "Não vejo nada que justifique uma terceira"),
  matching the review protocol's 2-correction-round budget.
- Full suite: **1096 passed, 0 failed**.

### Persistent log of what OmaBackup does — 2026-09-01

Motivated by a real screenshot: the panel showed `config: terminal command
exited with status 130` with no way to find out what actually happened.
`Panel.qml`'s `root.lastError` is a plain QML property, never written to
disk. Separately confirmed live that `sync`/`push`'s systemd-timer runs
already have a real log (`journalctl --user -u omabackup-sync.service -u
omabackup-push.service`) — the gap is everything else: an interactive
Config/Restore TUI session, and any command run by hand.

**Design consultation before any code (`herdr-ask` round `omabackup-10`)**,
per the user's explicit request to review the plan with the reviewer pair
first. Both reviewers found real problems with the first draft, two severe
enough that it would not have worked correctly in production:

- `die()` (`bin/omabackup:98`) calls `exit 1` directly, so a post-call
  wrapper ("run the function, then log after it returns") never runs for
  anything that fails via `die` -- most real failures in this codebase.
  Fixed with an `EXIT` trap installed before dispatch, not a wrapper.
- `Panel.qml`'s `resolveProc` (confirmed live) prefers PATH over the plugin
  directory for the CLI path the panel hands to `bin/omabackup-tui`. The
  original draft derived `OMABACKUP_ROOT` as `dirname(dirname($cli))` --
  silently wrong on a machine where `omabackup` is actually on PATH, a
  failure invisible to every test (which always invokes this repo's own
  binary directly). Fixed by having `bin/omabackup-tui` call a new internal
  `omabackup log-event ACTION OUTCOME [DETAIL]` subcommand on the exact
  `$cli` path it just ran, instead of sourcing `lib/log.sh` and deriving a
  root itself.

Also from that consultation: pruning by `find -mtime` was replaced with
per-day files (`omabackup-YYYY-MM-DD.log`, no rename step) and a filename-
date string comparison against a cutoff -- exact "N calendar days," not
`-mtime`'s "+N*24h with truncation" (confirmed live: `-mtime +30` keeps 31
days); a persistently-failing `verify`/`status` (the panel polls every
`refreshIntervalSec`, confirmed live as 900s default/60s floor, not "a few
seconds" as first assumed) now coalesces into one transition line plus one
daily heartbeat, not one line per poll; `restore` without `--apply` that
refuses is now logged (the original scope table said "never," silently
dropping the single most useful line this tool produces); and
`OMABACKUP_LOG_SKIP=1` on both systemd units keeps the file log from
duplicating the journal.

New: `lib/log.sh` (`_log_write`/`_log_run_always`/`_log_run_on_failure`,
config/state split mirroring `lib/destinations.sh`'s own stated principle
-- `log.json` for the user's retention-days intent, `$OMABACKUP_STATE/log/`
for the events themselves). `omabackup config set log-retention-days N`,
`config show`'s new `Log retention: N days` line, and Settings TUI option
7 round out the surface.

**Two implementation bugs found and fixed against the project's own test
suite, not by review:**

- The full suite regressed from comfortably-under-600s to exceeding it
  after wiring in `_log_write` -- traced to running the flock+prune scan on
  every single write. Fixed by gating it on this being the first write to
  actually create today's file (pruning only ever removes files older than
  today, so repeating it same-day was pure waste).
- `test/panel.test.sh`'s own signal-testing stub CLIs (infinite-loop
  processes simulating a supervised CLI in isolation) do not implement
  `log-event` -- the wrapper's new post-exit call launched a second copy of
  the infinite loop, hanging the suite. Fixed by giving each affected stub
  an early `[[ "$1" == log-event ]] && exit 0`, and bounding the wrapper's
  own call with `timeout --kill-after=2s 5s` regardless (defense in depth:
  `$cli` is trusted in production, but nothing here should be able to make
  the panel wait forever if it somehow is not). Two further stubs
  (`HANDOFF_CLI`, `TTY_CLI`) got the same guard for a quieter corruption
  case -- the wrapper's own log-event call re-invoking them would have
  overwritten a file their *real* invocation's assertion depends on.
- `test/log.test.sh`'s own new Ctrl-C regression needed the same fix
  `test/panel.test.sh`'s already-proven one uses and the new draft had
  missed: `kill -INT <wrapper-pid>` is silently swallowed (bash sets
  SIGINT to `SIG_IGN` for an async job, inherited down through `script` to
  the wrapper, and a `trap` cannot override a `SIG_IGN` inherited at a
  bash process's own startup) -- the fix is `env --default-signal=INT,QUIT`
  immediately before the wrapper inside the `script -qec` string, plus
  writing the literal `\003` byte into the pty rather than signaling the
  PID directly, exactly mirroring `test/panel.test.sh`'s own working
  pattern instead of reinventing a second way to deliver the same signal.
- 41 new regressions in `test/log.test.sh`, each confirmed against the
  pre-fix code (`git stash -u` the implementation, keeping the new test
  file present, rerun, restore) before being counted as passing --
  including a `die()`-triggered failure, exact-boundary pruning, and the
  actual motivating case: `bin/omabackup-tui` driven through a real PTY
  with the real CLI, Ctrl-C delivered, confirming `signal=INT` lands in the
  log.
- Full suite: **1132 passed, 0 failed**.

#### Review round `omabackup-22`: a false "ok" on signal, real state pollution, and five more

`herdr-review` on the implementation (not the design, already consulted
separately) found ten real problems, seven from `omabackup-rev` and three
from `omabackup-rev-2` -- the most severe of which was live-reproduced on
this machine, not just in a test:

- **CONFIRMADO, most severe** -- the dispatch's `EXIT` trap caught `die()`
  correctly but had no signal traps of its own. A real Ctrl-C (or `kill
  -INT`) on a manually-run command reached the `EXIT` trap with whatever
  `$?` was set to BEFORE the signal -- reproduced live: bash reports `0`
  there, so an interrupted `sync` logged a false **`ok`**, the exact class
  of error this project treats as the worst a backup tool can make.
  `omabackup-rev` found the same gap from the die()-ordering angle (a
  `--groups`-parse-time die() happened before the trap existed at all, and
  an unrecognized command fell through with no policy). Fixed together:
  the trap installs immediately after `CMD` is captured (before argument
  parsing, which can also die()), `LOG_POLICY` starts at `failure` as a
  safe default and is only refined once `CMD`/`ARGS` are fully known, and
  new `HUP`/`INT`/`TERM` traps mirror `bin/omabackup-tui`'s own
  (129/130/143), so the human-run and panel-launched paths agree on what a
  signal means. Verified safe against the existing interactive-TUI signal
  handling: `lib/tui.sh`'s `tui_read_line` saves/restores traps via `trap
  -p` generically, so it does not matter what was there before.
- **`omabackup-rev`, real and currently active** -- `log-event` itself
  required the group manifest to exist, so exactly the failure it exists
  to report (a broken/missing manifest during an interactive session) also
  killed the notification. Fixed by exempting `log-event` from the
  manifest checks.
- **`omabackup-rev`, real and currently active on this machine** --
  `test/panel.test.sh`'s own `status --json` version probe had no
  `HOME`/state isolation, so every suite run wrote a real baseline/
  coalescing entry into this machine's actual
  `~/.local/state/omabackup/log/` -- confirmed by inspecting it directly.
  Fixed with an isolated `HOME` plus an explicit `OMABACKUP_LOG_SKIP=1`
  (this probe is about status's JSON, not logging).
- **`omabackup-rev`** -- `flock -x` with no timeout could hang the `EXIT`
  trap indefinitely if another logger was suspended holding the prune
  lock, after the wrapped command had already finished. Fixed with `-w 5`;
  a timed-out lock skips pruning rather than blocking exit. The coalescing
  state (`.last-*`) read/decide/write/update sequence had the same gap at
  a different layer (two concurrent first observations could both write a
  baseline) -- fixed with a per-action lock, same bound.
- **`omabackup-rev`** -- `log.json`'s `retentionDays` was only checked
  `>= 1`, so a hand-edited file with an absurd value (or one `jq` prints in
  exponential notation) passed as valid and reached the cutoff-date
  arithmetic unbounded; `config validate` did not look at `log.json` at
  all. Both fixed.
- **`omabackup-rev`** -- `OMABACKUP_LOG_SKIP=1` only reached the systemd
  *templates*; `cmd_install` is the only thing that ever writes the live
  units, and `reload` (the documented update path, and what `omarchy
  plugin update` calls) never touched them -- confirmed live: this
  machine's own installed `.service` files still lack the line. Fixed with
  a narrow refresh inside `reload` that rewrites only the two `.service`
  files (never `.timer`, which would discard a configured schedule) when
  a units directory already exists.
- **`omabackup-rev-2`, P3** -- two of the seven wrapper-invoked stubs in
  `test/panel.test.sh` (`HEARTBEAT_HOME/cli`, `HBARGV_CLI`) were safe
  against the new `log-event` call only by accident of timing, unlike the
  other five, which had an explicit guard. Given the explicit guard too,
  for the same reason.
- **`omabackup-rev-2`, P3, documented not fixed** -- pruning only runs on
  a write, and both systemd units now skip writing entirely, so "keep N
  days" on a mostly-idle machine is closer to "keep N days of write
  activity." Impact is small (nothing writes, nothing grows) and rev-2
  did not push past documenting it; noted in `lib/log.sh`'s own comment.
- Everything else `omabackup-rev-2` checked (log-event's `timeout`
  bounding, coalescing/heartbeat correctness including exactly-once-per-
  day firing, the append/prune race, both of this round's own earlier
  self-found-and-fixed bugs) came back clean, verified independently
  against a sandbox rather than just re-reading the code.
- 15 new regressions in `test/log.test.sh` (51 total), covering: a die()
  during argument parsing before the old trap-install point, `log-event`
  with no manifest present, a real `SIGINT` mid-`sync` (via `env
  --default-signal=INT,QUIT`, the same disposition-reset bin/omabackup-tui
  already needed -- a plain `kill -INT` on a backgrounded test process is
  silently swallowed for the identical POSIX reason) asserting no false
  `ok`, bare `config` now being logged at all, an over-limit `log.json`
  correctly falling back to the default, `config validate` reporting it,
  eight concurrent processes racing the same first observation producing
  exactly one line, and `reload` refreshing an already-installed
  `.service` file while leaving a configured `.timer` schedule untouched.
- Full suite: **1147 passed, 0 failed**.

#### Review round `omabackup-23` (correction round 2 of 2): a real unit-truncation risk, and a regression from round 22's own fix

`herdr-review` on round-22's fixes found four more real problems (all from
`omabackup-rev`) and one regression `omabackup-rev-2` traced to round 22's
own change (their P2 from round 22 -- the signal traps -- verified correct
by independent reconstruction, not by re-reading the tests):

- **CONFIRMADO-shaped, most severe** -- `omabackup-rev`'s P1: `cmd_reload`'s
  new service-file refresh (round 22) used a plain `>` redirect, which
  truncates the target FIRST -- a read/write failure partway (disk full
  included) left the live unit empty or partial while `|| true` silently
  swallowed it, and `reload` still reported success. Fixed with a temp
  file in the same directory, a non-empty-output check, and an atomic
  `mv` only on success; a failure now leaves the previously-working unit
  untouched and prints a warning instead of dying (reload's own real job
  -- verifying the shell restart -- should not block on this).
- **`omabackup-rev`'s P2, converging with `omabackup-rev-2`'s new P3** --
  round 22's dispatch-policy fix only half-closed the gap it meant to:
  `LOG_POLICY` still parked at a single `failure` default until AFTER
  argument parsing, so `sync --groups`'s parse-time die() stayed
  misclassified as `failure` (coalesced against unrelated state, instead
  of always logging the way `sync` is supposed to), `OMABACKUP_LOG_SKIP`
  applied too late to cover a parse-time die on a timer-triggered run, and
  -- the regression `omabackup-rev-2` found live -- `help`/`version`/
  `artifacts`/no-CMD-at-all never got their own `never` case in the
  post-parse refinement, so they fell into the `failure` default and each
  wrote a one-time "ok" baseline, one of them under a literally empty
  action name. Fixed by splitting into two passes: a coarse one, `$CMD`
  alone, immediately after capturing it (before any parsing that can
  die()), applying `OMABACKUP_LOG_SKIP` right there; a second pass after
  ARGS is known only narrows it for config/restore's own sub-command
  distinctions, which `$CMD` alone cannot decide.
- **`omabackup-rev`'s P2** -- the wrapper double-logs a panel-launched
  session: the child's own dispatch policy for bare `config`/`restore`
  writes one entry, and the wrapper's own post-exit `log-event` call
  writes a second for the exact same session. Fixed with a new
  `OMABACKUP_TUI_SUPERVISED=1` the wrapper sets on the CLI child it
  launches; the child's dispatch checks it and skips its own self-log for
  a bare interactive session, leaving the wrapper's call as the sole
  record. Same finding, Restore half: bare `restore` shared its
  coalescing marker with a specific artifact preview call (the outer
  session's own eventual "ok" could silently overwrite an inner preview's
  "failed") -- fixed by giving the bare session its own action name,
  `"restore (interactive)"`, distinct from a plain `"restore"` preview
  call.
- **`omabackup-rev`'s P2** -- deferred, not fixed this round, given the
  2-round correction budget and its narrow/cosmetic shape:
  `cmd_restore_tui` installs its own INT/TERM/HUP traps for snapshot
  cleanup, which override (not chain with) the new dispatch-level ones
  during a Restore session specifically -- `omabackup-rev-2` independently
  confirmed (by reconstructing the exact trap composition, not by reading
  the code) that this causes no interference and no incorrect behavior;
  the only consequence is that a Ctrl-C mid-Restore-session logs
  `"failed (exit 130)"` instead of the more descriptive
  `"failed (signal INT)"` -- the exit code, the EXIT trap firing, and the
  absence of a false "ok" are all still correct. Noted here as a known,
  accepted limitation rather than silently dropped.
- 8 new regressions in `test/log.test.sh` (59 total): bare/`help`/
  `version`/`artifacts` writing nothing at all, a repeated parse-time
  die() on `sync` logging every time instead of coalescing, the
  `OMABACKUP_TUI_SUPERVISED` suppression (and its absence still logging
  normally), the distinct bare-restore action name, and a reload
  service-refresh failure (an unwritable units directory) leaving the
  working unit byte-for-byte untouched.
- This is correction round 2 of the review protocol's 2-round budget for
  this implementation; `omabackup-rev-2` reviewed independently by direct
  reconstruction/reproduction rather than re-trusting the test suite for
  the highest-severity claims (their own explicit method note this round).
- Full suite: **1155 passed, 0 failed**.

#### Review round `omabackup-24` (correction round 3 -- final): a mis-cited "safe", and two items escalated to the user

`herdr-review` on round-23's fixes found four more problems (two from
`omabackup-rev`, two from `omabackup-rev-2`) and, notably, one of them was
`omabackup-rev-2` publicly correcting a claim my own dispatch request had
attributed to them:

- **P3, mis-citation corrected by the reviewer themselves** -- round 23's
  deferral of the `cmd_restore_tui` trap-chaining issue described it in the
  next round's request as something `omabackup-rev-2` had "already
  independently confirmed ... causes no interference/incorrectness."
  `omabackup-rev-2` opened their round-24 verdict by explicitly rejecting
  this: what they verified in round 23 was a *different* code path
  (`tui_read_line`'s save/restore via `trap -p`), never `cmd_restore_tui`
  itself. They then tested it for real and found the deferral's premise
  did not fully hold: `cmd_restore_tui`'s RETURN trap did `trap - RETURN
  INT TERM HUP` -- removing, not restoring, the dispatch-level signal
  traps -- so a signal landing in the narrow window between
  `cmd_restore_tui` returning and the process actually exiting reached the
  EXIT trap untrapped, reopening the exact false-"ok" bug round 23 existed
  to close. Both reviewers converged on the same one-line fix: `trap -
  RETURN` only, leaving INT/TERM/HUP bound (their handlers are already
  idempotent, so a signal in that window still exits 130/143/129 -- just
  without the more descriptive "signal=INT" phrasing a session-scoped
  Ctrl-C gets elsewhere). Fixed. Noted for next time: don't characterize a
  deferred item's safety more strongly than what was actually verified,
  and say so plainly in the next round's request rather than compress it.
- **`omabackup-rev`'s P3** -- `_rewrite_execstart` (called by both
  `cmd_install` and `cmd_reload`'s new refresh) calls `die()` -- a real
  `exit` -- for a source path containing a single quote or an unexpected
  `ExecStart` shape. Running in the main shell, that would have killed
  `reload` outright for a single malformed template: no warning, no temp
  cleanup, and none of `reload`'s own real job (verifying the shell
  restart) for either unit, not just the malformed one. Fixed by wrapping
  the call in an explicit `( ... )` subshell, containing the `exit` to
  just that one unit's generation attempt.
- **`omabackup-rev`'s P2, escalated to `omabackup-scout` (the project's
  arbiter agent) at the user's explicit direction -- decided, not fixed**
  -- `cmd_reload`'s round-23 atomic-write fix is atomic per file but not
  across the pair, nor relative to `daemon-reload`: a failure between the
  two `mv`s (or between both `mv`s and `daemon-reload`) can leave disk and
  loaded-unit state briefly inconsistent. `omabackup-rev` wanted a
  two-phase-commit-style fix (generate and validate both temps before
  moving either, roll back the pair on any later failure).
  `omabackup-rev-2` tested both failure sequences directly and judged the
  current behavior "aceitável": nothing is truncated, the warning prints,
  and a later `reload` retries both units -- a genuine severity
  disagreement between the two reviewers on the same facts. Rather than
  decide alone, this went to `omabackup-scout`, this workspace's read-only
  arbiter for exactly this kind of reviewer disagreement (it re-read both
  verdicts and the current code before ruling): **do not fix now** --
  `omabackup-rev-2`'s severity call stands, since systemd keeps the old
  units loaded when the pair fails, nothing is corrupted, and the next
  `reload` reconciles the pair on its own; two-phase-commit rollback would
  add disproportionate complexity for a transient, recoverable
  inconsistency.
- **`omabackup-rev`'s P2, documented not fixed, escalated to
  `omabackup-scout` for the same reason -- decided, not fixed** --
  `config set --groups`/`restore --apply --groups` parse-time `die()`s
  still land under the coarse `failure` policy instead of `always`, the
  same class of gap `sync --groups` had (fixed in round 23) but not
  extended to these two, since classifying them correctly needs `ARGS`,
  which only exists after the parsing that can itself die(). Lower
  severity than a false "ok" -- reduces visibility on a *repeated* rare
  parse mistake, does not misreport an outcome. Not a reviewer conflict
  (both agreed on the fact and the P2 severity) but still put to
  `omabackup-scout` since it was a scope call made under a budget
  constraint rather than a settled decision: **keep documented, do not fix
  now** -- the first occurrence is still logged correctly; only a rare
  *repeat* of the same invalid `--groups` value coalesces. Fixing it would
  mean re-parsing argv a second time ahead of the real parser, duplicating
  a sensitive classification rule with its own risk of drifting out of
  sync -- worth a dedicated pass with its own regressions and review, not
  a patch appended to an already-over-budget correction cycle.
- Both reviewers independently re-verified everything from round 23 stayed
  correct: the two-pass `_log_policy_for_cmd` split covers every `$CMD`
  value by construction (including an unrecognized command, and the
  now-fixed `help`/`version`/`artifacts`/bare-invocation regression),
  `OMABACKUP_TUI_SUPERVISED` is scoped only to the two bare-interactive
  branches (not `config set`/`restore --apply`, so a supervised session's
  own real mutating actions still log normally), and the atomic
  service-file write pattern itself (temp in the same directory, `-s`
  check, `chmod --reference`, `mv -f` only on success) is correct in
  isolation -- `omabackup-rev-2`'s own independent full-suite run came
  back **1155 passed, 0 failed**, matching this session's own count.
- 3 new regressions in `test/log.test.sh` (67 total): the RETURN trap
  extracted directly out of `bin/omabackup` (not a frozen copy) and
  replayed to confirm INT stays bound afterward -- the highest-priority
  of the three, since it is the actual false-"ok"-reopening fix; a
  malformed source unit's `_rewrite_execstart` failure proven contained to
  that one unit (the other unit still refreshes, and `reload` still
  reports success) rather than aborting `reload` outright; and Settings
  opened from Restore's own recovery menu proven to get its own log
  record instead of silently inheriting the outer session's
  `OMABACKUP_TUI_SUPERVISED` suppression.
- This is correction round 3, past the review protocol's 2-round budget;
  both reviewers explicitly agreed this should be the last automatic
  round ("Concordo que esta seja a última rodada automática" --
  `omabackup-rev-2`). The two items above that were not fixed this round
  are reported to the user rather than resolved unilaterally or taken to
  a fourth round.
- Full suite: **1163 passed, 0 failed**.

## Two more marketplace security findings: an unbounded restore extraction, and Panel.qml process/output containment

Follow-up on issue #3968 after the AGENTS.md fix (`cd4857e`): `HANCORE-linux`
flagged two more blockers at HEAD `cd4857e`, unrelated to logging.

**1. `lib/bundle.sh:482` (`_zstd_extract`) -- restore decompressed an
artifact fully before verification, with no size limit at all.** A shared
destination is not a trusted source, and `verify_bundle`/`cmd_restore` both
extract BEFORE checking anything -- extraction has to happen to have
something to check. zstd's ratio is not bounded by the compressed file's
size on disk (a 1.6KB archive of 50MB of zeros, built and measured live,
decompresses to the full 50MB), so a hostile or corrupted artifact could
fill the disk before the checksum/clone check ever ran. Fixed with `head -c`
between `zstd -dc` and `tar -x` in the same pipe -- the archive file itself
is still read exactly once, matching this function's own existing
reasoning about checking a real pipe rather than a process substitution --
so an oversized decompressed stream is cut off before `tar` writes past
the cap; the existing `pipefail` handling turns tar's resulting "unexpected
EOF" into the function's own failure, same as any other extraction
failure. 4 GiB default (`OMABACKUP_RESTORE_MAX_BYTES` to override) --
generous for what this tool actually backs up (this repo's own dotfiles
archive measures ~1MB) while still bounding the worst case to a fixed
number. Also bounds the worst-case tar member count, since every entry
costs at least one 512-byte header in the exact stream the cap applies to
-- no separate member-count check was needed on top of it. Verified live:
the 50MB bomb above, under a 1MB test cap, left disk usage at ~999KB, not
50MB. 5 new regressions in `test/bundle.test.sh` (57 total): the fixture
really is lopsided (archive < 10KB, decompressed > 40MB), the bomb is
refused and bounded, a real legitimate bundle far under the cap still
extracts cleanly, and `restore` itself refuses a bomb artifact the same
way it refuses any unextractable one.

**2. `Panel.qml:594-668,718-824` -- QuickShell's own `Process` has no
group-kill, and `StdioCollector` has no size cap.** Design consultation
(`herdr-ask` round `omabackup-11`) before any QML was written, since this
touches production UI code with no live QuickShell/Wayland environment to
test interactively in this session by hand -- both reviewers gave
substantive, partly-converging, partly-diverging positions; `omabackup-rev`
proposed wrapping in `timeout`, `omabackup-rev-2` proposed reusing
`bin/omabackup-tui`'s own already-hardened `_group_pgid_wait`/
`_stop_group` via a new subcommand instead of a second QML implementation.
Confirmed directly against `quickshell-mirror/quickshell`'s own source
(the 0.3.1-1 build installed on this machine): `process.cpp` shows
`running = false` calls `QProcess::terminate()` and `signal()` calls a
bare `kill(pid, signal)` -- both target one PID, never a group; a timed-out
`verify`/`status`/`sync`/`collect`/enable-disable that was itself blocked
on a `git`/`rsync` child left that child orphaned. `datastream.hpp`/`.cpp`
confirm `StdioCollector` appends every chunk to one `QByteArray` forever,
no cap anywhere.

Live-verified the one premise both reviewers flagged as needing it
(`omabackup-rev-2`, explicitly: do not merge before checking) rather than
assuming: a throwaway, isolated `qs -p <probe>.qml` (no panel config
touched) confirmed QuickShell's own `Process`-spawned children do NOT get
their own process group (`ps -o pid=,pgid=` showed the two differ) --
exactly what makes `setsid --` in front of a command work as designed (a
caller that is not already a process-group leader is what makes `setsid`
exec in place rather than fork, per its own manual page).

Fixed, synthesizing both reviewers' positions rather than picking one
wholesale:

- **Process-group containment**: a new internal subcommand,
  `omabackup kill-group <pid>`, reusing the shape of
  `bin/omabackup-tui`'s own hardened group-kill logic rather than a second
  implementation in QML with no test suite exercising it (`omabackup-rev-2`'s
  recommendation). Stricter than the tui wrapper's own version on purpose:
  requires `pgid == pid` (the target really is its own group's leader)
  rather than accepting any pgid that is merely not the caller's own --
  correct because this subcommand is always invoked well after the target
  started (no fork-vs-exec race to accommodate, unlike the tui wrapper's
  own narrow post-fork window). Also refuses `pgid == 1` explicitly, found
  while writing its own test: `kill -- -1` is not "process group 1", it is
  POSIX's own broadcast case ("every process the caller has permission to
  signal") -- caught and fixed before ever exercising it for real, not
  discovered by running it. `verify`/`status`/`sync`/`collect`/
  enable-disable's own `command` in Panel.qml is wrapped in `setsid --`;
  `busyTimeoutTimer`'s `onTriggered` now calls `root.killGroup(pid)` with
  the PID captured in the same statement `timedOut` is set, before
  `running = false` (which reads `processId` back as `null`). 8 new
  regressions in `test/panel.test.sh` covering the subcommand directly
  (group-kill success including the spawned child, the own-group-leader
  guard's fallback to single-pid, non-numeric-pid rejection, the pgid-1
  broadcast guard via isolated `ps`/`kill` function stubs -- never a real
  `kill -1`, the manifest exemption), plus a new headless QuickShell probe
  (`test/qml/timeout-kills-descendant.qml`, matching this file's own
  established `qs -p` probe methodology) proving the QML wiring itself --
  not just the subcommand in isolation -- actually reaches and kills a
  descendant process.
- **Output byte cap**: `omabackup-rev-2`'s stronger argument, verified
  directly against `datastream.cpp` rather than taken on its own premise --
  `SplitParser`'s default `\n` delimiter would not have helped the actual
  hot path (`verify --json`/`status --json` are single-line JSON, so the
  delimiter is never reached until the stream ends, same as
  `StdioCollector`) -- confirmed `SplitParser { splitMarker: "" }` emits
  every chunk immediately via `read()` and never buffers internally
  (`datastream.cpp`'s own empty-marker branch, read directly). `verifyProc`/
  `statusProc`'s `stdout` uses that, feeding a new
  `root.accumulateCapped(proc, chunk)` that owns the actual 256 KiB cap
  (`root.maxOutputBytes`), latches a distinct `outputCapped` flag once
  crossed (checked before `timedOut` in `onExited`, so a truncated buffer
  never reaches `applyReport`/`applyStatus` as though it were valid JSON),
  and kills the process the same way a timeout does (group and all, via
  `killGroup`) rather than merely stopping this function's own
  accumulation while the process keeps running. Documented honestly as a
  consumer-side (QML) cap using JS string length (UTF-16 units), not a
  byte-exact producer-side guarantee -- `omabackup-rev-2`'s own explicitly
  acceptable fallback when a byte-exact guarantee is not required, chosen
  over restructuring `bin/omabackup`'s two separate JSON-output sites
  (`report()` for verify, a second inline `jq -n` call for status) into a
  producer-side cap, given the added risk of touching well-established
  reporting code for a lower-confidence attack surface: verify/status read
  only this machine's own local, bounded configuration, never
  attacker-controlled input the way `restore`'s artifact is. Buffers and
  the latch are reset at the start of every run (`refresh()`), not just on
  exit, so a capped run does not read as capped forever. 1 new headless
  probe (`test/qml/output-cap-stops-accumulating.qml`): a well-formed
  small output survives byte-for-byte, a 4000-byte single-line (no
  newline at all) output past a 1000-byte test cap latches
  `outputCapped`, stops growing, and triggers the kill path.
- **Not applied to `sync`/`collect`/`switchProc`'s `stderr` collectors**:
  `omabackup-rev-2` pushed back on how this was first framed here (round
  omabackup-25) -- worth stating precisely rather than as an open
  question implying there is a security boundary between them. The
  declared threat model is a compromised or malfunctioning CLI; that
  model does not distinguish stdout from stderr, and these three
  `errBuffer` collectors are the exact same uncapped `StdioCollector` as
  everything else was before this fix -- a CLI that floods stderr in a
  loop grows the panel's memory exactly the same way. This is a
  **triage decision**, not a principled split: `verify`/`status`'s stdout
  was the specific single-line-JSON hot path both reviewers' arguments
  were actually about, so it went first. The other three remain the same
  exposure this whole entry describes, just not yet covered -- see "Open
  questions" below; the same `accumulateCapped`/`SplitParser` pattern
  extends to them directly.
- Full suite: **1180 passed, 0 failed** as of this entry; see round
  `omabackup-25` below for what a real review round found on top of it.

### Review round `omabackup-25`: a process-group suicide bug, a race the whole fix existed to close, and a `head -c` sign flip

`herdr-review` on the process/output hardening above found six real
problems, one from `omabackup-rev-2` and five from `omabackup-rev` --
the two most severe both live-reproduced, not just reasoned about:

- **CONFIRMADO, most severe -- `omabackup-rev-2`'s finding, `omabackup-rev`
  independently found the same class one branch over** -- `cmd_kill_group`
  accepted `0` (and, separately, `1`) as a numeric pid. For `0`: `ps -p 0`
  produces no valid pgid, so `_kg_stop_group` falls to its single-pid
  branch and runs a bare `kill -TERM "$pid"` -- and `kill(2)` gives pid `0`
  its own POSIX special case, distinct from the `-1` broadcast this file
  already guarded: it signals **every process in the caller's own process
  group**. Since `omabackup kill-group` shares QuickShell's own group
  whenever invoked normally (the exact premise `setsid --` exists to
  escape), `kill-group 0` would have SIGTERM'd the whole panel/bar.
  Reproduced live, twice: `omabackup-rev-2` in an isolated session with a
  sentinel process; this session again, independently, in a `setsid --wait`
  session whose own test script died mid-run without reaching its own
  final `echo` -- not merely predicted. For `1`: a legitimate pid
  (init/systemd) that `_kg_stop_group`'s own `pgid != 1` guard correctly
  refuses as a GROUP target, but that refusal falls through to the same
  single-pid branch, which would run `kill -TERM 1` against the real init
  process. Fixed by tightening `cmd_kill_group`'s own input validation to
  `^[1-9][0-9]*$ && "$pid" != 1`, rejecting both before `_kg_stop_group`
  -- and therefore before any `ps`/`kill` at all -- ever runs. 2 new
  regressions in `test/panel.test.sh`, both against the real subcommand:
  pid 0 in an isolated `setsid` session with a sentinel (dies mid-run
  pre-fix, completes normally post-fix); pid 1, safe to test directly
  since the fix rejects it before any signal is ever sent.
- **CONFIRMADO-shaped, `omabackup-rev`'s finding -- the fix's own async
  helper raced against a direct kill of the same target.** `killGroup()`
  only *starts* a separate `Process` (bash, then `lib/*.sh` sourcing, then
  its own `ps` lookup) -- not instant. Immediately after starting it, the
  SAME calling code also set `proc.running = false` on the target
  directly. If the direct kill reaped the leader first, the helper's own
  `ps -o pgid= -p <pid>` lookup then found nothing (the pid was already
  gone), fell through to a no-op single-pid signal, and the descendant --
  the entire reason this mechanism exists -- was never reached.
  `test/qml/timeout-kills-descendant.qml`'s own stand-in killer (an inline
  `sh -c 'kill -TERM -"$1"'`, near-instant) could not have caught this: it
  never raced the real subcommand's actual startup latency. Fixed by
  removing every direct `proc.running = false` from `busyTimeoutTimer` and
  `accumulateCapped` -- `killGroup()`'s own eventual signal is now the
  ONLY thing that ever touches the target, so there is nothing left to
  race, at any speed; QuickShell still detects the real exit and fires
  `onExited` regardless of who signaled it. The probe was rewritten to
  call the REAL `bin/omabackup kill-group` subcommand instead of a
  stand-in (confirmed live: the probe reproduces `PARENT_GONE`/
  `CHILD_ALIVE` -- the exact orphaning `omabackup-rev` described -- when
  pointed at the OLD racy shape, and `PARENT_GONE`/`CHILD_GONE` against
  the fix).
- **`omabackup-rev`'s P1** -- the byte cap only ever covered `verify`/
  `status`'s stdout; every stderr channel across all five processes
  (including `verify`/`status`'s own) stayed on unbounded `StdioCollector`.
  The declared threat model (a compromised or malfunctioning CLI) does not
  distinguish stdout from stderr -- a `git`/`rsync`/hook writing rapidly
  to stderr exhausts panel memory the same way, and could do it before the
  45s timeout ever catches it, `omabackup-rev`'s own words, potentially
  taking the whole bar down with it. Fixed by extending
  `accumulateCapped`/`SplitParser{splitMarker:""}` to all five processes'
  stderr too (generalized to take a `field` parameter -- `"buffer"` or
  `"errBuffer"` -- so stdout and stderr on the same process share one
  `outputCapped` latch). Found and fixed in the same pass: `errBuffer` was
  never reset between runs (`StdioCollector`'s old
  `onStreamFinished: proc.errBuffer = text` replaced the whole string
  every time, so it never needed one; the new incremental
  `proc[field] += chunk` does, or a failed run would show the PREVIOUS
  run's stderr prepended to its own) -- reset alongside `buffer`/
  `outputCapped` everywhere a run starts. `externalProc` (the detached TUI
  launcher) intentionally excluded, same reasoning both reviewers already
  agreed on for its group-kill exemption.
- **`omabackup-rev`'s P2, real, live-verified** -- `lib/bundle.sh`'s
  `OMABACKUP_RESTORE_MAX_BYTES` override reached `head -c` completely
  unvalidated. GNU `head -c` gives a **leading minus its own opposite
  meaning**: `-N` means "all but the last N bytes", not "the first N
  bytes" (confirmed live: `printf '0123456789' | head -c -1` prints all
  but the final byte). `OMABACKUP_RESTORE_MAX_BYTES=-1` would have turned
  the cap into "everything except the last byte" -- functionally
  unlimited for anything this function extracts. Fixed by validating the
  override as a canonical positive decimal (`^[1-9][0-9]*$`) before use,
  falling back to the safe 4 GiB default for anything else -- negative,
  empty, non-digit, a leading `+`, or a leading zero. 7 new regressions in
  `test/bundle.test.sh`: six non-canonical values (`-1`, `-0`, empty,
  `abc`, `+9999999999`, `007`) each confirmed to fall back to exactly
  `4294967296`, not reach `head -c` at all.
- **`omabackup-rev`'s P2, documented not fixed** -- `SplitParser`'s
  empty-marker branch converts each raw chunk to a `QString`
  independently and does not retain incomplete trailing bytes for the
  next chunk (confirmed against `datastream.cpp`'s own empty-marker code
  path). A multi-byte UTF-8 character split across two separate reads can
  arrive as replacement characters before `accumulateCapped` ever sees
  it; `jq` does not ASCII-escape non-ASCII output by default, so a real
  path, hostname, or label could in principle be corrupted this way.
  Fixing this correctly needs the cap to live in the producer
  (`bin/omabackup` itself, operating on whole, already-decoded strings)
  rather than the consumer -- a larger redesign than this round of fixes
  took on, given it was already past a lot of ground for one pass.
  Documented in `Panel.qml`'s own `accumulateCapped` comment and in "Open
  questions" below, not silently left uncovered.
- **`omabackup-rev`'s P3, already independently found and fixed from
  `omabackup-rev-2`'s own P3 in the same round** -- both `onExited`
  handlers checked `timedOut` before `outputCapped`, opposite of what
  their own comments claimed, so a run capped for output size could still
  report "timed out" if `busyTimeoutTimer`'s `running`-based guard fired
  in the same narrow async window (this file's own already-measured,
  not-synchronous `exited` delivery). Fixed by swapping the check order in
  both, clearing both flags atomically in the `outputCapped` branch.
- Full suite: **1191 passed, 0 failed**.

### Review round `omabackup-26` (correction round 2 of 2, verifying round omabackup-25's fixes): a residual dead-leader gap, and two test-quality gaps

`herdr-review` on round-25's fixes found four more problems (all from
`omabackup-rev`) and, from `omabackup-rev-2`, an explicit direct answer to
the question this round's own dispatch asked ("does anything here block
considering this done") plus two lower-severity findings of their own:

- **`omabackup-rev-2`'s explicit answer**: **no**, nothing in their review
  should block this. Both of `omabackup-rev-2`'s own findings this round
  are P3, and neither is a blocker -- both are side effects of otherwise-
  correct fixes (see below).
- **`omabackup-rev`'s P1, real and fixed** -- the async `kill-group`
  helper can still miss the whole group if the setsid-wrapped LEADER
  exits (on its own, quickly) before the helper's own startup (bash, then
  sourcing several `lib/*.sh` files) reaches its `ps -o pgid= -p "$pid"`
  lookup: once that specific pid is gone, `ps` finds nothing, and the old
  code fell through to a no-op single-pid signal against an already-dead
  pid -- never trying the group at all, orphaning any child the leader
  left behind. Fixed by no longer rediscovering the group id via `ps`:
  every legitimate caller `setsid`-wraps its target first, so the
  captured pid IS its own group id by construction, and that id keeps
  meaning the same thing even after the specific leader process exits, as
  long as any other member (an orphaned child) is still alive in it --
  `kill -0 -- "-$pid"` asks exactly that, needing no live leader to
  answer. The own-group and pid-0/1 guards move to compare directly
  against `$pid` instead of a `ps`-derived value; `_kg_stop_group` no
  longer calls `ps` for the target at all (only for its own pgid, to
  check the own-group refusal). 4 new regressions in `test/panel.test.sh`:
  `_kg_stop_group` called directly with 0 and 1 (bypassing
  `cmd_kill_group`'s own validation, proving the second guard holds on
  its own too), and the actual dead-leader case reproduced directly (a
  `setsid`-wrapped leader that forks a child and exits immediately,
  confirmed dead before `kill-group` is even invoked, not raced) --
  `kill-group` still reaches the child.
- **`omabackup-rev`'s P2, test-quality, fixed** -- `test/qml/
  output-cap-stops-accumulating.qml` had drifted: it defined its own
  local copy of `accumulateCapped`/`killGroup` for isolation, but that
  copy still matched an EARLIER shape of the real functions (a direct
  `proc.running = false`, a 2-argument signature) -- silently passing
  while testing behavior Panel.qml no longer has. Re-synced to the
  current 3-argument (`proc, field, chunk`) shape and the no-direct-kill
  design, with an explicit comment that this is a hand-maintained mirror,
  not an import, and will drift again if `Panel.qml`'s own functions
  change without this file being updated too -- moving them to a shared
  `.js` module Panel.qml would import was judged out of scope for this
  round. Separately, `test/qml/timeout-kills-descendant.qml` used fixed
  `/tmp` filenames (risking a stale file from an interrupted or
  concurrent run being read as this run's own) and treated `kill -0 ""`
  on an empty/missing pid file the same as "confirmed dead" -- a
  precondition failure (the target never starting, the pid files never
  being written) could have silently read as success. Fixed: unique
  per-run filenames (`Date.now()` plus a random suffix), and the checker
  now requires both pid files to hold an actual decimal pid before
  treating either as meaningful, reporting a distinct
  `PARENT_PID_MISSING`/`CHILD_PID_MISSING` otherwise rather than folding
  into the same result as "gone."
- **`omabackup-rev-2`'s P3, documented not fixed** -- `killGroup()`
  starting a Process is now the ONLY path that ever stops a timed-out or
  output-capped target (round omabackup-25's own fix for the race
  `omabackup-rev` found). But if that helper Process fails to even start
  (`killer.running = true` never actually execs, for whatever reason),
  nothing recovers: `onExited` never fires, and `checking`/`syncing`/
  `busy` stay stuck forever -- the panel would show every action disabled
  with no way out. Before round omabackup-25, `running = false` was a
  synchronous, always-succeeding action inside the panel's own process;
  the fix traded a real race for removing that guaranteed fallback.
  `omabackup-rev-2` rates this narrow (`root.cli` is a path `resolveProc`
  already validated once and never clears, so a failed `exec` of it is
  unlikely) and suggests a specific, race-safe recovery: re-arm
  `busyTimeoutTimer` once (or a second, short timer) after the first
  timeout, and on THAT second firing, if the process is still `running`,
  fall back to a direct `proc.running = false` -- which by then does NOT
  reopen the original race, since the race was specifically "a direct
  kill emitted immediately, before the helper's own `ps` lookup runs";
  one emitted seconds later gives the helper every chance first. Not
  implemented this round (see "Open questions" below) -- a genuine new
  behavioral change on top of an already-large round of fixes, better
  reviewed on its own than folded in under this round's budget.
- **`omabackup-rev-2`'s P3, documentation fixed** -- the round-25 UTF-8
  deferral note was written describing the JSON stdout channel
  specifically, but round 25 itself extended the same `SplitParser`/
  `accumulateCapped` pattern to all five processes' stderr in the same
  pass -- and stderr is where human-readable error text carrying real
  user paths lives, if anything MORE likely to be non-ASCII than jq's own
  JSON, not less. Neither document connected the two decisions. Fixed:
  `Panel.qml`'s own comment on `accumulateCapped` now says the exposure
  spans all five stderr channels too, not just the original two JSON
  ones; not a behavior change, a scope correction to the existing note.
- Full suite: **1194 passed, 0 failed**.
- This is correction round 2 of the (separate, fresh) 2-round budget for
  round omabackup-25's own findings; `omabackup-rev-2` gave an explicit
  answer that nothing found this round should block considering the work
  done, and the one item deliberately not fixed
  (`omabackup-rev-2`'s backstop-timer suggestion) is reported to the user
  below rather than taken to a further round.

### Both open items from rounds omabackup-25/26, arbitrated by `omabackup-scout`

The user asked for `omabackup-scout` (this workspace's read-only arbiter
agent) to decide the two items above rather than deciding either alone.

- **UTF-8 corruption in `SplitParser`'s empty-marker mode**: decided
  **accept the documented state, do not move the cap to the producer
  now**. Scout's reasoning: the QML-side cap already achieves its actual
  security goal (bounded panel memory); the residual defect only rarely
  corrupts DISPLAYED text or could make `xdg-open` fail on a mangled
  path -- it does not alter what any command does or write bad data.
  Moving the cap to the producer would mean a cross-cutting redesign
  spanning two JSON stdout channels and five stderr channels,
  disproportionate to a cosmetic impact. This directly resolves
  `omabackup-rev`'s P2 (wanted a real fix) versus `omabackup-rev-2`'s P3
  (cosmetic, documentation-only) severity disagreement from round
  omabackup-25/26 -- both were reasoning from the same facts, genuinely
  disagreeing only on how much the cosmetic impact was worth fixing now.
- **`killGroup()`'s missing fallback if its helper Process never actually
  stops the target**: decided **implement the two-stage backstop now**.
  Scout's reasoning: permanently locking `busy` (every panel action
  disabled, no recovery short of restarting the panel) is a liveness
  failure with no internal recovery path at all -- categorically worse
  than a narrow race window, regardless of how rarely the helper actually
  fails to start. A short second timer that only acts if the helper
  genuinely did not resolve the target is small and safe; explicitly
  confirmed safe against round omabackup-26's own fix specifically
  (`_kg_stop_group` no longer needs to find a *live* leader via `ps` --
  it trusts the setsid-captured pid as the group's own id directly, so a
  delayed fallback has nothing left to race against).
- **Implemented**: `killGroup(proc)` now takes the whole process object
  (not just its pid, needed so the backstop can check `proc.running`
  later) and arms a 3-second one-shot `Timer`, created the same way the
  helper `Process` already is, alongside spawning the helper. On firing,
  if the target is somehow STILL `running`, it falls back to a direct
  `proc.running = false` -- QuickShell still detects the real exit and
  fires `onExited` regardless of who or what actually stopped the
  process. Does not fire early or interfere when the helper already
  succeeded (the target is no longer `running` by the time the timer
  checks). 1 new headless probe,
  `test/qml/killgroup-backstop-rescues-stuck-helper.qml`: one target
  whose "helper" is a plain `true` (starts, does nothing, standing in for
  a helper that never signals anything at all) is still recovered by the
  backstop; a second target alongside it, whose helper is a real,
  working `kill`, is unaffected by the backstop existing at all.
  Confirmed against a variant with the backstop code removed that the
  broken-helper target stays stuck (`running` never becomes `false`) --
  fail-before/pass-after, not just a passing assertion.
- Full suite: **1195 passed, 0 failed**.

### Maintainer re-review of `fc9f51a`: a member-count bomb the byte cap's own math didn't actually close

`HANCORE-linux` re-reviewed the pushed commit directly on issue #3968 and
confirmed the panel fix and byte ceiling both address the prior findings,
but found one more real gap in `lib/bundle.sh:510-535`: this file's own
comment had claimed the byte cap "also caps the worst-case entry count at
roughly BYTES/512" -- true as stated, but nobody had actually done the
division. `4294967296 / 512 = 8,388,608` -- not a meaningfully tight bound.
An archive of that many empty files (header-only entries, no content
blocks) stays nowhere near the byte ceiling while exhausting inodes and
keeping extraction busy far longer than any real restore would --
"consume millions of inodes... without approaching the byte limit," in
the maintainer's own words.

Fixed with a second, independent ceiling: `tar -xv`'s own member-by-member
progress (one line per extracted file, confirmed live to go to stdout, not
stderr) feeds a trailing `awk` that counts lines and exits 1 the instant
the count passes `OMABACKUP_RESTORE_MAX_MEMBERS` (default 100,000 --
generous against this repo's own ~1,200-file artifact, same reasoning as
the byte default). GNU tar has no native entry-count limit to reach for
instead. Once `awk`'s read end closes, `tar`'s next attempt to write
another progress line gets SIGPIPE and dies -- measured live, twice, not
assumed: 5,000 empty-file members capped at 50 stopped at 51 actually
extracted; 100,000 members capped at 1,000 stopped at 1,002, in four
milliseconds. Not exact -- tar can have a little more already in flight
when the pipe closes -- but bounded to a small, fixed overshoot instead of
the millions the byte-only cap would have let through. Confirmed live that
bash's `pipefail` still correctly reports a middle-stage failure even when
the pipeline's own last stage (`awk`) exits 0 -- the four-stage pipe (zstd
| head | tar | awk) needed this checked directly, not assumed to still
hold from the two- and three-stage cases already relied on elsewhere in
this file.

Found and fixed while writing this entry, before it ever reached a test:
an actual typo (`// closes` instead of `# closes`) in the explanatory
comment above `_zstd_extract`, which `bash -n` alone did not catch since a
bare `//` is syntactically a valid (if semantically wrong) simple command,
not a parse error.

12 new regressions in `test/bundle.test.sh` (89 total): the many-tiny-files
fixture confirmed to stay under 50KB on disk while carrying 10,000 members
(proving the fixture is genuinely a member-shaped bomb, not a byte-shaped
one); `_zstd_extract` refusing it under a lowered cap with disk usage
bounded near the cap, not the full 10,000; a real, legitimate bundle far
under the member cap still extracting cleanly; `restore` itself refusing a
member bomb the same way it refuses any unextractable artifact; six
non-canonical `OMABACKUP_RESTORE_MAX_MEMBERS` override values (mirroring
the byte override's own validation tests exactly) all falling back to the
safe default.

Full suite: **1207 passed, 0 failed**.

### Review round `omabackup-27`: a stale-backstop bug, a directory-amplification bypass of the member cap, and a silent `TAR_OPTIONS` bypass

`herdr-review` on the backstop timer (added after `omabackup-scout`'s
arbitration above) and the member-count cap (added after the maintainer's
own re-review of `fc9f51a`, below) found two real P1s from `omabackup-rev`
and two P2s. `omabackup-rev-2`'s own verdict for this round did not
complete: mid-review, they were directly interrupted by the user in their
own pane over an `rm -rf ./*` embedded in a test command they were about
to run, and the round was left there rather than re-dispatched -- this
round's fixes rest on `omabackup-rev`'s findings alone; `omabackup-rev-2`'s
own independent pass on this specific diff is still open.

- **P1, `Panel.qml` -- the backstop timer could kill a brand new run, not
  just the stale one it was armed for.** `verifyProc`/`statusProc`/
  `syncProc`/`collectProc`/`switchProc` are singleton `Process` objects,
  reused across runs (`refresh()`/`syncNow()`/etc. all set `running =
  true` again on the SAME object). The backstop's own callback only
  checked `proc.running`, not which run it was watching: if the helper
  killed the OLD run quickly and the operator started a brand NEW run of
  the same object within the backstop's own 3-second window, the stale
  backstop would see the new run as "still running" and kill it directly
  -- a single-PID kill capable of reopening the exact descendant-orphaning
  problem the whole mechanism exists to close, on a run it was never armed
  for. Fixed by also comparing `proc.processId` against the pid captured
  when that specific backstop was created -- a no-op for any run other
  than the one it is actually watching. New headless probe,
  `test/qml/killgroup-backstop-ignores-stale-run.qml`, driven by
  `runningChanged` rather than fixed delays: kills a first run, starts a
  second the instant the first is observed dead, and confirms the second
  survives past the stale backstop's own window. Confirmed
  fail-before/pass-after against the un-fixed comparison (the second run
  died too, `deathCount=2`).
- **P1, `lib/bundle.sh` -- the member-count cap counted tar's own
  progress lines, not the filesystem objects extraction actually
  creates.** GNU tar silently creates every missing intermediate
  directory a member's path implies, and none of those auto-created
  directories get their own line in `-v`'s progress output -- only the
  one explicit member does. Confirmed live: a SINGLE crafted member at a
  500-level-deep path (built with `tar --transform`, remapping a flat
  file's name, since a real filesystem would need the directories to
  already exist first) produced exactly one progress line but created
  502 real filesystem entries on extraction. A flat per-member cap read
  that as "1", nowhere near any reasonable ceiling regardless of how deep
  the path actually went -- the scalable version of this attack is many
  members, each moderately deep, none individually alarming. Fixed with
  a weighted cost per member (`1 + slash count in the reported path`)
  instead of a bare count, deliberately not deduplicated against shared
  prefixes between siblings (that would need an unbounded set of seen
  paths to track precisely -- itself a resource an adversarial archive
  could grow without bound; a conservative per-member estimate needs no
  such structure). A flat archive of shallow files behaves exactly like
  the original bare-count cap. A new, separate `OMABACKUP_RESTORE_MAX_DEPTH`
  (default 64) additionally refuses any SINGLE member whose own path is
  absurdly deep outright. Documented honestly, not glossed over: for the
  single-pathological-member case specifically, tar fully extracts one
  member -- parent directories included -- before it ever prints that
  member's own progress line, so detection necessarily comes after that
  one entry's damage, not before it; bounded regardless by the OS's own
  `PATH_MAX`, not by how many times an attacker repeats the pattern. 6
  new regressions in `test/bundle.test.sh`: the deep-path fixture
  confirmed to genuinely be one member with 500+ `/` characters in its
  own path; `_zstd_extract` refusing it under the depth guard; a real,
  legitimately-nested path (a handful of levels) still extracting
  cleanly; six non-canonical `OMABACKUP_RESTORE_MAX_DEPTH` override
  values falling back to the safe default.
- **P2, `lib/bundle.sh` -- an inherited `TAR_OPTIONS` environment
  variable could silently defeat the member cap entirely.** GNU tar
  prepends `TAR_OPTIONS`'s contents to its own argv; confirmed live that
  `TAR_OPTIONS=--index-file=/dev/null` redirects `-v`'s progress output
  away from stdout completely, so the counting `awk` reads EOF
  immediately, counts zero, and every member extracts with no cap in
  effect at all -- regardless of how `OMABACKUP_RESTORE_MAX_MEMBERS`/
  `_MAX_DEPTH` are configured. Fixed with `env -u TAR_OPTIONS` (does not
  inherit the variable at all) AND an explicit `--index-file=/dev/stdout`
  placed after it (confirmed live that an explicit option wins over a
  prepended one, the ordinary last-one-wins rule for a single-valued tar
  option) -- kept alongside `env -u`, not instead of it, since relying on
  option-ordering precedent alone is a thinner guarantee than simply not
  inheriting the variable. 1 new regression in `test/bundle.test.sh`:
  the many-tiny-files bomb from the member-count fix, re-run with
  `TAR_OPTIONS='--index-file=/dev/null'` set, still refused and still
  bounded.
- **P2, `test/bundle.test.sh` -- the member-count bomb fixture's own
  build steps were not checked for success.** The file-creation loop and
  the `tar | zstd` pipeline building the many-tiny-files fixture had no
  exit-status checks; a silently-failed fixture (disk full, a corrupted
  write) could have left an empty or missing archive, and the
  assertions after it would still have read as "small", "refused", and
  "bounded" for the wrong reason -- never reaching the real counting
  pipeline at all. Fixed: each fixture-building step now fails loudly if
  it fails, and a real listing of the built archive (not the loop's own
  upper bound) asserts the true member count (10,001 -- 10,000 files
  plus the directory entry itself), proving the fixture actually is what
  the test claims rather than assuming the build commands worked.
- Also found and fixed while writing the fix, before any test ever
  touched it: a literal typo (`// closes` instead of `# closes`) in the
  explanatory comment above `_zstd_extract`'s own byte-cap section, which
  `bash -n` alone did not catch (a bare `//` is syntactically a valid, if
  semantically wrong, simple command, not a parse error).
- Full suite: **1222 passed, 0 failed**.

**`omabackup-rev-2` completed their own round-27 verdict afterward,
independently: `APPROVE`, no new findings.** Their review had been left
mid-task (the `rm -rf ./*` interruption above); after redoing their own
tests safely (a fresh `mktemp -d` per extraction, zero removals -- the
old, abandoned scratch directory was deleted only afterward, with the
user's explicit go-ahead), they confirmed:

- **The backstop bug independently**, by reading the code alone, before
  seeing this document's own fix -- the exact same P1 `omabackup-rev`
  found, described down to the same realistic trigger sequence (timeout
  fires, operator clicks "Check again" within the 3-second window, the
  stale backstop kills the healthy new run). Verified the fix already in
  the file matches what they would have proposed.
- **No bypass of the member/depth cap via a newline in a member's own
  name** (question 2 from the round-27 request): GNU tar's default
  quoting escapes an embedded `\n` as the literal two characters `\`+`n`
  in `--index-file`'s output, keeping one progress line per member --
  tested across quoting styles (`literal`/`shell`/`escape`, all
  consistent) and entry types (regular, directory, hardlink, symlink,
  FIFO, and a 250-character name needing a GNU extension header -- 7
  members, 7 lines). A genuine side finding: `env -u TAR_OPTIONS` (added
  for the `/dev/null`-redirect bypass) turns out to ALSO be load-bearing
  here -- `TAR_OPTIONS="--quoting-style=literal"` turns escaping off and
  splits one member across two lines (6 members read as 7). Harmless for
  the count specifically (it overcounts, so the cap fires earlier, not
  later) but worth keeping documented so the `env -u` is never removed
  later on the mistaken belief it only mattered for the other bypass --
  added to the comment above `_zstd_extract`.
- **A SIGPIPE-truncated extraction does not leave an observable partial
  last file** (question 3): tested with 30 MiB-sized files and a low cap
  -- tar died from SIGPIPE between complete members, not mid-write, and
  every file on disk measured exactly its real size. More load-bearing
  than that specific test result, though: all three of `_zstd_extract`'s
  own callers already `rm -rf` the destination directory on any failure,
  so nothing downstream ever observes a failed extraction's contents at
  all, partial or not -- the cap failing is what makes this question
  moot regardless of buffering specifics.
- **One no-severity nit**: `OMABACKUP_RESTORE_MAX_MEMBERS`'s own name
  suggests a flat count, but it governs the weighted cost described
  above -- a path nested one level deep already costs 2 per member, not
  1. The internal comment already explained the weighting; added a
  sentence to the override's own user-facing documentation too, so
  raising the value further than the literal member total suggests is
  understood as sometimes legitimately necessary, not a sign something
  is wrong.
- Their own independent `./test/run.sh` matched exactly: **1207 passed,
  0 failed** (the count at the time their review started, before this
  session's own subsequent full-suite runs above).

Full suite after both documentation additions: **1222 passed, 0
failed**.

### A requirement from the maintainer's own comments, missed until re-reading them closely: an extraction-time ceiling

Two things the maintainer had already asked for, in writing, in prior
comments on issue #3968, were not (fully) acted on the first time --
found on a careful re-read the user explicitly asked for, not a new
review round:

- Their SECOND comment (on `cd4857e`) already said "without
  compressed/uncompressed byte **and member** limits" -- the member cap
  did not land until round omabackup-25's follow-up, a full round later
  than it could have.
- Their THIRD comment (on `fc9f51a`) asked to "enforce a separate
  practical member-count **(and extraction-time)** ceiling" -- the
  extraction-time half was never implemented, and the reply comment sent
  back didn't even mention it.

Fixed now: `_zstd_extract`'s entire 4-stage pipe (`zstd | head | tar |
awk`) is wrapped in `timeout`, a wall-clock ceiling independent of the
byte/member/depth ceilings, which only bound WHAT gets written, not HOW
LONG getting there can take on a machine whose disk or filesystem this
project has no visibility into. `timeout` without `--foreground` creates
its own process group for the command it launches and signals that whole
group on expiry (the same fact already relied on for Panel.qml's own
`kill-group` design, cited there against the coreutils source) -- so
timing out here reaps zstd/head/tar/awk together, not just whichever
process `timeout` directly spawned. The pipe itself moved into a
`bash -c` child (so `timeout` has one process to launch and manage), with
every value it needs -- archive path, byte cap, dest, member cap, depth
cap, and the awk program text itself -- passed as positional arguments
rather than interpolated into the script string, keeping the whole thing
to one level of quoting. `OMABACKUP_RESTORE_TIMEOUT_SEC` (default 120s)
follows the exact same validation discipline as the other three
overrides.

Verified live, not just by reading `timeout`'s own man page: a real,
valid, tiny archive fed through a held-open FIFO one byte at a time with
a real delay between each (simulating a slow disk without needing one)
was killed at almost exactly a configured 2-second ceiling (`124`, GNU
coreutils' own timeout exit code; measured wall-clock `2.002s`, not the
full slow-write duration), with zero surviving zstd/tar/awk processes
afterward -- confirming the whole group, not just one stage, actually
gets reaped.

Found and fixed in the same pass: `timeout` is a genuinely new
dependency this introduces (part of the same GNU coreutils package as
`head`/`tail`/`mv`/`cp`/`chmod`, already required elsewhere, so free to
actually depend on) -- `test/deps.test.sh`'s own `DEPS_CORE` list, the
project's canonical declaration of every tool it legitimately expects,
did not include it, and a restricted-PATH test that deliberately excludes
only `hostname` broke on the new, unanticipated `timeout: command not
found`. Fixed by adding `timeout` to that list, and to `require_tools` at
every call site that can reach `_zstd_extract` (`cmd_bundle`, `cmd_push`,
`cmd_restore`) -- a clean, explicit "missing tool" message up front
instead of a confusing mid-pipe failure if it is ever genuinely absent.

9 new regressions in `test/bundle.test.sh`: the slow-FIFO scenario above
(one for the timeout firing, one for the whole process group being gone
afterward); a real, legitimate bundle extracting cleanly under a short
but reasonable configured ceiling; six non-canonical
`OMABACKUP_RESTORE_TIMEOUT_SEC` override values each falling back to the
safe default.

Full suite: **1233 passed, 0 failed**.

### Round omabackup-28 review of the extraction-time ceiling: a real gap in it, closed

`herdr-review` dispatched on the extraction-time-ceiling work above.
`omabackup-rev` found one P1, since fixed; `omabackup-rev-2` found two P3s
(also fixed) and confirmed the positional-parameter quoting airtight
against hostile paths (embedded quotes, tabs, newlines, a leading `-`
failing closed) with no new bypass.

- **P1 (`omabackup-rev`) -- the nested `timeout` process group escapes
  the caller's own supervision.** `timeout` without `--foreground`
  creates its own PGID for the pipe it launches, separate from whatever
  group the real caller (`bin/omabackup-tui`'s `CLI_PGID` tracking, or a
  bare terminal's own Ctrl-C) would signal. Reproduced live with real
  PIDs: a `TERM` sent to the simulated CLI's own process group left both
  `timeout` and its child alive; an `INT` on the outer group left the
  waiting shell's trap un-run after a full second. Fixed by having
  `_zstd_extract` itself forward HUP/INT/TERM into the nested group: save
  any pre-existing trap for each signal (`trap -p`, the same idiom
  `lib/tui.sh`'s `tui_read_line` already uses), install a temporary
  forwarding trap, `wait` once, and on interruption poll with `kill -0`
  (not a second `wait` -- confirmed live that a second `wait` on an
  already-once-interrupted pid can simply hang rather than detect the
  child's real later exit) until the group is actually gone, then restore
  the original traps exactly and return the standard 128+signal code
  (129/130/143). Getting there needed working around two genuine bash
  `wait`/trap subtleties beyond the one above, both confirmed live before
  landing on this design: a background (`&`) job in a script inherits
  SIGINT as `SIG_IGN` (POSIX), so a trap installed *inside* it has no
  effect -- irrelevant to the production fix itself (the pipe's stages
  install no traps of their own) but the reason one early test needed
  `env --default-signal=INT,QUIT`; and `wait "$PID"` returns as soon as
  ANY trapped signal reaches the *calling* process, regardless of whether
  `$PID` has actually exited yet.
- **P3 (`omabackup-rev-2`) -- `timeout` without `--kill-after` does not
  actually guarantee the ceiling it exists to guarantee.** Measured live:
  a child that ignores TERM still returned `124`, but only after 20 real
  seconds under a configured 3s limit -- the exit code lied about the
  ceiling having been respected. `--kill-after=5s` added, matching the
  idiom already used everywhere else in this codebase `timeout` is a real
  control (`bin/omabackup-tui`, `test/config.test.sh`,
  `test/log.test.sh`, `test/vm/run.sh`, and `test/vm.test.sh` which
  itself asserts the flag's presence) -- this was the one place it had
  been missing. Honest limit noted in the review and kept in the code
  comment: `--kill-after` closes "ignores/is slow to handle TERM", not a
  stage blocked in kernel I/O wait (state `D`), which cannot be signaled
  at all until its syscall returns.
- **P3 (`omabackup-rev-2`) -- `timeout`'s own distinct `124` was being
  thrown away into a generic, alarming message.** All three call sites
  (`verify_bundle`, `_verify_cache_entry`, `cmd_restore`) collapsed every
  extraction failure -- corrupted artifact, decompression bomb, *or* a
  legitimate restore from slow media that genuinely exceeded the ceiling
  -- into the same `return 1` / "could not extract". Fixed at the
  highest-visibility site: `cmd_restore` now distinguishes `_extract_rc
  == 124` and names `OMABACKUP_RESTORE_TIMEOUT_SEC` directly in the
  message, so a slow-pendrive restore reads as "raise this if the artifact
  is legitimately large" instead of implying corruption. The other two
  call sites (local build/cache self-checks, not user-facing restores in
  the same way) were left generic -- lower priority, not blocked on
  anything.
- Also cleaned up per `omabackup-rev-2`'s review, both nits rather than
  findings: `--` added before both paths in the child pipe
  (`zstd -dc -- "$1"`, `tar -C "$3" ... -- `) as free defense-in-depth
  against a legitimate path starting with `-`, even though no real
  caller can reach that today; and a comment added at the
  `OMABACKUP_RESTORE_MAX_MEMBERS`/`_MAX_DEPTH` validation noting the
  `^[1-9][0-9]*$` regex is load-bearing for a second reason beyond
  numeric sanity -- both values are later passed as `awk -v`, which
  interprets backslash-escape sequences in `-v` values (POSIX/gawk
  behavior), so restricting them to bare digits first also forecloses
  escape-sequence injection through `-v`.
- `omabackup-rev`'s own P3 against the *test* fixtures (not the
  production fix): the slow-FIFO producer test helper fed bytes through
  `read -r -n1 -d '' | printf '%s'`, and a bash variable cannot hold a
  NUL byte -- reproduced live against a real `tar | zstd` stream from
  this repo (1,283 bytes, 14 of them NUL, came out 14 bytes short through
  that loop), meaning the "byte-exact slow source" the tests claimed to
  build was never actually proven byte-exact. Fixed by replacing the
  loop with a shared `_slow_feed_fifo` helper that moves each byte
  through `dd` on an open FD instead of a shell variable, plus a new,
  dedicated regression that feeds a source built from literal bytes
  including several NULs through the helper and asserts the reproduced
  stream is byte- and hash-identical to the source -- proving the
  property the later timeout/signal tests depend on, rather than
  assuming it.

Full suite after this round's fixes: **1250 passed, 0 failed**.

### Round omabackup-29: the round-28 test fixes needed their own review, and had a real gap

Dispatched narrowly, on just the two round-28-response changes above (the
`_slow_feed_fifo` helper and the `awk -v` comment) -- explicitly scoped
to skip re-reviewing the already-reviewed signal-forwarding/`--kill-after`/
rc=124 layer itself. Both reviewers converged on the same gap, from
different angles: `omabackup-rev` (P3) and `omabackup-rev-2` (nit, but
endorsing the same fix) both found `_slow_feed_fifo` never checked its own
`stat`/`exec`/`dd` exit status -- a mid-run `dd` failure would silently
feed fewer bytes than the source, which is the exact shape of defect this
helper exists to close, just relocated one level down. Fixed: each step
now fails fast and closes the FIFO on error instead of continuing past a
silent short feed; the NUL-byte proof test now asserts the feeder's own
exit code is 0 instead of discarding it.

`omabackup-rev-2` additionally verified, independently and exhaustively,
that the fix actually holds: fed all 256 possible byte values (not just
NUL) through the real helper and confirmed an identical hash out; ran the
old `read -r -n1 -d ''` loop side by side against a NUL-containing source
and confirmed it really did fail before this round's fix (a genuine
fail-before/pass-after, not assumed); confirmed `status=none` suppresses
only `dd`'s own summary line, never its error diagnostics or exit code;
and confirmed the `awk -v` comment's claim and scope directly, including
which two of the four overrides are and are not `awk -v`-bound. No
disagreement between the two reviewers, and no findings against the
already-reviewed round-28 layer resurfaced.

Full suite after this round's fix: **1251 passed, 0 failed**.

### Two logging gaps found against a real incident, closed after design consultation

The user hit the exact scenario the persistent-log feature (above) was
supposed to explain: the panel showed `check failed` /
`config: terminal did not report completion; status refreshed`, and
today's log file had no `config` line anywhere. Investigation (Plan Mode)
found two independent gaps:

1. This machine's installed systemd units were stale -- the repo's own
   templates already carry `Environment=OMABACKUP_LOG_SKIP=1`, and
   `cmd_reload` already refreshes installed units from them on every run,
   but this machine had not run `reload` since that fix shipped, so
   `sync`/`push` timer runs were duplicating into the file log
   (~20 routine lines/day, confirmed directly). Operational, not a code
   fix -- addressed by actually running `reload`.
2. Two places in `Panel.qml` detect a real problem without ever hearing
   from a live `bin/omabackup-tui` wrapper, so neither could log anything:
   `externalRecoveryTimer.onTriggered` (no heartbeat for
   `externalRecoveryMs`, default 900s = 30x the wrapper's own 30s
   heartbeat -- **this is exactly the user's incident**), and
   `externalProc.onExited`'s `code !== 0` branch (the terminal launch
   itself failed, so there was never a wrapper process at all).

Design-consulted before writing any code (`herdr-ask`, round
omabackup-12) -- same precedent as the original logging feature itself.
Both reviewers independently converged on `Util.execArgv` (`qs.Commons`)
over `killGroup`'s disposable-`Process`-plus-backstop pattern, for a
reason the initial draft plan didn't have: `killGroup`'s `Process`
requires the *panel itself* to survive long enough to observe `exited`
and call `destroy()`, which cannot be assumed at either site (900s of
already-degraded state at one; a leaked `Qt.createQmlObject` if never
destroyed). `execDetached`'s child is independent of the panel's own
lifecycle. Both reviewers also converged on keeping a `timeout` bound on
the dispatch (since `execDetached` gives no way to observe a hang), with
one reviewer (`omabackup-rev-2`) finding, by reading `lib/log.sh`
directly, that `_log_write` appends its line *before* it ever reaches its
own `flock -x -w 5` -- meaning the initially-proposed matching `5s`
external timeout was only safe by an unwritten internal ordering; raised
to `10s`, with a comment explaining why, to stop depending on that
coincidence.

Also settled by consultation: the outcome field must read `failed
(no heartbeat)` / `failed (launch)`, not free text -- the log's existing
outcomes are `ok`/`failed (exit N)`/`failed (signal X)`/`still failing
(exit N)`, and a human `grep failed`-ing the file after an incident
(confirmed to be the actual use case -- this whole investigation started
because that grep came up empty) needs to catch these two new lines the
same way. And a possible "duplicate" -- the wrapper eventually completing
and logging its own real outcome shortly after the panel already gave up
-- is kept deliberately, not deduplicated: two different true facts
("the panel stopped waiting" vs. "the wrapper finished, and how")
together reveal a slow-not-dead wrapper a single line couldn't
distinguish, linked by a shared `token` in both detail strings.

One review-caught bug fixed before it ever shipped: the launch-failure
site's own guard (`root.cli !== ""`) did not also check `action !== ""`,
unlike the recovery-timer site, which already had that guard structurally
via an early return. Without the fix, a launch failure with an already-
cleared `externalAction` would have logged a line with a blank action
field -- reopening the exact shape of bug already fixed once elsewhere
(round omabackup-23). `errBuffer` (an unbounded `StdioCollector`) is now
truncated to 2000 chars with a marker and stripped of embedded NULs
before becoming an argv element, and the exit code is preserved in the
detail even when stderr is also present (the original draft's
`errBuffer || ("exit " + code)` shape silently dropped the code whenever
stderr was non-empty).

Two new headless QuickShell probes (`test/qml/panel-logs-recovery-timeout.qml`,
`test/qml/panel-logs-launch-failure.qml`), following this suite's own
"hand-maintained mirror" convention -- driving the real handler logic
against a stub `omabackup` CLI that records its own invocation argv to a
file (`Util.execArgv`/`execDetached` gives no completion signal to wait
on, so the probes poll for the file instead of asserting immediately).
Both fail-before/pass-after verified directly: the launch-failure probe's
second scenario (empty `externalAction`) was run against a scratch copy
with the `action !== ""` guard removed and correctly caught the
regression (a second log line with a blank action field appeared) before
being counted as a real regression test. One structural substring check
added alongside them for the one fact a behavioral probe cannot easily
prove without shelling out to `ps` mid-run: that `timeout` really is the
literal prefix `Util.execArgv` is given at both sites, not just present
somewhere in the file.

Full suite: **1254 passed, 0 failed**.

### Round omabackup-30 review of the implementation: a real race and a real architectural bug, both closed

`herdr-review` dispatched on the implementation above. `omabackup-rev`
found two P2s and a P3; `omabackup-rev-2` found one P2 -- the same
underlying fact `omabackup-rev` also flagged from a different angle
(CONFIRMADO), plus independently verified everything else in the diff was
correct.

- **P2 (`omabackup-rev`) -- `externalProc.onExited` re-read mutable root
  state instead of its own launch's captured identity.** The handler read
  `root.externalAction`/`root.externalToken` at CALLBACK time, not the
  values that were actually active when THIS launch started. A late,
  stale exit from session A arriving after root's own state had moved on
  to session B would stop B's recovery, clear B's busy/token, overwrite
  B's `lastError`, and log a failure under B's token that actually
  belonged to A. `canOpenExternalTui`'s own `!busy` gate makes this
  unreachable by any caller in the codebase today, but the fix -- capture
  `launchAction`/`launchToken` on `externalProc` itself when the launch is
  armed, and refuse to act at all in `onExited` unless they still match
  the currently active session -- removes the dependency on that gate
  holding forever, rather than trusting it implicitly. Verified with a
  genuine, deterministic race in the new test probe: session A's
  `externalProc` launched with a real 0.4s delay before its own non-zero
  exit, root's session identity switched to session B 100ms in (while A
  is still running), and the probe confirms A's late exit changes nothing
  about B's state and logs nothing under A's stale identity.
- **P3 (`omabackup-rev`) -- the `timeout` bound did not actually bound
  what it was supposed to.** `Util.execArgv`'s own implementation is
  `Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "bash"].concat(argv))`
  -- passing `timeout` as part of that `argv` (the first draft's own
  shape) puts it INSIDE the login shell, so `timeout`'s own clock starts
  only after `bash -lc` has already finished sourcing the user's profile.
  A hung profile was therefore never bounded at all, despite the
  comment's own claim that it was. Fixed with a small shared
  `logEventDetached(argv)` helper that calls `Quickshell.execDetached`
  directly, with `timeout` as the true outermost element wrapping the
  whole login-shell invocation -- still injection-safe (every value stays
  a literal argv element through `"$@"`, the `bash -lc` string itself
  unchanged and constant).
- **P2 (both reviewers independently, converging on the same fact) -- a
  permanent comment asserted a correlation mechanism that did not exist.**
  The comment justifying the decision not to deduplicate the panel's two
  log lines per session claimed the wrapper's own `_on_exit` log-event
  calls already carried the session token -- they did not.
  `bin/omabackup-tui:190,192` fixed to include `(token $token)` in both
  calls, closing the gap the comment had assumed was already closed.
- **P2 (`omabackup-rev`) -- the two new QML probes did not actually
  exercise the properties they claimed to.** The original probes'
  launch-failure scenario used short ASCII stderr and only tested the
  empty-action case, never actually exercising truncation, NUL-stripping,
  or the (then-nonexistent) stale-identity guard. Rewritten into five
  sequenced scenarios: normal failure, the real stale-substitution race
  above, empty-action, NUL-stripping in isolation (a short
  `"BEFORE\0MORE"` blob -- proving the two halves survive JOINED, which a
  Qt/QProcess-level truncation-at-NUL upstream of this code could not
  produce), and truncation in isolation (2500 pure-ASCII characters, no
  NUL at all -- proving the >2000-char cut on its own, not conflated with
  NUL-handling in the same oversized blob the way the first draft's single
  combined scenario had been, which could not actually distinguish the two
  properties from each other). A new bash-level regression
  (`test/panel.test.sh`) captures `bin/omabackup-tui`'s own real invocation
  argv and confirms the token fix above. Structural substring checks
  (`test/panel.test.sh`) extended to anchor on `logEventDetached` itself
  and the launch-identity guard's own field names, not just the `timeout`
  prefix as before -- per `omabackup-rev-2`'s own suggestion, turning "a
  mirror that can silently drift" into "a mirror that breaks the suite
  when it drifts."
- **P3 (`omabackup-rev`) -- both probes leaked a `/tmp` directory per run,
  outside `test/run.sh`'s own `TMPDIR` scoping.** Fixed with
  `Quickshell.env("TMPDIR")` (the same access pattern this shell's own
  `shell.qml`/`Color.qml` already use for `HOME`), falling back to `/tmp`
  only if unset.

One self-inflicted bug found and fixed before it ever reached review: an
intended `\x00` escape sequence in one of the two probe files was
transcribed as an actual, literal NUL byte during authoring -- caught by
directly inspecting the file's raw bytes (`python3 -c "...count(b'\x00')..."`)
after `grep`/the Edit tool's own string-matching started failing
inexplicably against text that LOOKED identical when read back. Fixed by
rewriting the byte in place with Python, not by retyping the surrounding
QML by hand a second time.

Full suite after this round's fixes: **1257 passed, 0 failed**.

### Round omabackup-31: a follow-up review of round-30's own fixes, and it earned its keep

`herdr-review` dispatched narrowly on round-30's own fix set (the four
items above). `omabackup-rev` found one real P2 and two P3s;
`omabackup-rev-2` independently verified the four fixes were each correct
on their own merits (including measuring the `timeout` fix's real effect
with a fabricated slow login profile: without it, `rc=0` after the full
3s a hung profile took; with it, `rc=124` at the configured 1s bound) and
found two P3s of its own, one of which converges with `omabackup-rev`'s
own P3 on the exact same underlying gap.

- **P2 (`omabackup-rev`) -- the two new QML probes' assertions about
  sanitization, truncation, and guard-ordering only proved their own
  private mirror copies of the logic were correct, never that the REAL
  `Panel.qml` matched.** Reproduced directly: removing the NUL-strip or
  the 2000-char truncation from `Panel.qml`, or moving the stale-callback
  guard to run AFTER the state mutations it exists to prevent, would leave
  every existing check green. This is the same "hand-maintained mirror,
  not import" tradeoff this whole test suite already accepts elsewhere
  (documented in `killGroup`'s own comment) -- not something to solve with
  a full module-extraction refactor in this round, but the SPECIFIC gap
  (nothing anchored these exact expressions, or their order, against the
  real source) is closeable cheaply. Three new structural substring checks
  added in `test/panel.test.sh`, anchored directly on `Panel.qml`'s own
  text: the NUL-strip and 2000-char truncation literals, and an
  ORDER-sensitive pattern (`*guardText*'root.externalAction = ""'*`,
  bash's `*A*B*` glob requiring A before B) proving the guard's own text
  appears before the first state mutation it's supposed to gate.
- **P3 (both reviewers, converging on the same gap from different
  angles) -- the timeout structural check itself would have passed a
  reordered, still-broken version of the fix.** Two independent `&&`-ed
  substring clauses impose no order between them --
  `omabackup-rev-2` constructed the exact regression
  (`["bash", "-lc", 'exec "$@"', "bash", "timeout", ...]` -- `timeout`
  moved back inside the login shell, just written by hand instead of
  through `Util.execArgv`) and confirmed the OLD two-clause check passed
  it. Fixed with a single ordered pattern instead of two independent
  ones, the same `*A*B*` technique as the guard-ordering fix above --
  named by `omabackup-rev-2` as the same family of defect this project
  already took seriously in rounds 15 and 18 (an assertion that stops
  discriminating in silence).
- **P3 (`omabackup-rev`) -- the token-correlation regression only covered
  the wrapper's normal-exit path, never its signal path.**
  `bin/omabackup-tui`'s `_on_exit` has two nearly-identical `log-event`
  calls (`"exit=$rc"` and `"signal=$TUI_SIGNAL"`); the earlier fix's own
  test only drove the first. A same-shaped bug in the second could have
  hidden indefinitely. The existing HUP-signal fixture (already present
  for an unrelated regression) now also records its own `log-event` argv
  and asserts the token there too.
- **P3 (`omabackup-rev-2`) -- phase 3's "nothing was logged" assertion in
  the launch-failure probe used a fixed ~800ms window, not a real
  completion signal, and could pass for the wrong reason (the write just
  hadn't landed yet) rather than because it was genuinely suppressed --
  precisely the same login-shell-profile latency the round's own `timeout`
  fix exists to bound, not eliminate.** Fixed using the standard technique
  for proving a negative in an async system: after the suppressed
  attempt's own process has actually exited (`!externalProc.running`, a
  real signal, not a guess), dispatch a second, KNOWN-VALID sentinel
  `log-event` call and wait for IT to land with the same retry loop
  phase 1 already uses; only the content BEFORE the sentinel in the
  record file is what the suppressed attempt could possibly have
  contributed. The same "wait for the real signal, not a guessed window"
  fix was applied to phase 2's own completion check for the same reason
  (`omabackup-rev`'s related point that a fixed tick count there could
  also check before the exit was actually delivered), and phase 2's own
  artificial delay was widened (0.4s -> 0.8s) for a wider safety margin
  against a starved event loop -- `omabackup-rev-2`'s own assessment that
  a flake there fails in the safe direction (a spurious red, not a false
  green) made this a lower-priority hardening, not a required fix, but
  cheap enough to do anyway.

Full suite after this round's fixes: **1259 passed, 0 failed**.

### Round omabackup-32: the second correction-round's own verification, and where this stopped

`herdr-review` dispatched on round-31's own fixes -- the second and, per
this project's own "max 2 correction rounds" discipline, LAST
self-directed correction-verification round before any remaining finding
goes to the user instead of being fixed unilaterally. This round produced
a genuine, and instructive, split: `omabackup-rev` reported two more P2s
and three P3s; `omabackup-rev-2` explicitly **APPROVE**d, stating plainly
that no unresolved P1 or P2 remained, and characterized the overlapping
concern as low-priority residue for "a future round, or never."

Three of `omabackup-rev`'s findings were precise, cheap, and clearly
worth fixing regardless of the disagreement -- applied immediately, not
treated as requiring a fresh round:

- The `launchAction`/`launchToken` guard-ordering anchor only ordered
  `launchAction`'s own comparison against the mutation, leaving
  `launchToken`'s comparison free to move after `root.externalAction = ""`
  without breaking the check -- a real, narrower regression shape than
  "the whole guard moved" (which `omabackup-rev-2`'s own testing HAD
  caught). Fixed by anchoring both comparisons as one unit, ending at the
  guard's own `) return`.
- The truncation anchor only required `errText.length > 2000` to appear,
  not the assignment `errText = errText.slice(0, 2000)` -- a no-op body
  would have still passed. Fixed by anchoring the full `if (...) errText =
  ...` line as one literal.
- The `timeout`-wrapping anchor's ordered `*A*B*` pattern still accepted
  `Util.execArgv(["timeout", ...])` -- "timeout text before bash -lc text"
  is also true for that construction, which puts `Util`'s own internal
  login shell back outside `timeout`'s reach (the exact round-30 defect,
  surviving through the ordered check that was supposed to close it).
  Fixed by anchoring the literal call shape
  `Quickshell.execDetached(["timeout"` instead.

All three fixes verified fail-before/pass-after against the exact
regressions described, applied to a scratch copy of `Panel.qml` (not the
real file) via Python string replacement, confirming each check now
rejects what it previously accepted.

Two comment corrections from `omabackup-rev-2`, also applied: a stale
"0.4s" reference in `panel-logs-launch-failure.qml` left over from
widening phase 2's delay to 0.8s; and, more substantively, the
phase-3 sentinel's own comment was rewritten after `omabackup-rev-2`
pointed out it attributed the proof of absence to the wrong clause --
`beforeSentinel` is a readability aid, not what actually closes the case;
`lines.length === 11` is, since it catches a leak wherever in the file it
lands, not only before the sentinel. `omabackup-rev-2` flagged the
mis-attribution as more urgent than the underlying gap itself, since a
future reader could "simplify" the check down to just the misleadingly
central-looking `beforeSentinel` clause and silently remove the part that
actually works.

**What was NOT fixed, and why this is where self-directed correction
stops:** `omabackup-rev`'s remaining findings -- that the phase-3 sentinel
does not FORMALLY fence the suppressed attempt's own write (both are
independent `execDetached` chains with no ordering guarantee, so a
sufficiently delayed leak could in principle land after the sentinel and
still pass), and that phases 2/4/5 still read their target state after a
real-but-not-fully-synchronized signal rather than a true blocking
handshake -- are real, and `omabackup-rev-2` independently confirmed the
same underlying facts. The two reviewers diverge only on severity:
`omabackup-rev` weighs the sentinel gap as P2 and recommends a
synchronous in-memory dispatch log or an explicit join before proving
absence; `omabackup-rev-2`, having derived that the check's REAL
soundness rests on `lines.length` catching a leak anywhere in the file
(not on the sentinel ordering the way its comment used to imply), assesses
the residual window as narrow enough (it requires a reintroduced bug's own
leaked write to lose a race against another near-identical, independently
dispatched write) to defer indefinitely without blocking. This is a
genuine severity disagreement over the same underlying facts, arriving
exactly at the point this project's own review discipline says to stop
iterating and hand the state to the user rather than picking a side
unilaterally.

Full suite after this round's fixes: **1259 passed, 0 failed**. Both
`herdr-review` rounds' full test-suite runs (`omabackup-rev-2`,
independently) matched.

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
- **Panel.qml process/output hardening, live verification still needed**:
  this session confirmed the mechanism against real, headless QuickShell
  (`qs -p`, no display) and against the real installed 0.3.1-1 library
  source directly, but the actual panel, live, on a real bar, triggering a
  real timeout or a real oversized output, has not been exercised -- both
  reviewers were explicit that the QML wiring itself (property binding
  order, the dynamically created killer Process's lifecycle, `busy`'s
  visible state during a TERM→KILL sequence) is not verifiable by reading
  code alone.

# OmaBackup — design proposal

A document under review. Continues from [CONTEXT.md](CONTEXT.md), which
describes the 3 → 4.0 "Quattro" upgrade incident and Omarchy's plugin
architecture. Here the open questions from that document's §5 become concrete
decisions, so they can be attacked.

Written 2026-08-24.

---

## 0. Central thesis

**August's failure was not backup corruption. It was coverage.**

The versioned `hyprland.conf` was intact, valid and complete. It simply stopped
being the file Hyprland reads. A backup that verified *integrity* (hash, syntax,
a successful restore) would have passed with top marks and still saved nothing.

So the question OmaBackup has to answer is not "is the backup intact?" but:

> **Does the backup contain the files this system, right now, actually reads?**

That is verifiable by interrogating the live machine, in seconds, with no VM at
all. A VM answers a different question (more expensive and less frequent):
"restored from scratch, does this come up?". Both are needed; only the first has
to run all the time.

---

## 1. Architecture: the plugin is UI, the heavy lifting is a CLI

```
┌─ omabackup (bash CLI, ~/.local/bin) ─────────────────────┐
│  collect · classify · scan-secrets · verify · pack       │
│  push (git | rclone | dir | removable) · restore         │
│  every subcommand accepts --json                         │
└──────────────────────────▲───────────────────────────────┘
                           │ Quickshell.Io.Process (JSON on stdout)
┌──────────────────────────┴───────────────────────────────┐
│  brenoperucchi.omabackup (QML plugin)                    │
│    service    → timer, version watcher, triggers         │
│    bar-widget → icon + state badge                       │
│    panel      → groups, destinations, schedule, diff     │
└──────────────────────────────────────────────────────────┘
```

Why the split:

1. **The plugin runs inside the process that hosts the entire desktop.** A QML
   error takes down the bar, the dock and the menu — it already happened on this
   machine. Backup is exactly the feature that must not be the cause of that.
2. **Restoring has to work when there is no shell.** A new machine, a recovery
   tty, ssh. A plugin cannot reach that scenario; a CLI can.
3. **A CLI is testable.** `omabackup verify --json` runs in CI, in cron, in a
   container. QML does not.

The plugin never writes a file or runs `git` directly. If the CLI is not
installed, the widget shows "not configured" and breaks nothing.

---

## 2. Groups — "what is being saved"

A declarative manifest versioned in the repo (`omabackup.groups.json`). Each
group is a unit the user toggles and the panel reports on.

| id | label | paths | strategy | critical |
|----|-------|-------|----------|:---:|
| `compositor` | Hyprland | `~/.config/hypr/**` | copy | ● |
| `shell` | Omarchy shell | `~/.config/omarchy/{shell.json,themes}` | copy | ● |
| `state` | Omarchy state | `~/.local/state/omarchy/{current,toggles,migrations}` | copy | ● |
| `plugins` | Shell plugins | `~/.config/omarchy/plugins/**` | triple (§2.1) | ● |
| `terminal` | Terminal | alacritty, ghostty, kitty, foot, tmux, starship | copy | |
| `editor` | Editors | nvim, opencode | copy | |
| `shellrc` | User shell | `.bashrc`, `.bash_profile`, `.inputrc`, `.XCompose` | copy | ● |
| `desktop` | Desktop | `.local/share/applications`, `mimeapps.list`, `user-dirs.dirs` | copy | |
| `scripts` | Personal scripts | `~/bin`, `~/.local/bin`, `~/scripts` | tracked only | |
| `packages` | Packages | pacman/AUR/explicit lists | generated | ● |
| `systemd` | Services | units + enabled lists | generated | |
| `secrets` | Secrets | explicit allow-list, age-encrypted | allow-list | |

Each row in the panel shows: **file count · size · last change · state**
(up to date / changed / **not covered**).

The "not covered" state is the innovation: it comes from the coverage checker
(§5.1), not from comparing against the last commit.

### 2.1 The triple strategy for plugins

Inherited from `sync.sh`, it is the detail that cost the most to discover:

| case | detection | what goes into the backup |
|------|-----------|---------------------------|
| clean git | has `.git/`, `status --porcelain` empty | just the URL |
| dirty git | has `.git/`, dirty status | URL + `git diff` as a patch |
| local | no `.git/` | the whole directory |

Without this: either the local customization is lost (`rosakodu.dock` carries a
`slotSize: 42 → 56` of ours), or the repo grows by ~7 MB of third-party code.

---

## 3. Destinations

Several at once, each with its own policy. **Git is the source of truth for
content; the others receive a bundle derived from it** — so there are never
three divergent formats to reconcile later.

| destination | mechanism | retention | note |
|-------------|-----------|-----------|------|
| `github` | `git commit` + `push` | git history | default; diff and blame for free |
| `gdrive` | `rclone copy` to a remote | last N | the `GoogleDrive:` remote is **already configured** on this machine |
| `dir` | `cp` to a path (NAS, disk) | last N | |
| `removable` | same as `dir`, triggered by a mount | last N | matched by UUID; "waiting for the drive" badge |

The bundle is `omabackup-<host>-<YYYYMMDD-HHMMSS>.tar.zst`, containing a
`git bundle` of the repo (full history, clonable) plus the worktree in the clear
(readable without git) plus a `manifest.json` with versions, groups and the
verification result.

Each destination records: enabled, last success, last error, backoff.

One destination failing does **not** invalidate the others — the panel reports
per destination.

---

## 4. Schedule

Intervals offered: **5 min · 30 min · 1 h · 6 h · 1 day · manual**.

A design point: **the timer fires a _check_, not a backup.** No diff, nothing
happens — no empty commits, no traffic. That is what makes "5 min" a sane option
instead of a factory for junk history.

Triggers beyond the timer, in order of value:

1. **Before an Omarchy upgrade** — the highest-value item in the whole product.
   Watch `~/.local/share/omarchy/version` and/or hook into `omarchy-update`;
   force a backup **before** the upgrade runs. Attacks lesson #2 (the moment of
   highest risk is the moment of lowest attention).
2. **After a plugin mutation** — following `omarchy plugin add/update/remove`.
3. **On suspend/shutdown** — optional.
4. **When the configured removable drive is mounted.**

Exponential backoff per destination on failure. The badge does not clear itself:
a stale backup stays visible until it is dealt with.

---

## 5. Verification — "confirming the dotfiles work"

Three layers, increasing in cost, each catching a distinct class of failure.

### 5.1 T1 — Coverage (seconds, every run)

Interrogates the **live system** and asks whether the backup keeps up with it:

- Hyprland: which config did it actually load? The log says
  `[cfg] Using lua config found at <path>`. Is that path in the backup?
- Is every `.lua` under `~/.config/hypr/` covered? Is there a covered `.conf`
  that is **no longer** read? (warns: dead weight)
- Is `shell.json` present, valid JSON, `version: 1`?
- Does every plugin returned by `omarchy-shell shell listPlugins` have coverage —
  URL, patch or copy?
- Does every package from `pacman -Qqe` appear in a list?
- Does every enabled unit appear in the lists?

**This is the layer that would have caught the August incident**, on the day of
the upgrade, with no VM, no restore, in under a second.

### 5.2 T2 — Syntax (seconds, every run)

Against the bundle, not the machine: `luac -p` on `.lua`, `jq` on `.json`,
`bash -n` on scripts, `omarchy plugin validate` on each local plugin.

Catches a backup captured mid-write, or a broken config being propagated as
though it were fine.

### 5.3 T3 — Restore in a VM (minutes, on demand / weekly)

Answers "does this come up from scratch?". A separate artifact
(`tools/omabackup-verify-vm/`), not part of the plugin — the plugin only shows
"last VM check: ok, 3 days ago".

**A golden image, built once.** Three possible paths, from most faithful to
cheapest:

- (a) The official Omarchy ISO driven by `expect` over the configurator — most
  faithful, most fragile.
- (b) **Deferred provisioning** — Omarchy already supports it: an install can
  leave `/var/lib/omarchy/provisioning/pending` and
  `omarchy-provision-owner.service` finishes setup on first boot, on tty1. It is
  the hook designed for OEM use, and it serves here.
- (c) `pacstrap` straight into a qcow2 using
  `install/omarchy-base.packages` plus Omarchy's own `install/` — cheapest, skips
  the installer (and therefore does not test the installer; acceptable, that is
  not what we want to test).

**Each run** is cheap because nothing is reinstalled:

```
qemu-img create -f qcow2 -b golden.qcow2 -F qcow2 run.qcow2
qemu-system-x86_64 -snapshot ... -virtfs <bundle> ...   # headless
  → oneshot unit: restore the bundle, run install.sh
  → assert.sh: is quickshell alive? did hyprland start? did shell.json load?
               the expected number of keybindings? monitors applied?
  → grim/screenshot copied back
discard run.qcow2
```

The golden stays intact; the overlay is disposable. No `libvirt` — just
`qemu-system-x86_64`, already installed on this machine.

---

## 6. Secrets

**An explicit allow-list**, not a deny-list. Nothing enters `secrets/` without
being named in the manifest; today that is two files (`rclone.conf.age`,
`khronos.master.key.age`), encrypted with `age`.

On top of that, a deny-list scanner runs over the bundle and **blocks the push**
on a hit — it does not merely warn. Known harmless false positives
(`--password-store=gnome-libsecret`, `hide_token_restore`, conditional `source`
in `.bashrc`) go into a versioned exception allow-list, with justifications.

Why blocking: a leak is irreversible, and "just warns" is precisely the failure
mode of lesson #1 (a warning nobody reads).

---

## 7. Plugin robustness

Requirements derived from the observed crash (a QML error in *another* plugin
took down the entire `quickshell` process and nothing relaunched it):

- try/catch at every boundary; nothing heavy in `Component.onCompleted`
- zero synchronous I/O in QML — only `Quickshell.Io.Process`
- degradation: CLI absent → widget shows "not configured", no exception
- `shell.json` changes underneath the backup (plugins write to it on their own):
  the CLI compares hashes before and after and re-reads if they diverge
- inconsistent settings conventions between plugins (`rosakodu.dock` uses a
  nested `settings:{}`, `argus` uses loose keys) → capture the whole file, never
  rebuild it field by field

---

## 8. Decisions this document closes (and the review should attack)

| # | question from CONTEXT §5 | decision |
|---|--------------------------|----------|
| 1 | git or tarball? | **git as the source of truth + a derived bundle** for the other destinations |
| 2 | Omarchy only or dotfiles in general? | **dotfiles in general**, organized into toggleable groups; the narrow scope does not solve the real pain |
| 3 | deny-list or allow-list for secrets? | **allow-list**, plus a **blocking** deny-list scanner |
| 4 | `/etc` too? | **no** — the plugin never asks for sudo; `/etc/sudoers.d` remains a warning only |
| 5 | where does the work run? | **an external CLI**; the plugin is UI and scheduler |
| 6 | how to confirm it works? | **three layers**: coverage (always) · syntax (always) · VM (weekly/on demand) |
| 7 | symlink (stow) or copy? | **hybrid** — link for what only the user edits, copy for what Omarchy rewrites (§10) |

---

## 9. Known risks, unresolved

- **The golden image ages.** A VM built in August tests restores against an
  August Omarchy. It needs a rebuild policy.
- **None of this helps if the user disables the plugin.** The CLI plus a systemd
  timer survives; the plugin does not. Maybe the systemd timer should be the
  primary mechanism and the plugin merely its face.
- **A 5-minute interval with git** still produces many commits on a day of heavy
  dotfile work, even with the diff check. Automatic squash? A separate branch?
- **Selective restore** (the most requested item from CONTEXT §5) is sketched as
  groups, but restoring *one group* onto a live system can leave it in a mixed,
  inconsistent state.

---

## 10. Prior art: `omadot`, and the symlink vs. copy question

[`tomhayes/omadot`](https://github.com/tomhayes/omadot) — a thin GNU Stow
wrapper for Omarchy (56 stars, last pushed 2026-04-27, no license). Two verbs:
`get <pkg>` moves `~/.config/<pkg>` to `~/.dotfiles/<pkg>/.config/<pkg>` and
symlinks it back; `put <pkg>` re-stows it on a new machine.

What it does **not** do and OmaBackup must: scheduling, reminders, destinations
(git is manual; no Drive, drive or directory), verification of any kind, and any
awareness of Omarchy 4 (`shell.json`, the triple plugin strategy, `.lua` vs
inert `.conf`).

What it gets right, and is worth stealing: **it removes the sync step.** If
`~/.config/nvim` *is* the repo, there is no `sync.sh` for anyone to forget to
run. That attacks lesson #1 at the root, structurally, instead of with a
reminder.

### The experiment that settles it

The stow model only holds if the system's writers respect the link. Measured on
this machine, in an isolated environment:

| writer | mechanism | link survives |
|--------|-----------|:---:|
| Quickshell `FileView { atomicWrites: true }` (`shell.qml:130`) | writes through the link | **yes** |
| `omarchy-shell-config` → `commit()` (`mktemp` + `mv`) | replaces the inode | **no** |

The second one backs `omarchy bar move`, `omarchy bar set` and
`omarchy plugin enable/disable`. A stow-managed `shell.json` is silently
disconnected from the repo **the first time you move a widget in the bar** — and
the symptom is exactly August's: backup green, content stale.

### Decision: hybrid, with the failure mode made visible

- **Symlink (stow)** for what only the user edits: `nvim`, `bashrc`,
  `alacritty`, `ghostty`, `tmux`, `starship`, `.XCompose`. No sync step.
- **Copy** for what Omarchy itself rewrites: `shell.json`, `hypr/*.lua`,
  `~/.local/state/omarchy/`, and everything generated (package lists, systemd
  units). `plugins/` is **not** a plain rsync copy — it keeps the triple
  strategy from §2.1; that is how the first version of `sync.sh` tripped over
  itself.
- The group manifest (§2) gains a `mode: link | copy` column.
- **T1 verification (§5.1) now checks link integrity**: is every path declared
  `mode: link` still a symlink pointing into the repo? If it stopped being one →
  a red alert in the panel, with the repair command.

That converts stow's characteristic silent failure into a visible one, which is
the point of the whole product.

Note: `stow` is **not installed** on this machine. If link mode is adopted,
either it becomes a dependency, or the CLI does its own `ln -s` — stow's
directory layout is simple enough not to justify the dependency.

---

## 11. Review results (dual-r, 2026-08-24)

Two independent lenses, blind to each other — `gpt-5.6-sol`/xhigh via
AgentRelay (model proven by `codex-argv:-m`) and a native `dual-opus-reasoner`
(`model: opus`, `effort: max`; the numbered version was not proven by the
harness). Every solo P0/P1 was verified against the code before landing here.

### 11.1 The circular loop (P0)

§4 said: *the timer fires a check, not a backup; no diff, nothing happens.* That
works for `mode: link` groups, where the live file **is** the repo. For
**`mode: copy`** groups — `shell.json`, `hypr/*.lua`, plugins, the critical ones
— there is no diff at all until something has been copied. The loop closes on
itself: no collect → no diff → no backup → no collect.

**Fix — the cycle has four beats:**

```
collect  → staging in ~/.local/state/omabackup/staging (rsync, repo untouched)
diff     → staging vs. the repo worktree, normalized (jq -S on .json)
verify   → T1 coverage + T2 syntax over the staging area
commit   → only if the diff is non-empty AND verification passes
```

Normalized because `shell.json`'s two writers serialize differently —
`omarchy-shell-config` uses `jq -S` (sorted keys), Quickshell uses
`JSON.stringify(payload, null, 2)` (insertion order). Without normalizing,
moving one widget rewrites the whole file in the diff.

### 11.2 What changes

| § | v0 decision | v1 decision | why |
|---|-------------|-------------|-----|
| 1 | the plugin schedules, the CLI executes | **the systemd timer is primary**; the plugin is just the face and a button | `omarchy-update-restart:51` runs `omarchy-restart-shell` at the end of every update: the scheduler dies during the event it exists to watch |
| 1 | state in the shell | state in `~/.local/state/omabackup/` | restoring yesterday's `shell.json` **disables OmaBackup itself** — a third-party plugin is enabled iff its id appears in `shell.json`, and there is no deep merge |
| 4 | watcher on `~/.local/share/omarchy/version` | **dropped** | it is a symlink to `/usr/share/omarchy`; it only changes after pacman has already swapped the package, and it reads `4.0.0.alpha` while `omarchy-version` reads `4.0.0-1` |
| 4 | pre-upgrade trigger via a hook | **there is no pre-update hook** | `omarchy-update:47-49` is packages → migrations → `omarchy-hook post-update`. The available hooks are battery-low, font-set, post-boot, post-update, pre-refresh-pacman, theme-set |
| 5.1 | probes over known directories | **transitive resolution** | `~/.local/state/omarchy/toggles/hypr/flags.lua` and `current/theme/hyprland.lua` are live Lua outside the declared scope, loaded via `package.path` |
| 5.1 | plugin coverage via `listPlugins` | driven by the **directory**, with `listPlugins` only enriching | `listPlugins` includes first-party plugins (permanent noise) and omits any plugin with an invalid manifest — precisely the one that most needs backing up |
| 5.3 | golden via deferred provisioning | **pacstrap** is the only non-interactive path | `omarchy-provision-owner:551` blocks on `read -r -t 0.2 _ </dev/tty` inside a `while true`, then asks for username/password/hostname/timezone through `gum` |
| 6 | scanner over the bundle | scanner over **`git log -p --all`** as well | the bundle carries the full history; a secret committed and later removed travels in every backup without passing the scanner |
| 10 | `mode: link\|copy` per file | per file **plus a property test per release** | symlink survival is per-writer, not per-file: `omarchy-shell-config:59` uses `mv` (destroys), migration `1785189600.sh:53` uses `cat >` with the explicit comment *"so a tmux.conf symlinked out of a dotfiles repo keeps pointing where it pointed"* (preserves) |
| 10 | "red alert with the repair command" | **copy the live file into the repo, then relink** | the naive repair (`ln -sf`) erases the very edit that broke the link |

### 11.3 A bug in today's `sync.sh` (not just design)

`sync.sh:157` decides a plugin is dirty using `git status --porcelain`, but
`sync.sh:161` writes the patch with `git diff` — which includes **neither
staged nor untracked** changes. Proven by construction:

```
status --porcelain : M  Widget.qml ?? Helper.qml
git diff           : 0 lines   ← what goes into the patch
git diff HEAD      : 7 lines
```

The plugin is marked "git + local patch" with an empty patch. The fix is
`git diff HEAD` plus explicit capture of untracked files
(`git ls-files --others --exclude-standard`).

And the manifest stored only `id url`, no commit. If upstream moves, the restore
installs different code and the patch will not apply. It needs a SHA.

### 11.4 The chicken-and-egg problem in the destinations

`bootstrap.sh:19-26` decrypts `secrets/rclone.conf.age` **from inside the cloned
repo**. Which means Google Drive is only reachable once you already have the
repo from GitHub. If GitHub is what you lost, the credential for fetching the
Drive bundle is inside the Drive bundle.

Consequence for §3: each destination must be **restorable from its own
identifier alone**, and T3 must exercise a different destination each round
(even = local bundle, odd = clone from the remote), requiring all of them to
have passed within the last N days before the panel goes green. A path that is
not exercised does not work.

Related: the `secrets` group uses `age -p` (an interactive passphrase,
`secrets/README.md:13`). No timer can refresh it. Either it becomes
`age -R recipients.txt` — and then the private key needs a custody story this
document does not have — or it is explicitly manual, with an expiry date visible
in the panel.

### 11.5 The pre-upgrade trigger, now that we know the hook does not exist

Three options, none clean:

1. **A pacman `PreTransaction` hook on `Target=omarchy`** — the only point
   genuinely before the mutation. Requires root once, which collides with
   decision §8 #4 ("the plugin never asks for sudo"). The collision is between
   *installing* with sudo once and *running* with sudo always; only the second
   is what Omarchy's rule forbids.
2. **A wrapper or alias on `omarchy update`** — bypassable by any other route
   (`pacman -Syu` updates the `omarchy` package directly).
3. **`snapper -c home create`** — `omarchy-update:36` already runs
   `omarchy-snapshot create` **before** the packages; `/` and `/home` are btrfs
   and snapper is installed. Cheap, local, and no substitute for off-site.

And even a perfect trigger would not cover everything: migrations also run **at
login** and on retry (`omarchy-migrate:79`), decoupled from `omarchy update`. An
ordinary `pacman -Syu` updates the package; the migrations rewrite `input.lua`
and `bindings.lua` at the next login without any §4 trigger firing. The right
probe is `omarchy-migrate --pending` inside T1.

### 11.6 Selective restore: blocked until there is a graph

Three independent reasons, any one sufficient:

1. **Lua does not degrade, it aborts.** `hyprland.lua:14-26` has six top-level
   `require` calls, none guarded by `pcall`. Restoring only the `compositor`
   group with a `looknfeel.lua` referencing something the `state` group would
   have brought → an error in `require` → bindings, autostart and toggles never
   load. The old `.conf` tolerated failure line by line; Lua does not.
2. **Restoring `shell` disables OmaBackup** (§11.2).
3. **Migration markers.** There are 439 in
   `~/.local/state/omarchy/migrations`. Without them a restore runs every
   migration against the config you just restored. With them, legitimate
   migrations for the new version are skipped forever.

### 11.7 The missing half of the invariant

§0 defines coverage in one direction: *does the backup contain what the system
reads?* The symmetric half is missing: *does it contain **only** that?* The repo
is the proof — `configs/hypr.backup/`, `configs/waybar.backup/`,
`configs/walker.backup/`, the Quattro-era `.bak` files,
`.user.system-monitor.bak.20260820042654/`. A bootstrap from here today
resurrects all of it.

The August incident was **both halves at once**: `.conf` files present and dead
plus `.lua` files absent. The v0 design addressed only the second.

And a third, raised by the Sol lens and the most uncomfortable: **coverage is
not semantic equivalence.** After the upgrade the generated `hyprland.lua` files
were empty but valid. Copying them would leave T1 green with zero customization
preserved. T1 has to compare against the *last known-good state*, not merely
against the existence of a path.

---

## 12. v2 decisions — a declared restore range replaces racing the upgrade

Three decisions taken after the review. The second one reorganizes the product.

### 12.1 OmaBackup declares what it can restore; it does not chase the upgrade

**Decision:** keep the backup always current (the four-beat cycle from §11.1
provides that) and move the safety guarantee from the *moment of capture* to the
*moment of restore*. OmaBackup declares a set of target versions it knows how to
restore onto — today Omarchy 3.x and 4.x. On a machine outside that set, it
**does not try**.

What this solves, and it is a lot:

- §11.5 (the pre-upgrade trigger) stops being the highest-value item in the
  product and becomes a convenience. No `PreTransaction` hook, no sudo, no
  intercepting `omarchy-update`, and decision §8 #4 ("the plugin never asks for
  sudo") is no longer in conflict with anything.
- August's failure mode becomes impossible **by construction**: a backup in
  `.conf` format restored onto an Omarchy that reads `.lua` is refused with a
  reason, instead of applied and discovered broken hours later.
- The "an upgrade is coming" warning needs no hook: `omarchy-update-available`
  is already a poll. The widget now says *"an update is available and it takes
  you outside the range OmaBackup knows how to restore"* — informative, never
  blocking.

What it costs: the product can refuse to help on the hardest day (a new machine
running Omarchy 5.x, with a 4.x backup). §12.2 is how that is paid for.

### 12.2 A new axis: version coupling

More important than `link` vs `copy`. It determines what survives an unknown
version.

| group | coupled to Omarchy? | why |
|-------|:---:|-----|
| `compositor` | **yes** | the format changed from `.conf` to `.lua` in 3 → 4 |
| `shell` | **yes** | `version: 1` schema, widget ids, settings conventions |
| `plugins` | **yes** | the Quickshell and `PluginRegistry` API |
| `state` | **yes** | toggles, active theme, migration markers |
| `terminal` | no | alacritty, ghostty, tmux and starship do not know what Omarchy is |
| `editor` | no | same |
| `shellrc` | no | same |
| `desktop` | no | freedesktop, not Omarchy |
| `scripts` | no | your own scripts |
| `packages` | partial | package names change slowly; failure is visible and fixable |
| `systemd` | partial | same |

On a machine outside the range, a restore **applies the uncoupled groups and
quarantines the coupled ones**, with a report of what was left out and where it
is. You get back shell, editor, terminal, scripts and packages — most of the
day-to-day — and rebuild by hand only the desktop config, which is what changed
format.

This also provides the cut §11.6 was missing: there is a **principled** boundary
for partial restore (coupled vs. uncoupled) instead of an invented graph. Inside
the coupled block it stays all-or-nothing — a chain of `require` without `pcall`
admits no middle ground.

### 12.3 Compatibility identity: the migration marker, not the version string

The bundle records three things:

| field | source | example |
|-------|--------|---------|
| version | `omarchy-version` | `4.0.0-1` |
| channel | `omarchy-channel-current` | `stable` |
| **migration watermark** | the highest name in `~/.local/state/omarchy/migrations` | `1786643346` (2026-08-13) |

The watermark is the better identifier: they are unix timestamps, they order
unambiguously, and on this machine there are 439 of them spanning 2025-06-28 to
2026-08-13 (against only 78 migrations still shipped in the package — the
package prunes, the state accumulates).

It answers the question §11.6 left open:

| situation | what to do with the markers |
|-----------|-----------------------------|
| target == source | restore the markers: migration state is identical |
| target > source, inside the range | **do not** restore them: let `omarchy-migrate` run forward — that is exactly what it exists for |
| target outside the range | restore nothing from the coupled block |

### 12.4 What verification asserts — and what becomes a note

**Decision:** the assert checks that **the config file is present and intact**.
Hardware is not a test subject.

Monitors, rotation, EDID and modes become a **note** in the panel — "this
machine had 3 monitors, the ASUS with `transform 3`" — information for a human
to check after a restore, never an assert that fails.

---

## 13. Correcting §12.4 — the container does not replace the VM

§12.4 concluded that if the assert is "the file is present and parses", there
would be no reason to boot a system. **That is wrong**, and decision §12.1 (the
restore range) makes the error worse, not smaller.

Two distinct needs had been glued into one:

| | question | who answers | who reads |
|---|---|---|---|
| **T3** | did the files arrive and do they parse? | a container | the machine |
| **T4** | does this become a working desktop? | a **VM** | a **human** |

The container answers the first. It does not answer the second, and above all it
**does not let you look**. The August incident would pass T3 with top marks: the
generated `.lua` files were valid, they parsed, they were in place. What was
missing only showed on screen.

### 13.1 Why §12.1 increases the need for a VM

The range table (`supportedTargets = ["3.*", "4.*"]`) is an **assertion that has
to be earned**, not a constant. Two questions depend on it and neither has an
analytical answer:

1. **How do you add `5.x` to the list?** By booting an Omarchy 5.x, restoring
   the bundle and looking at the result. There is no other honest way.
2. **Is the quarantine cut (§12.2) right?** "These 7 groups are
   version-independent" is a hypothesis. If `ghostty` or some `.desktop` turns
   out to depend on something Omarchy 5 changed, the VM is what finds out.

So the VM stops being a weekly regression test and becomes **the mechanism by
which the restore range is extended**. It runs once per major Omarchy release,
with a human in the loop — low frequency, high value.

### 13.2 How the user sees it

QMP `screendump`, measured on this machine (QEMU 11.1.0):

```
{"execute":"screendump","arguments":{"filename":"/out/screen.ppm"}}
→ {"return": {}}
```

The decisive property: **the capture comes from the host side, with no
cooperation from the guest.** Verified by booting a VM with no disk — the guest
never came up and the capture succeeded anyway, showing the boot-failure screen.
If Hyprland does not start after a restore, you see *the error screen*, not an
empty file.

A `grim` inside the guest would not have that property: broken desktop, no
capture, no diagnosis — blind exactly when it matters.

The cycle:

```
qemu-img create -f qcow2 -b golden-<version>.qcow2 -F qcow2 run.qcow2
qemu-system-x86_64 -display none -qmp unix:/tmp/qmp.sock -vnc :1 \
  -virtfs local,path=<bundle>,mount_tag=oma,security_model=mapped-xattr ...
  → oneshot unit: restore the bundle, run install.sh, reach SDDM/Hyprland
  → QMP screendump → screen.png
  → T3 (the container) already ran; here the output is the IMAGE, not an exit code
```

The `-vnc :1` stays open: when a still frame is not enough, you go in and click.

### 13.3 What the VM delivers — and what still is not an assert

Consistent with decision §12.4 about hardware: **the capture is not an assert.**
There is no pixel comparison, no "failed because it changed". It is **evidence a
human looks at** — the same category as the note about monitors.

The panel gains, alongside the tiers:

- a thumbnail of the last capture
- the target version it was taken on
- the date
- and, when that target version is outside the current range, the button that
  promotes it into `supportedTargets` — so the decision is recorded together
  with the image that justified it

### 13.4 The cost, honestly

What comes back: one golden image per Omarchy version you want to support, and
the work of building it (`pacstrap`, §11.2 — deferred provisioning stays out, it
blocks on a `gum` form). What does **not** come back is the frequency: T3 in a
container runs every day, on its own; T4 in a VM runs when a new Omarchy ships
or when you feel uneasy. §12.4 was right to take the VM off the critical path —
wrong to take it out of the product.

---

## 14. A crash while testing the harness (2026-08-24)

While validating the Panel.qml against the failure path (§0's August scenario)
in the isolated harness described in §1, a run with `XDG_RUNTIME_DIR=/nonexistent`
segfaulted the harness's own `quickshell` process. Root cause, from the crash
report's backtrace: `QsPaths::linkRunDir()` in Quickshell itself, not this
plugin's QML — it fails to create the runtime directory and then dereferences
something built from it anyway. Upstream bug, unrelated to OmaBackup.

The live shell (the one hosting the real bar, dock and menu) was never touched:
it runs from `/usr/share/omarchy/shell` as its own process, and the harness runs
from an isolated `-p` path with `Ui`/`Commons` symlinked in, in its own process,
started separately. `pgrep -x quickshell` during the incident showed the live
process still running; only the harness instance died.

This is the isolation the harness exists to provide, working as intended: the
crash CONTEXT.md warns about ("a QML error in one plugin can take down the
whole quickshell, bar/dock/menu included") happened, and it happened to a
disposable test process instead of the desktop.

Practical fallout: do not set `XDG_RUNTIME_DIR` to a nonexistent path when
driving quickshell for testing, isolated harness or not.

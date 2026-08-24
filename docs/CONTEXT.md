# OmaBackup — the context that started it

A handoff document. It gathers the problem that motivated the idea, everything
we learned about the Omarchy 4.0 "Quattro" plugin architecture, and what already
exists in working form and serves as a prototype.

Written 2026-08-24, right after rebuilding by hand the config lost in the
upgrade to Quattro.

---

## 1. The problem (the real story behind the idea)

**2026-08-17** — upgrade from Omarchy 3 to 4.0 "Quattro". Hyprland switched to
**native Lua config**: `~/.config/hypr/hyprland.lua` now takes priority over
`hyprland.conf`, which becomes inert. The compositor log confirms the switch:

```
[cfg] Regular config at /home/brenoperucchi/.config/hypr/hyprland.lua
[cfg] Using lua config found at /home/brenoperucchi/.config/hypr/hyprland.lua
```

The installer generated `monitors.lua`, `input.lua`, `bindings.lua`,
`looknfeel.lua` and `autostart.lua` as **empty templates, everything commented
out**. None of the customization from the old `.conf` files was migrated. The
`.conf` files stayed on disk, intact and completely ignored.

The practical result, all at once:

- monitors at the wrong resolution, the ASUS lost its rotation (`transform 3`)
- keyboard without accents (`kb_variant = intl` gone)
- ~40 macOS-style keybindings lost
- gaps, borders, blur and animations back to defaults
- workspaces detached from their monitors

Every one of these had to be rebuilt by hand, translating `.conf` into the new
Lua API, testing one at a time.

**And the worst part:** the dotfiles repo (`omarchy-personal`) had been sitting
untouched since 2026-08-10. A `bootstrap.sh` from it would have restored only
the `.conf` files — which Hyprland 0.55+ no longer even reads. The backup
existed and would still have saved nothing.

### The three lessons that became product requirements

1. **A backup nobody runs is not a backup.** The `README` had documented
   `./sync.sh` as the update flow for months. The script **never existed** (it
   appears in no commit). Nobody noticed because nothing said anything.
2. **An upgrade is the moment of highest risk and lowest attention.** Precisely
   when the config format changes is when nobody thinks about backups.
3. **Not everything restores the same way.** Your own config, a third-party
   plugin, a *modified* third-party plugin and a homegrown plugin each need a
   different strategy (see §4).

---

## 2. Quattro's plugin architecture (what you need to know to build here)

Primary sources, worth reading before writing code:

- `/usr/share/omarchy/shell/README.md` — manifest, kinds, IPC, `shell.json`
- `/usr/share/omarchy/shell/plugins/README.md` — the first-party catalogue
- `/usr/share/omarchy/shell/services/PluginRegistry.qml` — the full schema

### How it works

`omarchy-shell` is **a single instance** of [Quickshell](https://quickshell.org/)
hosting the entire desktop. Bar, panels, menus, overlays — everything runs
**inside** it as a plugin. The actual process is called `quickshell`:

```bash
pgrep -af quickshell
# 353177 quickshell -n -p /usr/share/omarchy/shell
```

A plugin is a **git repo with a `manifest.json` at its root**, cloned into
`~/.config/omarchy/plugins/<id>/`.

### manifest.json

```json
{
  "schemaVersion": 1,
  "id": "brenoperucchi.omabackup",
  "name": "OmaBackup",
  "version": "0.1.0",
  "author": "brenoperucchi",
  "license": "MIT",
  "description": "...",
  "kinds": ["service", "bar-widget", "panel"],
  "keepLoaded": true,
  "entryPoints": {
    "service": "Service.qml",
    "barWidget": "BarWidget.qml",
    "panel": "Panel.qml"
  },
  "barWidget": {
    "displayName": "OmaBackup",
    "category": "System",
    "allowMultiple": false,
    "defaults": { "intervalHours": 24 },
    "schema": [
      { "key": "intervalHours", "type": "number", "label": "Backup interval" }
    ]
  }
}
```

Available `kinds`:

| Kind | What it is |
|------|------------|
| `bar-widget` | a component the bar drops into a section |
| `panel` | a persistent or summoned floating window |
| `overlay` | a fullscreen overlay |
| `menu` | a summoned menu surface |
| `service` | a headless singleton, no UI |
| `bar` | a full bar, replacing `omarchy.bar` |

`keepLoaded: true` keeps the plugin mounted between summons.

The `barWidget.schema` block is what gives you a **configuration UI for free** —
the user edits it through Omarchy itself instead of hand-editing JSON. Worth
using.

### IPC

The shell exposes the `shell` target, and each plugin may register its own:

| Method | Effect |
|--------|--------|
| `ping` | health check |
| `summon <id> <payloadJson>` | load + open a panel/overlay |
| `hide <id>` / `toggle <id> <payload>` | close / toggle |
| `call <id> <method> <arg>` | call a method on a loaded plugin |
| `rescanPlugins` | re-walk and hot-reload plugin code |
| `reloadConfig` | reload `shell.json` |
| `setPluginEnabled <id> <enabled>` | enable/disable (a string! only `"true"` enables) |
| `listPlugins` | JSON of every plugin |

```bash
omarchy-shell shell ping
omarchy-shell shell listPlugins
omarchy-shell shell toggle brenoperucchi.omabackup '{}'
```

Registering your own target in QML:

```qml
IpcHandler {
    target: "brenoperucchi.omabackup"
    function runNow() { root.runBackup(); return "ok" }
    function status() { return JSON.stringify(root.lastRun) }
}
```

### Development cycle

**Saving any file under `~/.config/omarchy/plugins/` hot-reloads the code
automatically.** Normally nothing needs restarting.

```bash
omarchy plugin validate <dir>            # validate the manifest against the schema
omarchy-shell shell rescanPlugins        # force a reload
omarchy plugin add <url> --enable --yes  # --yes is the path for scripts and agents
omarchy plugin clone omarchy.clock       # study a first-party plugin without editing it
omarchy-restart-shell                    # full restart (see the warning below)
```

⚠️ **The shell can crash silently during a hot-reload.** It happened during
this session: a QML error in *another* plugin took down the entire `quickshell`
process — bar, dock and menu vanished — and nothing relaunched it. The
diagnosis is an empty `pgrep -x quickshell`; the cure is
`omarchy-restart-shell`. **A backup plugin must be defensive enough never to be
the cause of that**: try/catch everywhere, no unhandled exception in
`Component.onCompleted`.

To debug:

```bash
journalctl --user --since "-2 minutes" | grep -iE "omarchy-shell|error|fatal"
```

---

## 3. Persisted state: `shell.json`

One file: `~/.config/omarchy/shell.json`. Bar layout, per-entry settings, and
which plugins are enabled.

```json
{
  "version": 1,
  "idle": { "screensaver": 150, "lock": 300 },
  "bar": {
    "position": "top",
    "transparent": true,
    "centerAnchor": "omarchy.clock",
    "layout": {
      "left":   [ { "id": "omarchy.menu" } ],
      "center": [ { "id": "rosakodu.dock", "settings": { "autohide": true } } ],
      "right":  [ { "id": "omarchy.tray" } ]
    }
  },
  "plugins": []
}
```

Three traps found in practice:

1. **No deep merge.** The moment the user customizes anything, `shell.json`
   becomes the source of truth and defaults are **not** merged back in. A backup
   has to capture the whole file.
2. **Plugins write to it on their own.** `argus` wrote `sensorThresholds` and
   `hiddenSensors` into its entry without being asked. A backup in progress has
   to tolerate the file changing underneath it.
3. **The settings convention is inconsistent between plugins.**
   `rosakodu.dock` reads from a nested `"settings": {...}`; `argus` reads loose
   keys at the root of its entry. You cannot assume one shape.

Removing a widget from `layout` already marks it `enabled: false` — no separate
disable step needed.

---

## 4. The existing prototype: `sync.sh`

It lives at the root of the dotfiles repo, working, at commit `cd715db`. It is
the **reverse of `install.sh`**: it pulls the machine's live state back into the
repo. This is where the plugin's logic should come from.

```bash
./sync.sh --dry-run     # show without touching anything
./sync.sh
git add -A && git commit -m "..." && git push
```

### Design decisions (each one cost some discovery)

**It only updates what the repo already tracks.** Scanning all of `~/.config`
would drag in cache, state, browser profiles and secrets. To start versioning
something new you create the path in the repo once; from then on the sync keeps
it current.

**No `--delete`.** Whatever disappeared from the machine stays in the repo until
an explicit `git rm`. Real case: `elephant`, `mako`, `walker`, `waybar` and
`swayosd` no longer exist live after Quattro, but nobody wants to lose them by
accident.

**It preserves symlinks** (`rsync -a`, never `cp -p` or a blanket `-L`). This
repo versions 3 symlinks; `configs/nvim/lua/plugins/theme.lua` points at the
current Omarchy theme. Overwriting it with the target's content breaks theme
switching. To audit:

```bash
git ls-files -s | grep ^120000
```

**Plugins in three strategies** — the most important part for OmaBackup:

| Case | How to detect | Strategy |
|------|---------------|----------|
| git, unmodified | has `.git/`, `git status --porcelain` empty | just the URL in `lists/omarchy-plugins.txt` |
| git, **with** local changes | has `.git/`, dirty status | URL **plus** a `git diff` saved to `patches/omarchy-plugins/<id>.patch` |
| local (homegrown) | no `.git/` | versioned in full — it exists on no remote |

Without this: either you lose the local modification (`rosakodu.dock` carries
our `slotSize: 42 → 56`), or the repo gains ~7 MB of third-party code that
already lives on GitHub.

### Two bugs worth remembering

**`((count++))` with `set -e` aborts the script.** The post-increment returns
the *old* value; on the first pass (0) the status becomes 1 and `set -e` kills
everything mid-run, **silently**. Use `count=$((count + 1))`.

**A generic loop overrides specific handling.** The first version copied all of
`~/.config/omarchy/`, `plugins/` included — defeating the entire manifest+patch
strategy described above. It needed an `--exclude 'plugins/'` on that particular
rsync. Moral: when a subpath has special handling, the generic loop has to know
about it explicitly.

### Secret hygiene

This repo's `.gitignore` already covers a fair amount (secrets, browsers,
`**/.env`, keys). The sync scans the result before committing. Common and
harmless false positives: `--password-store=gnome-libsecret`,
`hide_token_restore`, and `.bashrc` conditionally sourcing external files
without containing any values.

A backup plugin **needs** that scan built in and visible — it is the kind of
thing you only discover was missing after it has already leaked.

---

## 5. Scope ideas for OmaBackup

Not decided; raw material for a design session.

### What the plugin would solve that `sync.sh` does not

- **Remembering to run it.** A `service` with a timer; a badge on the
  `bar-widget` when the backup is stale. Attacks lesson #1.
- **Detecting an Omarchy upgrade.** Watch the version
  (`~/.local/share/omarchy/version`) and offer a backup **before** applying it.
  Attacks lesson #2 — the highest-value part of the whole plugin.
- **A visual diff before committing.** A panel showing what changed since the
  last backup, with the option to exclude paths.
- **Selective restore.** Today `install.sh` is all-or-nothing.
- **Onboarding.** Today it requires a git repo assembled by hand. The plugin
  could initialize one (local git, optional remote, destination on disk or
  rclone).

### Open design questions

1. **Backend:** git (history, diff, push) or tarball snapshots? Git is the
   current prototype but requires the user to have a repo. Maybe local git by
   default plus an optional remote.
2. **Scope:** only Omarchy config (`shell.json` + plugins) or dotfiles in
   general (what `sync.sh` does)? The first is easier to defend as a plugin; the
   second is what actually hurts.
3. **Secrets:** deny-list (like the `.gitignore` here) or an explicit
   allow-list? An allow-list is safer and less convenient.
4. **System vs. user:** only `~/.config` or `/etc` too? `sync.sh` only *warns*
   about `/etc/sudoers.d` because it needs root. A plugin should not ask for
   sudo — the Omarchy installer explicitly never runs it.
5. **Where it writes:** a plugin runs inside the shell, unsandboxed. Writing
   files and running git from QML needs care; maybe the plugin is only the UI
   and the heavy lifting sits in a script it invokes
   (`Quickshell.execDetached`).

### Name

`OmaBackup` matches the existing convention (`omacalc`, `omawrite`, `omacut`).
The id would be `brenoperucchi.omabackup` or
`io.github.brenoperucchi.omabackup`.

---

## 6. Quick path reference

| Path | What it is |
|------|------------|
| `~/.config/omarchy/shell.json` | bar layout + settings + enabled plugins |
| `~/.config/omarchy/plugins/<id>/` | third-party and homegrown plugins |
| `/usr/share/omarchy/shell/` | the Omarchy shell (first-party, reference) |
| `/usr/share/omarchy/shell/README.md` | the plugin contract — **read it** |
| `/usr/share/omarchy/bin/` | the CLI (`omarchy-shell`, `omarchy-restart-shell`) |
| `~/.local/share/omarchy/version` | installed version (`4.0.0.alpha`) |
| `~/.config/hypr/*.lua` | Hyprland config (Quattro) |
| `~/.config/hypr/*.conf` | the old config, **inert** since Quattro |
| `~/Devs/omarchy-personal/sync.sh` | the prototype |

Marketplace: <https://omarchyplugins.com> (a small catalogue — several plugin
links return "does not exist in the current catalog", so trust the git repo
directly).

Plugins installed here, useful as real-code reference:

```
b.everything                       github.com/brianblakely/omarchy-everything
im0001gt.hw-tooltip                github.com/IM0001GT/omarchy-hw-tooltip
io.github.diegopluna.argus         github.com/diegopluna/omarchy-argus
io.github.howdyitskyle.weathering  github.com/howdyitskyle/weathering-omarchy-plugin
rosakodu.dock                      github.com/rosakodu/omarchy-dock
user.workspaces-per-monitor        (local, in the dotfiles repo — a minimal example, 2 files)
```

`user.workspaces-per-monitor` in `configs/omarchy/plugins/` is the smallest
complete example of a homegrown plugin: `manifest.json` plus one QML file, a
fork of a first-party widget. A good starting point for structure.

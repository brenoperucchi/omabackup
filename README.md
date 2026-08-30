# OmaBackup

Dotfile backup for Omarchy 4 that answers a different question than usual.
Not *"is the backup intact?"* — the `hyprland.conf` from August 2026 was
intact, valid and complete, and useless for exactly that reason once Hyprland
started reading `.lua`. The question is:

> **Does the backup contain the files this system, right now, actually reads?**

And a second one, which decides whether restoring is safe at all:

> **Is this machine on a version OmaBackup knows how to restore onto?**

## Status

The CLI, scheduler, restore TUI and QuickShell panel are working today.

```bash
./bin/omabackup status     # Omarchy version, restore range, groups
./bin/omabackup collect    # collect the groups into staging
./bin/omabackup verify     # check coverage; --json for programmatic use
./bin/omabackup config     # guided settings TUI
./bin/omabackup restore    # guided restore TUI
./test/run.sh              # complete regression suite
```

The QuickShell panel is a client of the CLI. Its Settings and Restore actions
fade the panel out and open the corresponding terminal TUI; the panel never
writes machine configuration or applies a restore itself.

### Configuration and schedules

`omabackup config` is safe to use over SSH or a recovery terminal. It lists
backup folders with numbers, generates a destination name when one is not
provided, explains retention, and offers frequency presets. A script can use
the same contract directly:

```bash
./bin/omabackup config set sync-schedule '*/15 * * * *'
./bin/omabackup config set push-schedule '0 * * * *'
./bin/omabackup config show --json
```

Schedules use the familiar five-field crontab form at the interface. The CLI
validates it and converts it to the systemd `OnCalendar` value behind the
scenes. The systemd expression is retained only as diagnostic data, not as a
value the user has to construct.

## How it works

The cycle has four beats, and the first one is not optional:

```
collect -> staging   diff -> against the repo   verify -> coverage + syntax   commit
```

Without `collect` there is no diff for `mode: copy` groups — and a scheduler
that only fires `verify` would never save `shell.json` or `hypr/*.lua`.

### The group manifest

`groups.default.json` describes what gets saved, along three axes:

| axis | values | decides |
|------|--------|---------|
| `mode` | `link` · `copy` · `gen` · `triple` | how to capture it |
| `coupled` | `true` · `false` | whether it is quarantined on an Omarchy outside the restore range |
| `critical` | `true` · `false` | weight in the report |

`link` is for what only you edit (the live file *is* the repo, no sync step).
`copy` is for what Omarchy rewrites. `triple` is for plugins only: a clean git
checkout stores URL + commit, a dirty one also stores the patch, and one
without a remote is copied in full. Without this, staging would grow by 6.6 MB
of code that already lives on GitHub — or lose the local customization.

**A declared field the collector does not implement aborts `collect`.** Failing
loudly is the point: the first three versions silently ignored `exclude`,
`trackedOnly` and `mode: triple`, and staging went from 1.3 MB to 84 MB without
a word.

### Coverage (T1)

The compositor probe resolves the `require` graph starting from the file
Hyprland *says* it loaded, traverses the package's own modules, and demands
coverage only for the user's files. That is how
`~/.local/state/omarchy/toggles/hypr/flags.lua` shows up — live Lua outside
`~/.config/hypr`, which a directory scan would never find.

Deliberate exclusions live in `excluded[]`, each with its reason versioned
alongside. A checker born with a dozen warnings teaches you to ignore it.

## Design

[`docs/PLAN.md`](docs/PLAN.md) is the living status: where things stand, what's
next, what a fresh session needs to know. [`docs/DESIGN.md`](docs/DESIGN.md) is
the architecture and the review that reshaped it twice. [`docs/CONTEXT.md`](docs/CONTEXT.md)
is the incident that started it all.

## License

MIT

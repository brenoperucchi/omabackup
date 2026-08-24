# The timers

`docs/DESIGN.md` §11.2: the systemd timer is the primary mechanism and the QML
plugin is its face. The panel polls `verify --json` read-only; everything that
writes runs here, where a failure is visible in `systemctl --user --failed`
whether or not the shell is even running.

Two units, on purpose:

| unit | interval | what it does | when it goes red |
|------|----------|--------------|------------------|
| `omabackup-sync` | 15 min | collect → publish → verify → commit | coverage broke, or git refused |
| `omabackup-push` | 1 h | build/reuse the bundle, send to every destination | a destination is unreachable |

Kept apart because a unit whose red means two different things is worse than
two units. An unplugged drive turning the *coverage* timer red every 15 minutes
trains you to ignore the one alarm this project exists to make you not ignore.

## Install

```sh
OMABACKUP_REPO=~/Devs/omarchy-personal omabackup install
```

That writes both units, records the repo in `~/.config/omabackup/env`, reloads
systemd and enables the timers. It is idempotent, and it never overwrites an
`env` file you have edited.

**This step cannot be automatic.** `omarchy plugin add` clones and enables a
plugin and runs no hook from it — a sound refusal to execute code fetched from
a URL. So a fresh install gets the bar widget and the CLI and *no automation at
all* until this runs. Which is why `omabackup verify` warns
`nothing is scheduled to run the backup` until it does, and `status --json`
carries `.scheduler.active` for the panel: a backup nothing runs is a backup
that does not happen, and that must never be a silent state.

`ExecStart` is rewritten to whichever copy of the tool ran `install`. Run it
from the installed plugin for a real setup; running it from a working copy wires
the timers to that checkout, which is what you want while developing and not
what you want otherwise.

## Check on it

```sh
systemctl --user list-timers 'omabackup-*'   # when each next fires
systemctl --user status omabackup-sync       # last run, exit code
journalctl --user -u omabackup-sync -n 50    # what it actually said
```

A red `omabackup-sync` means the backup no longer covers what the system reads.
Run `omabackup verify` to see which group, and fix that — do not disable the
timer. `docs/DESIGN.md` §11.2 has the repair procedure for a broken `mode:link`
path, and it is never `ln -sf`: that would discard the very edit that broke it.

## Turning it off

```sh
systemctl --user disable --now omabackup-sync.timer omabackup-push.timer
```

Nothing else needs undoing — the units write only through the CLI, and the CLI
writes only into `$OMABACKUP_STATE` and the destination repo.

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
mkdir -p ~/.config/systemd/user
cp systemd/omabackup-*.{service,timer} ~/.config/systemd/user/

# Machine identity: which repo receives the backup.
mkdir -p ~/.config/omabackup
echo "OMABACKUP_REPO=$HOME/Devs/omarchy-personal" > ~/.config/omabackup/env

systemctl --user daemon-reload
systemctl --user enable --now omabackup-sync.timer omabackup-push.timer
```

`ExecStart` points at the installed plugin
(`~/.config/omarchy/plugins/brenoperucchi.omabackup/bin/omabackup`). Point it at
a working copy instead if you are developing.

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

# OmaBackup — agent instructions

Read `docs/PLAN.md` in full before doing anything else in this repo, every
session, regardless of which coding agent you are. It is the living status
document: what exists, what was decided and why, what broke and how it was
found, what is next. `docs/DESIGN.md` and `docs/CONTEXT.md` are the
architecture and the incident behind it — read them when `PLAN.md` points to
them, not by default.

## Working here

- Bug fix workflow: reproduce with a permanent regression spec first (it must
  fail before the fix, pass after), keep it in the suite, run
  `./test/run.sh` before calling anything done.
- `~/Devs/omabackup` (this repo) is code only, public, GitHub. Backup *data*
  never belongs here.
- `~/Devs/omarchy-personal` is the user's actual dotfiles — private, and is
  `OMABACKUP_REPO`. OmaBackup's own code never belongs there.
- Update `docs/PLAN.md` before ending a session — see its own header.

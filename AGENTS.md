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

## Reviewer colleagues

If you're running as `omabackup-exec` inside a Herdr workspace, `omabackup-rev`
(Codex) and `omabackup-rev-2` (Claude Opus) are two independent reviewers
alive in sibling panes of the same workspace right now — not hypothetical,
nothing to set up. When you finish a reviewable unit of work, use the
`herdr-review` skill to dispatch a blind, parallel review round to both and
resolve their findings (CONFIRMED/UNIQUE/CONFLICT) before considering the
work done. The same pair can also weigh in on an open design question
*before* you build something — see the `herdr-ask` skill for that case.
Requires `HERDR_ENV=1`; if that's unset, you're not in a Herdr-managed pane
and none of this applies. Never use your own CLI's native sub-agent
mechanism (e.g. Codex's `agents`/`pipeline_reviewer`, Claude's `Agent` tool)
as a substitute for this — those spawn ephemeral, invisible processes
outside Herdr with no pane and no persistent identity. Every review round,
including an extra or "final" one, goes back through `herdr-review`.

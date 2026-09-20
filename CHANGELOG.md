# Changelog

All notable changes to OmaBackup are recorded here. The version numbers are the
ones published in `manifest.json` and read by the Omarchy Plugin Manager.

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
loosely while it is pre-1.0: patch releases may still change behaviour when the
change closes a security hole, and such changes are always called out here.

## [0.4.6] — 2026-09-20

Security hardening. A patch number, but it refuses something that used to be
allowed — read the first item before upgrading.

### Security

- **A publicly readable GitHub repository is refused as a backup destination.**
  Before a push, the destination's visibility is probed with an anonymous,
  canonical GitHub API request whose redirects are restricted to the expected
  host. A repository anyone can read is no longer pushed to. If your backup
  repository is public, `push` will now stop instead of publishing your
  dotfiles; make it private, or point `OMABACKUP_REPO` somewhere else.
  This gate governs only the private backup repository, never the public
  OmaBackup source checkout.
- **The whole push URL set is checked, not just the fetch URL.** `origin` and
  every `remote.*.pushurl` are normalized and probed, and per-destination
  results are reported so one failing destination does not hide the others.
- **Remote spellings that used to slip past the probe are closed.** The URL
  scheme is no longer consulted at all; whatever precedes `://`, the host
  decides. `https::https://github.com/o/r`, a percent-encoded host
  (`https://%67ithub.com/o/r`), `git+ssh://`, `ssh+git://` and upper-case
  schemes were all read as "not GitHub" and pushed to unasked. What cannot be
  read unambiguously is refused closed rather than guessed: a `%` anywhere in
  the host is refused rather than decoded, so no second decoder has to agree
  with git's byte for byte.
- **`ext::` transport helpers are rejected before parsing, probing or
  pushing.** An arbitrary-command transport cannot be resolved to a host, so it
  cannot be proven private. Both the SSH-shaped and the URL-shaped
  (`ext::https://github.com/o/r`) forms are refused.
- **A 404 from a `curl` that exited non-zero is no longer read as
  permission.** The response text and the exit status are validated separately;
  any non-zero exit is inconclusive whatever was printed. The detail now reads
  `HTTP 404, curl exit 18` so a 404 in the log is not misread.

### Fixed

- `curl` is no longer required up front by `push`, which blocked machines using
  only `dir` destinations. It is looked for inside the GitHub gate, at the
  moment there is a GitHub repository to ask about, and names `pacman -S curl`
  if missing.

### Testing

- The installation specs now create a temporary, private `XDG_RUNTIME_DIR` for
  the real `systemd-analyze --user verify` calls. Three failures previously
  blamed on invalid units came from the environment's `/nonexistent` runtime
  directory. Positive coverage and the negative control are unchanged.
- Permanent regressions cover every remote spelling above, including both
  `ext::` forms.
- Full suite on the release commit: **1450 passed, 0 failed**.

### Thanks

- The remote privacy gate came from [Corey Tyhurst](https://github.com/coreytyhurst)'s
  [PR #1](https://github.com/brenoperucchi/omabackup/pull/1).

## [0.4.5] — 2026-09-18

- Refuse to push to a publicly readable GitHub repository (first landing of the
  gate; superseded by the hardening in 0.4.6, which you should prefer).
- Lock files are opened once with `O_NOFOLLOW` from an already validated
  directory descriptor, and that descriptor is preserved through the critical
  section. The previous `exec N>path` reopened the name and left a TOCTOU
  window; a planted symlink could truncate an external target. Covers
  `.prune.lock`, the per-action failure lock and `destinations.json.lock`.
- Added the upstream **Built for Omarchy** badge to the README.

## [0.4.4] — 2026-09-13

- Hardened startup and atomic writes.

## [0.4.3] — 2026-09-09

- The title row's "OmaBackup" text was 4.5px off-center.

## [0.4.2] — 2026-09-07

- Closed three marketplace security findings, on artifact listing, on push, and
  on VM checksum trust.
- Panel height cap and `recentLog` sample corrected; screenshots updated.
- Version bump itself: the security fixes in the previous commit never bumped
  the manifest, so the Plugin Manager showed a bare "update" instead of a
  version arrow.

## [0.4.1] — 2026-09-03

- Panel copy fixes, and a title-row/activity reorganisation for real GitHub
  accessibility.

## [0.4.0] — 2026-09-02

- Read the log back: a Settings TUI item and a panel section.

## [0.3.0] — 2026-09-02

- The panel logs its own two previously undiagnosable failures.
- A persistent log of what OmaBackup does, with time-based retention.
- Settings TUI offers to fix repo/timer dead ends, not just report them.
- GitHub moved to its own top-row button, opening the local repository.
- Restore hardening: an extraction-time ceiling and its own bypasses, a
  decompression bomb, a `killGroup` backstop and a member-cap bypass.
- Stopped shipping agent-instruction files to the installed plugin.
- Bar icon iterated to Material Design's `md-folder_sync` after several
  variants rendered blank or nearly invisible.
- Added the MIT LICENSE file, install/uninstall documentation, screenshots and
  a marketplace preview image.

## [0.2.2] — 2026-08-31

- Restore button colour, and missing Send-schedule test coverage.
- Fixed broken TUI completion IPC and `tui_read_line` variable shadowing; added
  a git-init bootstrap.

## [0.2.1] — 2026-08-30

- Shipped the configuration and restore TUI.
- An extended adversarial audit of restore, publish, collect, verify and
  secrets closed a long series of fail-open findings: mid-tree symlink aliases,
  containment checks that followed live symlinks, an id-injection path, a
  source read escape, a `.plugins/local` TOCTOU, `$HOME` compared by raw
  spelling rather than canonical form, unknown group modes applied as a plain
  copy, and refused files that vanished silently.
- `restore --json` gained an expanded plan and a durable apply journal;
  `artifacts --json` landed alongside it.

## [0.1.0] — 2026-08-24

- First release: the group manifest, `collect` and `verify`.

[0.4.6]: https://github.com/brenoperucchi/omabackup/releases/tag/v0.4.6

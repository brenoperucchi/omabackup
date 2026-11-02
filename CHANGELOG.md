# Changelog

All notable changes to OmaBackup are recorded here. The version numbers are the
ones published in `manifest.json` and read by the Omarchy Plugin Manager.

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
loosely while it is pre-1.0: patch releases may still change behaviour when the
change closes a security hole, and such changes are always called out here.

## [0.5.0] — 2026-11-02

The `secrets` group can now keep files such as `rclone.conf` in your backup,
encrypted with [age](https://github.com/FiloSottile/age) for public keys you
choose. It does nothing until you list files for it. Refusals from the secret
scan before a push no longer print what they matched.

### Read before upgrading

- Nothing changes for the `secrets` group until you list files in
  `~/.config/omabackup/secrets/files.json`. Once you do, `sync` needs
  `age` and a `recipients.txt` you accepted with `omabackup secrets accept`,
  and stops until both are in place. A changed `recipients.txt` stops it again
  until you accept it.
- `collect` refuses while a file you listed could leave in the clear by
  another route: a group that copies its path, a staged file with the same
  bytes, or a git plugin whose patch carries them. This holds even when the
  `secrets` group is left out with `--groups`. `collect` also refuses a staged
  file, or a file in a git plugin's patch, named `.omabackup-restore.*`, the
  temporary name `secrets restore` writes through.
- If `OMABACKUP_GROUPS` points at your own manifest, its `secrets` group keeps
  the old definition. Set its `mode` to `age` and remove `"enabled": false`
  before listing files.
- The panel runs the CLI bundled with the plugin before anything named
  `omabackup` on your PATH, another copy of OmaBackup included. Restart the
  shell, or run `omabackup reload`, for the panel to pick this up.

### Added

- The `secrets` group has mode `age`. Each file named in `files.json` is
  encrypted with `age -R` for the keys in `recipients.txt`, and only the
  ciphertext reaches `secrets/age/` in the repository, next to an encrypted
  index of where each file lives. Both files are local config, so whoever
  controls the repository cannot add a recipient. A file must be regular, not
  a symlink, and at most 1 MiB, and the list holds at most 1000 files. A file
  that has not changed keeps its ciphertext while the recipients and the local
  state stay the same, so a sync with nothing new is not a commit.
- `omabackup secrets drill -i <identity>` decrypts every file with one
  identity and compares it with the live copy. `verify` warns about each
  recipient never drilled, or not drilled in 90 days.
- `omabackup secrets restore -i <identity>` prints a plan and writes only with
  `--apply`. It never replaces a file that differs unless you pass `--force`,
  and it writes only into directories private to you under `~/`, never inside
  the backup or under a path another group copies in the clear.
- An identity file wrapped with `age -p` works with `-i`, binary or armored
  (`age -p -a`, the form you can print). age asks for its passphrase.
- `omabackup help` lists `install`, `sync`, `bundle` and `push`.

### Security

- A push refusal names the rule and where to look (the commit, the file and
  the line) and no longer prints the matched text. The hourly push used to
  copy it to the journal on every run until the history was rewritten. A file
  or ref name a rule matches is not printed either, and neither is a file name
  git prints quoted.
- The refusals raised while the push scan reads the refs (a tag chain deeper
  than 32, an unreadable tag or blob, a tag with no target) no longer print a
  ref name a rule matches.

### Testing

- Full suite on a real Omarchy session: 1777 passed, 0 failed.

### Thanks

- [Corey Tyhurst](https://github.com/coreytyhurst) wrote the push refusal
  redaction in [PR #7](https://github.com/brenoperucchi/omabackup/pull/7), the
  panel CLI order in [PR #6](https://github.com/brenoperucchi/omabackup/pull/6),
  the complete usage text in
  [PR #8](https://github.com/brenoperucchi/omabackup/pull/8) and the ref name
  redaction in [PR #9](https://github.com/brenoperucchi/omabackup/pull/9).

## [0.4.9] — 2026-10-22

Backups are now readable by their owner only. Earlier versions wrote every
bundle, and its copy in a `dir` destination, readable by any local user who
could reach the directory. Read the first section to close the copies that
already exist.

### Read before upgrading

- Under the usual 022 umask, bundles written by 0.4.8 and earlier are mode
  0644. OmaBackup closes the ones it can reach. The state directory, which
  holds the bundle cache, loses group and other access on the next sync, and a
  push tightens its own older bundles in a destination it owns, one holding a
  `.omabackup-destination` stamp. In a destination without the stamp, close
  them yourself. `--no-dereference` matters on a shared destination, where
  someone else could have left a symlink under a bundle's name:

  ```
  chmod --no-dereference 600 -- /path/to/destination/omabackup-*.tar.zst
  ```

- OmaBackup cannot promise owner-only access where the filesystem decides
  otherwise. A drive formatted vfat or exFAT has no per-file permissions, so
  its mount options decide who can read a bundle there. A default ACL can also
  grant access the umask does not control. A bundle in the cache stays 0600
  only while the state directory carries no default ACL that opens it, and its
  copy in a destination keeps that mode. In a stamped destination, the
  `chmod 600` on older bundles removes access an ACL had granted to those
  files.
- If you set `OMABACKUP_STATE` to a directory of your own, `collect` now
  removes group and other access from it. Point it at a directory only
  OmaBackup uses.

### Security

- The bundle is created 0600, and so is its copy in a `dir` destination,
  whatever the umask (see the ACL note above). zstd and cp created them 0644
  under the usual 022 umask, and the shipped services set none. Found in the
  marketplace maintainer's review of 0.4.8.
- The state directory (`~/.local/state/omabackup`) and the bundle cache lose
  group and other access on every collect and build. That also covers staging,
  plugin patches and the generated package lists.
- `restore --into` creates its target 0700, and so does `omabackup config`
  when it offers to create the backup repository.
- A JSON file whose keys are sorted on publish keeps its source's mode. A 0600
  `shell.json` used to be published 0644.
- Both systemd services run with `UMask=0077`. Run `omabackup reload` once
  after updating so the installed units pick it up (it also restarts the
  shell); `omarchy plugin update` alone does not rewrite them.

### Testing

- Full suite on a real Omarchy session: 1631 passed, 0 failed.

## [0.4.8] — 2026-10-22

Secrets are now refused before they reach your local backup, not only before a
push. `sync` can stop in cases where 0.4.7 went through, so read the first
section before upgrading.

### Read before upgrading

- `sync` scans what `collect` staged before publishing it, with or without
  `--commit`. A file that matches the deny-list stops the sync: nothing is
  published or committed, staging is cleared, and every timer run refuses
  again until you remove the credential from the live file, exclude that file
  in its group, or add a justified exception to `secrets.deny.json`. In 0.4.7
  the same file was committed to local history and only `push` refused it.
- A file you encrypt with a git clean filter, such as git-crypt, is refused
  too when its plain text matches a pattern. The scan reads staging, before
  git runs the filter, so it sees the plain text. Exclude the file in its
  group or add an exception for it.
- `sync --commit` refuses while a merge, cherry-pick, revert or rebase is in
  progress in the backup repository. It also refuses when something other than
  the sync changed the commit it was building, for example a git hook, an
  fsmonitor or a wrapper around git.
- `collect` refuses the package lists whenever any pacman query prints an
  `error:` line, whatever its exit status. That includes configuration errors
  that leave the lists intact, such as a repository section declared twice in
  `pacman.conf`, which 0.4.7 collected. The refusal shows pacman's first
  `error:` line so you can find the cause.

### Security

- `sync --commit` scans the commit before any branch moves. It builds the
  commit in its own index, writes the tree and scans what that tree adds: file
  names, the directories above them, the file contents read back from git by
  object id, and the commit object itself. A hit, or a scan that cannot run,
  refuses the commit and leaves your index and branch as they were. This
  catches what the staging scan cannot see, such as a clean filter that adds a
  credential. The commit is made with `write-tree`, `commit-tree` and a
  compare-and-swap `update-ref`, with hooks and fsmonitor turned off.
- Every scanner runs under the C locale. Under a UTF-8 locale, a byte that is
  not valid UTF-8 right before a token hid it from grep, and the systemd user
  manager runs with a UTF-8 `LANG`. The push scan in 0.4.6 and 0.4.7 had this
  gap on the timer.
- The push scan passes `--no-color` to git. With `color.ui=always` in git's
  config, the colour codes hid a token from it.
- A refusal names the rule, the file and the line number, and never prints the
  matched line, so a credential does not end up in the journal. A file name
  that matches is not printed either.
- File names are also judged piece by piece between newlines, the way `push`
  reads them, so a rule that matches a piece in `push` matches it in `sync`
  too.

### Fixed

- An `error:` from any of the three pacman queries now refuses `collect`
  whatever their exit status, so a corrupted native package entry can no
  longer publish three shortened lists. This closes the known gap listed in
  0.4.7.

### Testing

- Full suite on a real Omarchy session: 1617 passed, 0 failed.

### Thanks

- [Corey Tyhurst](https://github.com/coreytyhurst) wrote the staging scan in
  [PR #3](https://github.com/brenoperucchi/omabackup/pull/3) and moved the
  `error:` check across every package list in
  [PR #4](https://github.com/brenoperucchi/omabackup/pull/4).

## [0.4.7] — 2026-09-26

### Fixed

- `collect` works on a machine with no foreign (AUR) packages. `pacman -Qqem`
  exits 1 when it has nothing to list, and it uses the same status when it
  cannot read its database, so a fresh install or a clean container could not
  run `collect` or `sync`. OmaBackup now accepts an empty foreign list only
  when the status is exactly 1, nothing was printed, the explicit and native
  lists match, and none of the three queries reported an `error:`. The empty
  list is staged, so a machine that removed its last AUR package overwrites
  the old list in the repository.

### Security

- A corrupted local package database can no longer make an empty foreign list
  look valid. pacman leaves out any entry it cannot parse, in every query, and
  still exits 0, so the explicit and native lists can match while real
  packages are missing. The queries now run as
  `LC_ALL=C LANGUAGE= pacman --color never`, and an `error:` line from any of
  them rejects the empty list. The pinned locale matters: with
  `LANGUAGE=pt_BR`, pacman prints `erro:` instead. `warning:` lines are
  allowed, for example when a repository in `pacman.conf` has not been synced
  yet.
- The native query does not get the same allowance. Without a sync database
  pacman reports every package as foreign, and accepting an empty native list
  would record the whole system as AUR.

### Known gap

- A query that exits 0 with an `error:` line and a non-empty foreign list can
  still publish shortened lists. This existed before 0.4.7 and will be fixed
  separately.

### Testing

- 15 new specs in `test/collect.test.sh`. Some of them fail a naive `|| true`
  fix, and they also catch three mutants (locale pin, colour, veto scope).
- Full suite on a real Omarchy session: 1465 passed, 0 failed.

### Thanks

- [Corey Tyhurst](https://github.com/coreytyhurst) found the bug and wrote the
  fix and its specs in [PR #2](https://github.com/brenoperucchi/omabackup/pull/2).

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

[0.4.7]: https://github.com/brenoperucchi/omabackup/releases/tag/v0.4.7
[0.4.6]: https://github.com/brenoperucchi/omabackup/releases/tag/v0.4.6

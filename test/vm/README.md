# OmaBackup VM restore test

This is the real T4 test. It runs the current CLI and a real bundle inside an
Omarchy guest, not a QML mock and not a container. The host uses QEMU/KVM with
OVMF and a copy-on-write overlay. The golden image is never modified.

## Host requirements

The host needs `/dev/kvm`, `qemu-system-x86_64`, `qemu-img`, `python3`, `ssh`,
`scp`, `jq`, `zstd`, `sha256sum`, `ss`, `tar`, `timeout`, an OVMF pair, a
golden Omarchy disk image, and an SSH key whose public half is authorized for
the golden guest user.

The runner defaults to `~/VMs/omabackup/` so disk images and failure evidence
never enter this public repository.

## Golden image contract

Create one clean Omarchy installation and provision it once with:

- guest user `omatest` (or pass `--user`);
- the matching `id_ed25519.pub` in `~/.ssh/authorized_keys`;
- the golden guest host key pinned in `~/VMs/omabackup/known_hosts` as
  `[127.0.0.1]:2222`; never use a blind TOFU or `StrictHostKeyChecking=no`;
- passwordless sudo for that test user;
- SSH enabled and reachable after boot;
- SDDM autologin into Hyprland;
- the normal Omarchy QuickShell session enabled;
- a writable `/tmp` and the guest user's home.

The normal restore run does not reinstall Omarchy. Rebuilding the golden image
is a separate, slower operation because it tests provisioning/installation,
not restore. The repository includes an opt-in builder for a repeatable
fixture. It uses the official unattended-install `cidata` contract, downloads
the versioned ISO when absent, creates a fresh unencrypted `qcow2`, enables the
test user's passwordless sudo, and pins the resulting SSH host key:

```bash
test/vm/build-golden.sh
```

The builder asks for a temporary guest password and refuses to overwrite an
existing disk. It leaves the ISO, key, golden disk, and `known_hosts` under
`~/VMs/omabackup/`; those files are local test data and must never be copied to
this public repository. The install model follows Omarchy's [unattended
install documentation](https://github.com/basecamp/omarchy/blob/quattro/manual/51-unattended-installs.md).
After provisioning, the builder powers the guest off, starts a fresh QEMU
process from the installed disk, verifies SSH plus the graphical contract
again, and only then declares the golden ready.

If the official ISO or the local host cannot be used, the golden can still be
installed manually from the normal Omarchy flow; the contract above remains
the same.

The current real artifact contains one intentional absolute symlink in
`state/omarchy/current/background`; the runner allows exactly that known safe
refusal and rejects any other escaped path. Set
`OMABACKUP_VM_EXPECTED_ESCAPE_REPO=` to require zero escapes for a different
artifact/manifest.

## Run

Use the newest local bundle:

```bash
test/vm/run.sh
```

Or select an explicit artifact and image:

```bash
test/vm/run.sh \
  --golden "$HOME/VMs/omabackup/golden.qcow2" \
  --artifact "$HOME/.local/state/omabackup/bundles/example.tar.zst"
```

The runner boots the overlay, waits for SSH, copies the real artifact and
current CLI, validates a JSON plan, runs `restore --apply`, checks the durable
journal and restored shell configuration, restarts SDDM, checks QuickShell and
Hyprland, captures a QMP screenshot, and discards the overlay.

Failures preserve serial output, QEMU output, restore output, plan JSON and a
PPM screenshot under a `~/VMs/omabackup/failures.<UTC timestamp>.<suffix>/`
directory. Pass
`--keep-on-failure` when debugging the temporary guest disk.

## Installer test

An ISO/installer automation job is intentionally separate. It may create or
refresh the golden image, but it must not run as part of every restore test.

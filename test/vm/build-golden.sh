#!/usr/bin/env bash
# Build a disposable Omarchy golden image through the official unattended ISO
# installer. The resulting disk lives outside the repository and is never
# modified by test/vm/run.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

VM_ROOT="${OMABACKUP_VM_ROOT:-$HOME/VMs/omabackup}"
VERSION="${OMARCHY_VM_VERSION:-4.0.1}"
ISO="${OMARCHY_VM_ISO:-$VM_ROOT/omarchy-$VERSION.iso}"
ISO_SHA256="${OMARCHY_VM_ISO_SHA256:-}"
DISK="${OMARCHY_VM_GOLDEN:-$VM_ROOT/golden.qcow2}"
SSH_KEY="${OMARCHY_VM_SSH_KEY:-$VM_ROOT/id_ed25519}"
KNOWN_HOSTS="${OMARCHY_VM_KNOWN_HOSTS:-$VM_ROOT/known_hosts}"
GUEST_USER="${OMARCHY_VM_USER:-omatest}"
GUEST_HOST="127.0.0.1"
SSH_PORT="${OMARCHY_VM_SSH_PORT:-2222}"
MEMORY="${OMARCHY_VM_MEMORY:-4096}"
CPUS="${OMARCHY_VM_CPUS:-4}"
DISK_SIZE="${OMARCHY_VM_DISK_SIZE:-32G}"
TIMEOUT_SEC="${OMARCHY_VM_INSTALL_TIMEOUT:-1800}"
KEEP_ON_FAILURE="${OMARCHY_VM_KEEP_ON_FAILURE:-0}"
OVMF_CODE="${OMARCHY_VM_OVMF_CODE:-/usr/share/edk2/x64/OVMF_CODE.4m.fd}"
OVMF_VARS="${OMARCHY_VM_OVMF_VARS:-/usr/share/edk2/x64/OVMF_VARS.4m.fd}"

usage() {
    cat <<'USAGE'
Usage: test/vm/build-golden.sh [options]

Download the official Omarchy ISO when needed, perform an unattended
unencrypted install into a new qcow2 disk, provision SSH/NOPASSWD access, and
leave a golden image for test/vm/run.sh.

Options:
  --iso PATH       Omarchy ISO (default: ~/VMs/omabackup/omarchy-VERSION.iso)
  --sha256 HASH    expected SHA-256 (default: official sidecar for versioned ISO)
  --golden PATH    output disk (default: ~/VMs/omabackup/golden.qcow2)
  --ssh-key PATH   key to authorize in the guest
  --user USER      guest user (default: omatest)
  --port PORT      forwarded SSH port (default: 2222)
  --timeout SEC    installer timeout (default: 1800)
  --keep-on-failure preserve installer logs for debugging
  -h, --help       show this help

The builder is intentionally separate from the restore runner. It may take a
long time and downloads the ISO from https://iso.omarchy.org/.
USAGE
}

die() {
    printf 'omabackup-vm-build: %s\n' "$*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "missing host dependency: $1"
}

while (($#)); do
    case "$1" in
        --iso) [[ $# -ge 2 ]] || die "--iso needs a path"; ISO="$2"; shift 2 ;;
        --sha256) [[ $# -ge 2 ]] || die "--sha256 needs a hash"; ISO_SHA256="$2"; shift 2 ;;
        --golden) [[ $# -ge 2 ]] || die "--golden needs a path"; DISK="$2"; shift 2 ;;
        --ssh-key) [[ $# -ge 2 ]] || die "--ssh-key needs a path"; SSH_KEY="$2"; shift 2 ;;
        --user) [[ $# -ge 2 ]] || die "--user needs a name"; GUEST_USER="$2"; shift 2 ;;
        --port) [[ $# -ge 2 ]] || die "--port needs a number"; SSH_PORT="$2"; shift 2 ;;
        --timeout) [[ $# -ge 2 ]] || die "--timeout needs seconds"; TIMEOUT_SEC="$2"; shift 2 ;;
        --keep-on-failure) KEEP_ON_FAILURE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

need curl
need genisoimage
need jq
need openssl
need qemu-img
need qemu-system-x86_64
need numfmt
need sha256sum
need ssh
need ssh-keygen
need ssh-keyscan
need timeout
need ss

[[ -e /dev/kvm ]] || die "KVM is unavailable at /dev/kvm"
[[ -f "$OVMF_CODE" ]] || die "OVMF code not found: $OVMF_CODE"
[[ -f "$OVMF_VARS" ]] || die "OVMF vars template not found: $OVMF_VARS"
[[ "$SSH_PORT" =~ ^[0-9]+$ && SSH_PORT -ge 1024 && SSH_PORT -le 65535 ]] \
    || die "SSH port must be between 1024 and 65535"
[[ "$TIMEOUT_SEC" =~ ^[0-9]+$ && TIMEOUT_SEC -ge 60 ]] \
    || die "timeout must be at least 60 seconds"
[[ "$GUEST_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] \
    || die "guest user must contain only lowercase letters, digits, underscores, and hyphens"
if ss -Hln "sport = :$SSH_PORT" 2>/dev/null | grep -q .; then
    die "SSH port is already in use: $SSH_PORT"
fi

mkdir -p "$VM_ROOT" "$(dirname "$DISK")" "$(dirname "$SSH_KEY")" "$(dirname "$KNOWN_HOSTS")"
if [[ ! -f "$SSH_KEY" ]]; then
    ssh-keygen -q -t ed25519 -N '' -f "$SSH_KEY" -C omabackup-vm
fi
[[ -f "$SSH_KEY.pub" ]] || ssh-keygen -y -f "$SSH_KEY" >"$SSH_KEY.pub"

if [[ ! -f "$ISO" ]]; then
    printf 'omabackup-vm-build: downloading %s\n' "https://iso.omarchy.org/omarchy-$VERSION.iso"
    curl -fL --retry 3 --progress-bar \
        -o "$ISO.part" "https://iso.omarchy.org/omarchy-$VERSION.iso"
    mv -- "$ISO.part" "$ISO"
fi
[[ -s "$ISO" ]] || die "Omarchy ISO is empty: $ISO"
if [[ -z "$ISO_SHA256" && "$(basename "$ISO")" == "omarchy-$VERSION.iso" ]]; then
    ISO_SHA256="$(curl -fsSL --retry 3 "https://iso.omarchy.org/omarchy-$VERSION.iso.sha256" | awk 'NR == 1 {print $1}')"
fi
[[ "$ISO_SHA256" =~ ^[[:xdigit:]]{64}$ ]] \
    || die "provide a 64-character ISO SHA-256 with --sha256 or OMARCHY_VM_ISO_SHA256"
printf '%s  %s\n' "$ISO_SHA256" "$ISO" | sha256sum -c - >/dev/null \
    || die "Omarchy ISO checksum mismatch: $ISO"

[[ ! -e "$DISK" ]] || die "refusing to overwrite existing golden disk: $DISK"

BUILD_DIR="$(mktemp -d "$VM_ROOT/build.XXXXXX")"
RUN_DIR="$(mktemp -d "$VM_ROOT/install.XXXXXX")"
DISK_CREATED=0
cleanup() {
    local rc=$?
    set +e
    if [[ -n "${QEMU_PID:-}" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        for _ in {1..50}; do
            kill -0 "$QEMU_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -KILL "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    if (( rc != 0 )); then
        failure_dir="$(mktemp -d "$VM_ROOT/build-failures.XXXXXX" 2>/dev/null || true)"
        if [[ -n "$failure_dir" ]]; then
            for log in install.log qemu.log provision-serial.log provision-qemu.log; do
                [[ -f "$RUN_DIR/$log" ]] && cp -f -- "$RUN_DIR/$log" "$failure_dir/$log"
            done
            printf 'omabackup-vm-build: failure evidence: %s\n' "$failure_dir" >&2
        fi
    fi
    rm -rf -- "$BUILD_DIR"
    if (( rc == 0 || KEEP_ON_FAILURE == 0 )); then
        rm -rf -- "$RUN_DIR"
    else
        printf 'omabackup-vm-build: kept build directory: %s\n' "$RUN_DIR" >&2
    fi
    if (( rc != 0 && DISK_CREATED == 1 && KEEP_ON_FAILURE == 0 )); then
        rm -f -- "$DISK"
    elif (( rc != 0 && DISK_CREATED == 1 && KEEP_ON_FAILURE == 1 )); then
        printf 'omabackup-vm-build: kept partial golden disk: %s\n' "$DISK" >&2
    fi
    exit "$rc"
}
trap cleanup EXIT

PASSWORD="${OMARCHY_VM_PASSWORD:-}"
if [[ -z "$PASSWORD" ]]; then
    read -r -s -p 'Password for the golden guest user (not saved in the repository): ' PASSWORD
    printf '\n'
fi
[[ -n "$PASSWORD" ]] || die "guest password cannot be empty"

DISK_BYTES="$(numfmt --from=iec -- "$DISK_SIZE" 2>/dev/null || true)"
[[ "$DISK_BYTES" =~ ^[0-9]+$ ]] || die "could not determine disk size for archinstall config"
MIB=$((1024 * 1024))
GIB=$((MIB * 1024))
DISK_MIB=$((DISK_BYTES / MIB * MIB))
BOOT_START=$MIB
BOOT_SIZE=$((2 * GIB))
GPT_RESERVE=$MIB
MAIN_START=$((BOOT_START + BOOT_SIZE))
MAIN_SIZE=$((DISK_MIB - MAIN_START - GPT_RESERVE))
(( MAIN_SIZE > 0 )) || die "golden disk is too small for the Omarchy layout"

PASSWORD_HASH="$(openssl passwd -6 -- "$PASSWORD")"
PUBKEY="$(<"$SSH_KEY.pub")"
printf '%s\n' "$PUBKEY" >"$BUILD_DIR/authorized_keys"

# This follows the fields produced by the official Omarchy configurator. The
# disk is deliberately unencrypted: the fixture is disposable and must boot
# unattended after the installer exits.
cat >"$BUILD_DIR/user_configuration.json" <<JSON
{
  "app_config": null,
  "archinstall-language": "English",
  "auth_config": {},
  "audio_config": {"audio": "pipewire"},
  "bootloader": "Limine",
  "custom_commands": [
    "printf '%s\\n' '$GUEST_USER ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/omabackup-vm && chmod 440 /etc/sudoers.d/omabackup-vm"
  ],
  "disk_config": {
    "btrfs_options": {"snapshot_config": {"type": "Snapper"}},
    "config_type": "default_layout",
    "device_modifications": [{
      "device": "/dev/vda",
      "partitions": [
        {
          "btrfs": [],
          "dev_path": null,
          "flags": ["boot", "esp"],
          "fs_type": "fat32",
          "mount_options": [],
          "mountpoint": "/boot",
          "obj_id": "ea21d3f2-82bb-49cc-ab5d-6f81ae94e18d",
          "size": {"sector_size": {"unit": "B", "value": 512}, "unit": "B", "value": $BOOT_SIZE},
          "start": {"sector_size": {"unit": "B", "value": 512}, "unit": "B", "value": $BOOT_START},
          "status": "create",
          "type": "primary"
        },
        {
          "btrfs": [
            {"mountpoint": "/", "name": "@"},
            {"mountpoint": "/home", "name": "@home"},
            {"mountpoint": "/var/log", "name": "@log"},
            {"mountpoint": "/var/cache/pacman/pkg", "name": "@pkg"}
          ],
          "dev_path": null,
          "flags": [],
          "fs_type": "btrfs",
          "mount_options": ["compress=zstd"],
          "mountpoint": null,
          "obj_id": "8c2c2b92-1070-455d-b76a-56263bab24aa",
          "size": {"sector_size": {"unit": "B", "value": 512}, "unit": "B", "value": $MAIN_SIZE},
          "start": {"sector_size": {"unit": "B", "value": 512}, "unit": "B", "value": $MAIN_START},
          "status": "create",
          "type": "primary"
        }
      ],
      "wipe": true
    }]
  },
  "hostname": "omabackup-vm",
  "kernels": ["linux"],
  "network_config": {"type": "iso"},
  "ntp": true,
  "parallel_downloads": 8,
  "script": null,
  "services": [],
  "swap": true,
  "timezone": "UTC",
  "locale_config": {"kb_layout": "us", "sys_enc": "UTF-8", "sys_lang": "en_US.UTF-8"},
  "mirror_config": {
    "custom_repositories": [],
    "custom_servers": [
      {"url": "https://mirror.omarchy.org/\$repo/os/\$arch"},
      {"url": "https://mirror.rackspace.com/archlinux/\$repo/os/\$arch"},
      {"url": "https://geo.mirror.pkgbuild.com/\$repo/os/\$arch"}
    ],
    "mirror_regions": {},
    "optional_repositories": []
  },
  "packages": ["base-devel", "git"],
  "profile_config": {"gfx_driver": null, "greeter": null, "profile": {}},
  "version": "3.0.9"
}
JSON

jq -n --arg hash "$PASSWORD_HASH" --arg user "$GUEST_USER" \
    '{root_enc_password:$hash,
      users:[{enc_password:$hash, groups:[], sudo:true, username:$user}]}' \
    >"$BUILD_DIR/user_credentials.json"
printf 'omarchy\n' >"$BUILD_DIR/user_full_name.txt"
printf 'omabackup-vm@example.invalid\n' >"$BUILD_DIR/user_email_address.txt"
genisoimage -quiet -output "$RUN_DIR/cidata.iso" -volid cidata -joliet -rock "$BUILD_DIR"/*

qemu-img create -q -f qcow2 "$DISK" "$DISK_SIZE"
DISK_CREATED=1
cp -- "$OVMF_VARS" "$RUN_DIR/OVMF_VARS.fd"
INSTALL_LOG="$RUN_DIR/install.log"
QEMU_LOG="$RUN_DIR/qemu.log"
QEMU_PID=""

printf 'omabackup-vm-build: installing Omarchy into %s\n' "$DISK"
timeout --foreground --kill-after=30s "${TIMEOUT_SEC}s" \
qemu-system-x86_64 \
    -name omabackup-golden-install \
    -machine q35,accel=kvm \
    -cpu host \
    -m "$MEMORY" \
    -smp "$CPUS" \
    -nodefaults \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$RUN_DIR/OVMF_VARS.fd" \
    -drive "if=virtio,format=qcow2,file=$DISK" \
    -drive "if=none,media=cdrom,readonly=on,file=$ISO,id=omarchy-iso" \
    -drive "if=none,media=cdrom,readonly=on,file=$RUN_DIR/cidata.iso,id=cidata-iso" \
    -device virtio-scsi-pci,id=scsi \
    -device scsi-cd,drive=omarchy-iso,bus=scsi.0 \
    -device scsi-cd,drive=cidata-iso,bus=scsi.0 \
    -device virtio-gpu-pci \
    -device virtio-keyboard-pci \
    -device virtio-mouse-pci \
    -nic user,model=virtio-net-pci \
    -boot order=d \
    -display none \
    -serial "file:$INSTALL_LOG" \
    -no-reboot \
    >"$QEMU_LOG" 2>&1

printf 'omabackup-vm-build: booting installed image for SSH provisioning\n'
qemu-system-x86_64 \
    -name omabackup-golden-provision \
    -machine q35,accel=kvm \
    -cpu host \
    -m "$MEMORY" \
    -smp "$CPUS" \
    -nodefaults \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$RUN_DIR/OVMF_VARS.fd" \
    -drive "if=virtio,format=qcow2,file=$DISK" \
    -device virtio-gpu-pci \
    -device virtio-keyboard-pci \
    -device virtio-mouse-pci \
    -nic "user,model=virtio-net-pci,hostfwd=tcp:$GUEST_HOST:$SSH_PORT-:22" \
    -display none \
    -serial "file:$RUN_DIR/provision-serial.log" \
    >"$RUN_DIR/provision-qemu.log" 2>&1 &
QEMU_PID=$!

PROVISION_KNOWN_HOSTS="$RUN_DIR/known_hosts"
PROVISION_DEADLINE=$((SECONDS + TIMEOUT_SEC))
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$PROVISION_KNOWN_HOSTS" -o ConnectTimeout=2 \
    -o ConnectionAttempts=1 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
    -i "$SSH_KEY" -p "$SSH_PORT")
provision_remaining() {
    local remaining=$((PROVISION_DEADLINE - SECONDS))
    (( remaining > 0 )) || return 1
    printf '%s' "$remaining"
}
ssh_guest() {
    local remaining
    remaining="$(provision_remaining)" || return 124
    timeout --foreground --kill-after=5s "${remaining}s" \
        ssh "${SSH_OPTS[@]}" "$@"
}
rm -f -- "$PROVISION_KNOWN_HOSTS"
for _ in {1..180}; do
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        die "installed guest exited before SSH became ready"
    fi
    if ssh-keyscan -T 2 -p "$SSH_PORT" "$GUEST_HOST" >"$PROVISION_KNOWN_HOSTS.tmp" 2>/dev/null \
       && [[ -s "$PROVISION_KNOWN_HOSTS.tmp" ]] \
       && mv -- "$PROVISION_KNOWN_HOSTS.tmp" "$PROVISION_KNOWN_HOSTS" \
       && ssh_guest "$GUEST_USER@$GUEST_HOST" true >/dev/null 2>&1; then
        break
    fi
    sleep 2
done
[[ -s "$PROVISION_KNOWN_HOSTS" ]] || die "installed guest did not expose SSH"

if ! ssh_guest "$GUEST_USER@$GUEST_HOST" sudo -n true >/dev/null 2>&1; then
    SUDOERS_LINE="$GUEST_USER ALL=(ALL) NOPASSWD: ALL"
    SUDOERS_COMMAND="printf '%s\\n' '$SUDOERS_LINE' > /etc/sudoers.d/omabackup-vm && chmod 440 /etc/sudoers.d/omabackup-vm"
    printf '%s\n' "$PASSWORD" | ssh_guest "$GUEST_USER@$GUEST_HOST" \
        "sudo -S -p '' sh -c $(printf '%q' "$SUDOERS_COMMAND")" >/dev/null
fi
ssh_guest "$GUEST_USER@$GUEST_HOST" sudo -n true >/dev/null \
    || die "could not establish passwordless sudo in the golden guest"

SDDM_COMMAND="install -d -m 0755 /etc/sddm.conf.d && printf '%s\\n' '[Autologin]' 'User=$GUEST_USER' 'Session=hyprland' > /etc/sddm.conf.d/omabackup-vm.conf"
ssh_guest "$GUEST_USER@$GUEST_HOST" \
    "sudo -n sh -c $(printf '%q' "$SDDM_COMMAND")"
ssh_guest "$GUEST_USER@$GUEST_HOST" \
    'sudo systemctl enable sshd sddm >/dev/null 2>&1' \
    || die "could not enable sshd and sddm in the golden guest"
ssh_guest "$GUEST_USER@$GUEST_HOST" \
    'sudo systemctl restart sddm >/dev/null 2>&1 || true' >/dev/null 2>&1 || true

wait_for_graphical() {
    for _ in {1..90}; do
        if ssh_guest "$GUEST_USER@$GUEST_HOST" bash -s -- "$GUEST_USER" <<'REMOTE'
set -euo pipefail
user="$1"
pgrep -u "$user" -x quickshell >/dev/null
pgrep -u "$user" -x Hyprland >/dev/null
uid="$(id -u "$user")"
runtime="/run/user/$uid"
wayland_display="$(find "$runtime" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' | head -n 1)"
instance_signature="$(find "$runtime/hypr" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | head -n 1)"
[[ -n "$wayland_display" && -n "$instance_signature" ]]
export XDG_RUNTIME_DIR="$runtime" WAYLAND_DISPLAY="$wayland_display" HYPRLAND_INSTANCE_SIGNATURE="$instance_signature"
hyprctl monitors -j | jq -e 'type == "array" and length > 0' >/dev/null
hyprctl layers -j | jq -e '[.. | objects | select(.namespace? == "omarchy-bar")] | length > 0' >/dev/null
REMOTE
        then
            return 0
        fi
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 2
    done
    return 1
}

wait_for_graphical \
    || die "golden guest did not reach an Omarchy graphical session"
ssh_guest "$GUEST_USER@$GUEST_HOST" \
    'sudo systemctl poweroff >/dev/null 2>&1 || true' >/dev/null 2>&1 || true
for _ in {1..30}; do
    kill -0 "$QEMU_PID" 2>/dev/null || break
    sleep 1
done
kill -0 "$QEMU_PID" 2>/dev/null && die "golden guest did not shut down cleanly"

# A successful provisioning boot is not enough: verify that the installed
# image survives a fresh QEMU process and reaches the same graphical contract.
cp -- "$OVMF_VARS" "$RUN_DIR/cold-OVMF_VARS.fd"
printf 'omabackup-vm-build: validating a cold boot of the golden image\n'
PROVISION_DEADLINE=$((SECONDS + TIMEOUT_SEC))
qemu-system-x86_64 \
    -name omabackup-golden-cold-boot \
    -machine q35,accel=kvm \
    -cpu host \
    -m "$MEMORY" \
    -smp "$CPUS" \
    -nodefaults \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$RUN_DIR/cold-OVMF_VARS.fd" \
    -drive "if=virtio,format=qcow2,file=$DISK" \
    -device virtio-gpu-pci \
    -device virtio-keyboard-pci \
    -device virtio-mouse-pci \
    -nic "user,model=virtio-net-pci,hostfwd=tcp:$GUEST_HOST:$SSH_PORT-:22" \
    -display none \
    -serial "file:$RUN_DIR/cold-boot-serial.log" \
    >"$RUN_DIR/cold-boot-qemu.log" 2>&1 &
QEMU_PID=$!

for _ in {1..180}; do
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        die "golden guest exited during cold boot"
    fi
    if ssh_guest "$GUEST_USER@$GUEST_HOST" true >/dev/null 2>&1; then
        break
    fi
    sleep 2
done
ssh_guest "$GUEST_USER@$GUEST_HOST" true >/dev/null 2>&1 \
    || die "golden guest did not expose SSH after cold boot"
wait_for_graphical \
    || die "golden guest did not reach an Omarchy graphical session after cold boot"
ssh_guest "$GUEST_USER@$GUEST_HOST" \
    'sudo systemctl poweroff >/dev/null 2>&1 || true' >/dev/null 2>&1 || true
for _ in {1..30}; do
    kill -0 "$QEMU_PID" 2>/dev/null || break
    sleep 1
done
kill -0 "$QEMU_PID" 2>/dev/null && die "golden guest did not shut down cleanly after cold boot"
mv -- "$PROVISION_KNOWN_HOSTS" "$KNOWN_HOSTS"
printf 'omabackup-vm-build: golden image ready: %s\n' "$DISK"
printf 'omabackup-vm-build: logs retained in %s until cleanup\n' "$RUN_DIR"

#!/usr/bin/env bash
# Run the real restore smoke test inside a disposable Omarchy VM.
#
# The golden image is a separately provisioned fixture. Each invocation boots
# a copy-on-write overlay, transfers the current artifact and tool, runs
# restore --apply in the guest, checks the graphical session, captures QMP
# evidence, and removes the overlay.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

VM_ROOT="${OMABACKUP_VM_ROOT:-$HOME/VMs/omabackup}"
GOLDEN="${OMABACKUP_VM_GOLDEN:-$VM_ROOT/golden.qcow2}"
ARTIFACT="${OMABACKUP_VM_ARTIFACT:-}"
SSH_KEY="${OMABACKUP_VM_SSH_KEY:-$VM_ROOT/id_ed25519}"
KNOWN_HOSTS="${OMABACKUP_VM_KNOWN_HOSTS:-$VM_ROOT/known_hosts}"
SSH_HOST="${OMABACKUP_VM_SSH_HOST:-127.0.0.1}"
SSH_PORT="${OMABACKUP_VM_SSH_PORT:-2222}"
GUEST_USER="${OMABACKUP_VM_USER:-omatest}"
GUEST_HOME="${OMABACKUP_VM_HOME:-/home/$GUEST_USER}"
TIMEOUT_SEC="${OMABACKUP_VM_TIMEOUT:-180}"
KEEP_ON_FAILURE="${OMABACKUP_VM_KEEP_ON_FAILURE:-0}"
RESULTS_DIR="${OMABACKUP_VM_RESULTS:-$VM_ROOT/results}"
MEMORY="${OMABACKUP_VM_MEMORY:-4096}"
CPUS="${OMABACKUP_VM_CPUS:-4}"
OVMF_CODE="${OMABACKUP_VM_OVMF_CODE:-/usr/share/edk2/x64/OVMF_CODE.4m.fd}"
OVMF_VARS="${OMABACKUP_VM_OVMF_VARS:-/usr/share/edk2/x64/OVMF_VARS.4m.fd}"

usage() {
    cat <<'USAGE'
Usage: test/vm/run.sh [options]

Boot an Omarchy golden image in a disposable QEMU/KVM overlay and run the
restore test against a real bundle.

Options:
  --golden PATH       golden boot image
  --artifact PATH     bundle to restore (default: newest local bundle)
  --ssh-key PATH      private key matching the guest golden image
  --known-hosts PATH  pinned SSH host keys for the golden image
  --port PORT         host SSH forwarding port (default: 2222)
  --user USER         guest user (default: omatest)
  --timeout SECONDS   boot/restore timeout (default: 180)
  --keep-on-failure   preserve the temporary VM directory on failure
  -h, --help          show this help

The golden image is not created by this command. See test/vm/README.md.
USAGE
}

die() {
    printf 'omabackup-vm: %s\n' "$*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "missing host dependency: $1"
}

while (($#)); do
    case "$1" in
        --golden) [[ $# -ge 2 ]] || die "--golden needs a path"; GOLDEN="$2"; shift 2 ;;
        --artifact) [[ $# -ge 2 ]] || die "--artifact needs a path"; ARTIFACT="$2"; shift 2 ;;
        --ssh-key) [[ $# -ge 2 ]] || die "--ssh-key needs a path"; SSH_KEY="$2"; shift 2 ;;
        --known-hosts) [[ $# -ge 2 ]] || die "--known-hosts needs a path"; KNOWN_HOSTS="$2"; shift 2 ;;
        --port) [[ $# -ge 2 ]] || die "--port needs a number"; SSH_PORT="$2"; shift 2 ;;
        --user) [[ $# -ge 2 ]] || die "--user needs a name"; GUEST_USER="$2"; GUEST_HOME="/home/$GUEST_USER"; shift 2 ;;
        --timeout) [[ $# -ge 2 ]] || die "--timeout needs seconds"; TIMEOUT_SEC="$2"; shift 2 ;;
        --keep-on-failure) KEEP_ON_FAILURE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

need qemu-system-x86_64
need qemu-img
need ssh
need scp
need python3
need jq
need timeout
need tar
need zstd
need sha256sum
need ss
need realpath

[[ -e /dev/kvm ]] || die "KVM is unavailable at /dev/kvm"
[[ -f "$GOLDEN" ]] || die "golden image not found: $GOLDEN (build it first; see test/vm/README.md)"
canonical_golden() {
    realpath -e -- "$1"
}
GOLDEN="$(canonical_golden "$GOLDEN")" \
    || die "could not resolve golden image: $GOLDEN"
[[ -f "$OVMF_CODE" ]] || die "OVMF code not found: $OVMF_CODE"
[[ -f "$OVMF_VARS" ]] || die "OVMF vars template not found: $OVMF_VARS"
[[ -f "$SSH_KEY" ]] || die "SSH private key not found: $SSH_KEY"
[[ -f "$SSH_KEY.pub" ]] || die "SSH public key not found: $SSH_KEY.pub"
[[ -f "$KNOWN_HOSTS" ]] || die "SSH known_hosts not found: $KNOWN_HOSTS"

if [[ -z "$ARTIFACT" ]]; then
    newest_mtime=-1
    newest_artifact=""
    mapfile -d '' -t candidate_artifacts < <(find "$HOME/.local/state/omabackup/bundles" \
        -maxdepth 1 -type f -name '*.tar.zst' -print0 2>/dev/null)
    for candidate in "${candidate_artifacts[@]}"; do
        [[ -f "$candidate" ]] || continue
        candidate_mtime="$(stat -c %Y "$candidate" 2>/dev/null || printf '%s' -1)"
        if [[ "$candidate_mtime" =~ ^[0-9]+$ ]] && (( candidate_mtime > newest_mtime )); then
            newest_mtime="$candidate_mtime"
            newest_artifact="$candidate"
        fi
    done
    ARTIFACT="$newest_artifact"
fi
[[ -n "$ARTIFACT" && -f "$ARTIFACT" ]] || die "restore artifact not found; pass --artifact PATH"

[[ "$SSH_PORT" =~ ^[0-9]+$ && SSH_PORT -ge 1024 && SSH_PORT -le 65535 ]] \
    || die "SSH port must be between 1024 and 65535"
[[ "$TIMEOUT_SEC" =~ ^[0-9]+$ && TIMEOUT_SEC -ge 10 ]] \
    || die "timeout must be at least 10 seconds"
if ss -Hln "sport = :$SSH_PORT" 2>/dev/null | grep -q .; then
    die "SSH port is already in use: $SSH_PORT"
fi

mkdir -p "$VM_ROOT"
RUN_DIR="$(mktemp -d "$VM_ROOT/run.XXXXXX")"
QEMU_PID=""
QMP="$RUN_DIR/qmp.sock"
SERIAL="$RUN_DIR/serial.log"
QEMU_LOG="$RUN_DIR/qemu.log"
OVERLAY="$RUN_DIR/overlay.qcow2"
VARS="$RUN_DIR/OVMF_VARS.fd"
GUEST_ARTIFACT="/tmp/omabackup-restore.tar.zst"
GUEST_TOOL="/tmp/omabackup-tool.tar"
HOST_TOOL="$RUN_DIR/omabackup-tool.tar"
GUEST_ROWS="/tmp/omabackup-restore-rows.tsv"
HOST_ROWS="$RUN_DIR/restore-rows.tsv"
PLAN_JSON="$RUN_DIR/plan.json"
APPLY_LOG="$RUN_DIR/apply.log"
RUN_DEADLINE=0

capture_qmp() {
    local out="$1"
    [[ -S "$QMP" ]] || return 1
    python3 - "$QMP" "$out" <<'PY'
import json
import socket
import sys

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(5)
sock.connect(sys.argv[1])
reader = sock.makefile("r", encoding="utf-8")

def receive_until_result():
    while True:
        line = reader.readline()
        if not line:
            raise RuntimeError("QMP closed before a response")
        message = json.loads(line)
        if "error" in message:
            raise RuntimeError(message["error"].get("desc", "QMP error"))
        if "return" in message:
            return

reader.readline()  # greeting
sock.sendall(b'{"execute":"qmp_capabilities"}\r\n')
receive_until_result()
sock.sendall((json.dumps({"execute": "screendump", "arguments": {"filename": sys.argv[2]}}) + "\r\n").encode())
receive_until_result()
sock.close()
PY
    [[ -s "$out" ]] || return 1
    [[ "$(head -c 2 "$out")" == "P6" ]] || return 1
    python3 - "$out" <<'PY'
import sys

data = open(sys.argv[1], "rb").read()
parts = data.split(b"\n", 3)
if len(parts) != 4 or parts[0] != b"P6":
    raise SystemExit("invalid PPM header")
try:
    width, height = (int(value) for value in parts[1].split())
    max_value = int(parts[2])
except (ValueError, TypeError):
    raise SystemExit("invalid PPM dimensions")
pixels = parts[3]
if width <= 0 or height <= 0 or max_value != 255 or len(pixels) != width * height * 3:
    raise SystemExit("invalid PPM payload")
sample = {pixels[offset:offset + 3] for offset in range(0, len(pixels), 3)}
if len(sample) < 4 or max(pixels) == 0:
    raise SystemExit("screenshot is visually empty")
PY
}

qmp_quit() {
    [[ -S "$QMP" ]] || return 0
    python3 - "$QMP" <<'PY' >/dev/null 2>&1 || true
import socket
import sys

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(2)
sock.connect(sys.argv[1])
sock.recv(65536)
sock.sendall(b'{"execute":"qmp_capabilities"}\r\n')
sock.recv(65536)
sock.sendall(b'{"execute":"quit"}\r\n')
sock.close()
PY
}

finish() {
    local rc=$? failure_dir
    set +e
    if (( rc != 0 )); then
        failure_dir="$(mktemp -d "$VM_ROOT/failures.$(date -u +%Y%m%dT%H%M%SZ).XXXXXX" 2>/dev/null)"
        if [[ -n "$failure_dir" ]]; then
            # Capture while QEMU is still alive; otherwise the most useful
            # evidence is lost before the cleanup path gets to it.
            capture_qmp "$failure_dir/screenshot.ppm" || true
            [[ -f "$SERIAL" ]] && cp -f "$SERIAL" "$failure_dir/serial.log"
            [[ -f "$QEMU_LOG" ]] && cp -f "$QEMU_LOG" "$failure_dir/qemu.log"
            [[ -f "$PLAN_JSON" ]] && cp -f "$PLAN_JSON" "$failure_dir/plan.json"
            [[ -f "$APPLY_LOG" ]] && cp -f "$APPLY_LOG" "$failure_dir/apply.log"
            printf 'omabackup-vm: failure evidence: %s\n' "$failure_dir" >&2
        fi
        if (( KEEP_ON_FAILURE == 1 )); then
            printf 'omabackup-vm: kept run directory: %s\n' "$RUN_DIR" >&2
        fi
    fi
    if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        qmp_quit
        kill "$QEMU_PID" 2>/dev/null || true
        for _ in {1..50}; do
            kill -0 "$QEMU_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -KILL "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    if (( rc == 0 || KEEP_ON_FAILURE == 0 )); then
        rm -rf -- "$RUN_DIR"
    fi
    exit "$rc"
}
trap finish EXIT

golden_format() {
    local golden="$1" base_format="" image_info=""
    for _ in {1..20}; do
        if image_info="$(qemu-img info --output=json "$golden" 2>/dev/null)" \
            && base_format="$(jq -r '.format // empty' <<<"$image_info")" \
            && [[ "$base_format" =~ ^[A-Za-z0-9._-]+$ ]]; then
            printf '%s' "$base_format"
            return 0
        fi
        sleep 0.1
    done
    return 1
}

create_overlay() {
    local format="$1" golden="$2" overlay="$3"
    for _ in {1..20}; do
        if qemu-img create -q -f qcow2 -F "$format" -b "$golden" "$overlay" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

BASE_FORMAT="$(golden_format "$GOLDEN")" || die "could not determine golden image format"
create_overlay "$BASE_FORMAT" "$GOLDEN" "$OVERLAY" \
    || die "could not create the disposable qcow2 overlay"
cp -- "$OVMF_VARS" "$VARS"

printf 'omabackup-vm: booting %s with artifact %s\n' "$GOLDEN" "$ARTIFACT"
qemu-system-x86_64 \
    -name omabackup-restore-test \
    -machine q35,accel=kvm \
    -cpu host \
    -m "$MEMORY" \
    -smp "$CPUS" \
    -nodefaults \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$VARS" \
    -drive "if=virtio,format=qcow2,file=$OVERLAY" \
    -device virtio-gpu-pci \
    -device virtio-keyboard-pci \
    -device virtio-mouse-pci \
    -nic "user,model=virtio-net-pci,hostfwd=tcp:$SSH_HOST:$SSH_PORT-:22" \
    -display none \
    -serial "file:$SERIAL" \
    -qmp "unix:$QMP,server=on,wait=off" \
    -no-reboot \
    >"$QEMU_LOG" 2>&1 &
QEMU_PID=$!

RUN_DEADLINE=$((SECONDS + TIMEOUT_SEC))
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
    -o ConnectTimeout=2 -o ConnectionAttempts=1 -o ServerAliveInterval=5 \
    -o ServerAliveCountMax=2 -i "$SSH_KEY" -p "$SSH_PORT")
SCP_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
    -o ConnectTimeout=2 -o ConnectionAttempts=1 -o ServerAliveInterval=5 \
    -o ServerAliveCountMax=2 -i "$SSH_KEY" -P "$SSH_PORT")
remaining_timeout() {
    local remaining=$((RUN_DEADLINE - SECONDS))
    (( remaining > 0 )) || return 1
    printf '%s' "$remaining"
}
qemu_alive() { [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; }
guest() {
    local remaining
    qemu_alive || return 125
    remaining="$(remaining_timeout)" || return 124
    timeout --foreground --kill-after=5s "${remaining}s" \
        ssh "${SSH_OPTS[@]}" "$GUEST_USER@$SSH_HOST" "$@"
}
guest_cmd() {
    local joined
    printf -v joined '%q ' "$@"
    guest "$joined"
}
guest_script() {
    local joined='bash -s --' arg
    for arg in "$@"; do
        printf -v joined '%s %q' "$joined" "$arg"
    done
    guest "$joined"
}
scp_guest() {
    local remaining
    qemu_alive || return 125
    remaining="$(remaining_timeout)" || return 124
    timeout --foreground --kill-after=5s "${remaining}s" \
        scp "${SCP_OPTS[@]}" "$@"
}

wait_for_guest() {
    while (( SECONDS < RUN_DEADLINE )); do
        if ! qemu_alive; then
            printf 'omabackup-vm: QEMU exited before SSH became ready\n' >&2
            return 1
        fi
        if guest true >/dev/null 2>&1; then return 0; fi
        sleep 2
    done
    printf 'omabackup-vm: timed out waiting for SSH\n' >&2
    return 1
}

wait_for_guest
printf 'omabackup-vm: SSH ready\n'

scp_guest "$ARTIFACT" "$GUEST_USER@$SSH_HOST:$GUEST_ARTIFACT" >/dev/null
tar -C "$REPO_ROOT" -cf "$HOST_TOOL" bin lib groups.default.json secrets.deny.json manifest.json
scp_guest "$HOST_TOOL" "$GUEST_USER@$SSH_HOST:$GUEST_TOOL" >/dev/null

guest_cmd sudo mkdir -p /opt/omabackup
guest_cmd sudo tar -xf "$GUEST_TOOL" -C /opt/omabackup
guest_cmd sudo chmod -R a+rX /opt/omabackup

RESTORE_ENV=(env "HOME=$GUEST_HOME" "OMABACKUP_ROOT=/opt/omabackup" \
    "OMABACKUP_STATE=$GUEST_HOME/.local/state/omabackup")

printf 'omabackup-vm: calculating restore plan\n'
guest_cmd "${RESTORE_ENV[@]}" /opt/omabackup/bin/omabackup restore --json "$GUEST_ARTIFACT" >"$PLAN_JSON"
RESTORE_COUNT="$(jq -er '
    if (.schemaVersion == 1
        and (.counts.restore | type == "number")
        and ((.rows | map(select(.action == "restore")) | length) == .counts.restore)
        and (.counts.quarantine == 0)
        and (.counts.ambiguous == 0)
        and (.counts.held == 0))
    then .counts.restore
    else error("invalid restore plan")
    end
' "$PLAN_JSON")" || die "guest produced an invalid restore plan"
if ! ESCAPE_REPOS="$(jq -r '[.rows[] | select(.action == "escape") | .repo] | .[]?' "$PLAN_JSON")"; then
    die "could not inspect restore plan escapes"
fi
EXPECTED_ESCAPE_REPO="${OMABACKUP_VM_EXPECTED_ESCAPE_REPO-state/omarchy/current/background}"
if [[ -n "$EXPECTED_ESCAPE_REPO" ]]; then
    [[ "$ESCAPE_REPOS" == "$EXPECTED_ESCAPE_REPO" ]] \
        || die "restore plan escapes differ from the expected path: ${ESCAPE_REPOS:-<none>}"
else
    [[ -z "$ESCAPE_REPOS" ]] \
        || die "restore plan contains escapes under a zero-escape policy: $ESCAPE_REPOS"
fi
ESCAPE_COUNT=0
[[ -z "$ESCAPE_REPOS" ]] || ESCAPE_COUNT="$(printf '%s\n' "$ESCAPE_REPOS" | wc -l)"

jq -e '[.rows[] | select(.action == "restore") | {repo, dest}]' "$PLAN_JSON" >"$HOST_ROWS" \
    || die "could not serialize restore rows"

scp_guest "$HOST_ROWS" "$GUEST_USER@$SSH_HOST:$GUEST_ROWS" >/dev/null

printf 'omabackup-vm: applying restore\n'
apply_rc=0
guest_cmd "${RESTORE_ENV[@]}" /opt/omabackup/bin/omabackup restore --apply "$GUEST_ARTIFACT" \
    >"$APPLY_LOG" 2>&1 || apply_rc=$?
if (( ESCAPE_COUNT == 0 )); then
    (( apply_rc == 0 )) || die "guest restore failed (exit $apply_rc)"
else
    (( apply_rc != 0 )) || die "guest restore unexpectedly succeeded despite an escaped path"
fi

JOURNAL="$GUEST_HOME/.local/state/omabackup/restore-last.json"
JOURNAL_JSON="$(guest_cmd cat "$JOURNAL")" \
    || die "guest restore journal was not written"
printf '%s' "$JOURNAL_JSON" | jq -e --argjson expected "$RESTORE_COUNT" --argjson escaped "$ESCAPE_COUNT" '
    .restored == $expected
    and .failed == 0
    and .quarantined == 0
    and .quarantineFailed == 0
    and .ambiguous == 0
    and .escaped == $escaped
' >/dev/null || die "guest restore journal did not match the validated plan"
for required_dest in "$GUEST_HOME/.config/omarchy/shell.json" "$GUEST_HOME/.config/hypr/hyprland.lua"; do
    jq -e --arg dest "$required_dest" 'any(.rows[]; .action == "restore" and .dest == $dest)' "$PLAN_JSON" >/dev/null \
        || die "restore plan did not include required destination: $required_dest"
    guest_cmd test -s "$required_dest" \
        || die "required restored file is missing or empty: $required_dest"
done

guest_script "$GUEST_ARTIFACT" "$GUEST_ROWS" <<'REMOTE'
set -euo pipefail
artifact="$1"
rows="$2"
archive_dir="$(mktemp -d /tmp/omabackup-archive.XXXXXX)"
trap 'rm -rf -- "$archive_dir"' EXIT
zstd -dc -- "$artifact" | tar -xf - -C "$archive_dir" ./worktree
items="$(jq -cer '.[]' "$rows")"
while IFS= read -r item; do
    repo="$(jq -er '.repo' <<<"$item")"
    dest="$(jq -er '.dest' <<<"$item")"
    archive_member="$archive_dir/worktree/$repo"
    if [[ -L "$archive_member" ]]; then
            [[ -L "$dest" ]] || {
                printf 'expected symlink is not a symlink: %s -> %s\n' "$repo" "$dest" >&2
                exit 1
            }
            expected_link="$(readlink -- "$archive_member")"
            actual_link="$(readlink -- "$dest")"
            [[ "$expected_link" == "$actual_link" ]] || {
                printf 'symlink target mismatch: %s -> %s\n' "$repo" "$dest" >&2
                exit 1
            }
    elif [[ -f "$archive_member" && ! -L "$archive_member" ]]; then
            [[ -f "$dest" && ! -L "$dest" ]] || {
                printf 'expected regular file is missing or is a symlink: %s -> %s\n' "$repo" "$dest" >&2
                exit 1
            }
            expected_mode="$(stat -c '%A' -- "$archive_member")"
            actual_mode="$(stat -c '%A' -- "$dest")"
            [[ "$expected_mode" == "$actual_mode" ]] || {
                printf 'mode mismatch: %s -> %s (%s != %s)\n' "$repo" "$dest" "$expected_mode" "$actual_mode" >&2
                exit 1
            }
            expected="$(sha256sum -- "$archive_member" | awk '{print $1}')"
            actual="$(sha256sum -- "$dest" | awk '{print $1}')"
            [[ "$expected" == "$actual" ]] || {
                printf 'content mismatch: %s -> %s\n' "$repo" "$dest" >&2
                exit 1
            }
    else
        printf 'unsupported restored archive member type: %s\n' "$repo" >&2
        exit 1
    fi
done <<<"$items"
REMOTE

# A fresh SDDM session makes the graphical assertion meaningful instead of
# checking the session that booted before the restore happened.
guest_cmd sudo systemctl restart sddm
graphical_session_ready() {
    guest_script "$GUEST_USER" <<'REMOTE'
set -euo pipefail
user="$1"
[[ "$(loginctl show-user "$user" -p State --value)" == "active" ]]
uid="$(id -u "$user")"
runtime="/run/user/$uid"
[[ -d "$runtime" ]]
wayland_display="$(find "$runtime" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' | head -n 1)"
instance_signature="$(find "$runtime/hypr" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | head -n 1)"
[[ -n "$wayland_display" && -n "$instance_signature" ]]
export XDG_RUNTIME_DIR="$runtime"
export WAYLAND_DISPLAY="$wayland_display"
export HYPRLAND_INSTANCE_SIGNATURE="$instance_signature"
hyprctl monitors -j | jq -e 'type == "array" and length > 0' >/dev/null
hyprctl layers -j | jq -e '[.. | objects | select(.namespace? == "omarchy-bar")] | length > 0' >/dev/null
REMOTE
}
while (( SECONDS < RUN_DEADLINE )); do
    if guest_cmd pgrep -u "$GUEST_USER" -x quickshell >/dev/null 2>&1 \
       && guest_cmd pgrep -u "$GUEST_USER" -x Hyprland >/dev/null 2>&1 \
       && graphical_session_ready >/dev/null 2>&1; then
        break
    fi
    sleep 2
done
guest_cmd pgrep -u "$GUEST_USER" -x quickshell >/dev/null 2>&1 \
    || die "QuickShell did not become active after restore"
guest_cmd pgrep -u "$GUEST_USER" -x Hyprland >/dev/null 2>&1 \
    || die "Hyprland did not become active after restore"
graphical_session_ready \
    || die "Hyprland session did not expose a live Wayland compositor"

capture_qmp "$RUN_DIR/screenshot.ppm" || die "QMP screenshot failed"
mkdir -p "$RESULTS_DIR"
SUCCESS_SCREENSHOT="$RESULTS_DIR/restore-$(date -u +%Y%m%dT%H%M%SZ).ppm"
cp -- "$RUN_DIR/screenshot.ppm" "$SUCCESS_SCREENSHOT"
printf 'omabackup-vm: screenshot evidence: %s\n' "$SUCCESS_SCREENSHOT"
printf 'omabackup-vm: PASS (restore, Omarchy state, QuickShell, Hyprland)\n'

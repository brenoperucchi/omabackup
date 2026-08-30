# Contract probes for the VM runner. The actual boot is intentionally opt-in:
# the main suite must stay fast and must not require a golden disk image.

OB="$PWD/test/vm/run.sh"
SOURCE="$(<"$OB")"
BUILDER="$PWD/test/vm/build-golden.sh"
BUILDER_SOURCE="$(<"$BUILDER")"

it "the VM runner is executable and parses as Bash"
[[ -x "$OB" ]] && bash -n "$OB" && ok || fail "VM runner is not executable or has a syntax error"

it "the golden builder is executable, parses, and stays opt-in"
if [[ -x "$BUILDER" ]] && bash -n "$BUILDER" \
   && "$BUILDER" --help >/dev/null 2>&1 \
   && [[ "$BUILDER_SOURCE" == *'refusing to overwrite existing golden disk'* ]]; then
    ok
else
    fail "golden builder is missing its safe opt-in contract"
fi

it "the VM runner documents its real-guest contract"
HELP="$($OB --help 2>&1)"
assert_contains "$HELP" "QEMU/KVM"
assert_contains "$HELP" "golden image"

FORMAT_SOURCE="$(sed -n '/^golden_format()/,/^}/p' "$OB")"
OVERLAY_SOURCE="$(sed -n '/^create_overlay()/,/^}/p' "$OB")"
RETRY_HOME="$(mktemp -d)"
printf '0\n' >"$RETRY_HOME/count"
cat >"$RETRY_HOME/qemu-img" <<'FAKE'
#!/bin/bash
count="$(cat "$FAKE_QEMU_COUNT")"
count=$((count + 1))
printf '%s\n' "$count" >"$FAKE_QEMU_COUNT"
if (( count < 3 )); then exit 1; fi
printf '{"format":"qcow2"}\n'
FAKE
chmod +x "$RETRY_HOME/qemu-img"
RETRY_FORMAT="$(FAKE_QEMU_COUNT="$RETRY_HOME/count" PATH="$RETRY_HOME:$PATH" \
    bash -c "$FORMAT_SOURCE; golden_format \"\$1\"" _ "$RETRY_HOME/golden.qcow2")"

it "retries transient qemu image format discovery before succeeding"
assert_eq "$RETRY_FORMAT" "qcow2"
assert_eq "$(cat "$RETRY_HOME/count")" "3"

printf '0\n' >"$RETRY_HOME/count"
cat >"$RETRY_HOME/qemu-img" <<'FAKE'
#!/bin/bash
count="$(cat "$FAKE_QEMU_COUNT")"
count=$((count + 1))
printf '%s\n' "$count" >"$FAKE_QEMU_COUNT"
exit 1
FAKE
chmod +x "$RETRY_HOME/qemu-img"
RETRY_FAIL_RC=0
FAKE_QEMU_COUNT="$RETRY_HOME/count" PATH="$RETRY_HOME:$PATH" \
    bash -c "$FORMAT_SOURCE; golden_format \"\$1\"" _ "$RETRY_HOME/golden.qcow2" \
    >/dev/null 2>&1 || RETRY_FAIL_RC=$?

it "stops after the bounded qemu image retry budget"
assert_eq "$RETRY_FAIL_RC" "1"
assert_eq "$(cat "$RETRY_HOME/count")" "20"

GOLDEN_PATH_SOURCE="$(sed -n '/^canonical_golden()/,/^}/p' "$OB")"
RELATIVE_GOLDEN_HOME="$(mktemp -d)"
touch "$RELATIVE_GOLDEN_HOME/golden.qcow2"
RELATIVE_GOLDEN="$(cd "$RELATIVE_GOLDEN_HOME" && bash -c \
    "$GOLDEN_PATH_SOURCE; canonical_golden \"\$1\"" _ golden.qcow2 2>/dev/null || true)"

it "canonicalizes a relative golden before it becomes an overlay backing file"
assert_contains "$SOURCE" 'GOLDEN="$(canonical_golden "$GOLDEN")"'
assert_eq "$RELATIVE_GOLDEN" "$(realpath "$RELATIVE_GOLDEN_HOME/golden.qcow2")"

printf '0\n' >"$RETRY_HOME/count"
cat >"$RETRY_HOME/qemu-img" <<'FAKE'
#!/bin/bash
count="$(cat "$FAKE_QEMU_COUNT")"
count=$((count + 1))
printf '%s\n' "$count" >"$FAKE_QEMU_COUNT"
if (( count < 3 )); then exit 1; fi
exit 0
FAKE
chmod +x "$RETRY_HOME/qemu-img"
RETRY_OVERLAY_RC=0
FAKE_QEMU_COUNT="$RETRY_HOME/count" PATH="$RETRY_HOME:$PATH" \
    bash -c "$OVERLAY_SOURCE; create_overlay \"\$1\" \"\$2\" \"\$3\"" _ \
    qcow2 "$RETRY_HOME/golden.qcow2" "$RETRY_HOME/overlay.qcow2" \
    >/dev/null 2>&1 || RETRY_OVERLAY_RC=$?

it "retries transient qcow2 overlay creation before succeeding"
assert_eq "$RETRY_OVERLAY_RC" "0"
assert_eq "$(cat "$RETRY_HOME/count")" "3"

VH="$(mktemp -d)"
mkdir -p "$VH/vm"
touch "$VH/vm/id_ed25519" "$VH/vm/id_ed25519.pub" "$VH/vm/known_hosts"
VMOUT="$(HOME="$VH" OMABACKUP_VM_ROOT="$VH/vm" "$OB" \
    --golden "$VH/vm/missing.qcow2" --artifact "$VH/missing.tar.zst" 2>&1)"
VMRC=$?

it "a missing golden image fails before any QEMU or transfer work"
[[ $VMRC -ne 0 ]] && ok || fail "missing golden image unexpectedly passed"
assert_contains "$VMOUT" "golden image not found"

it "the runner leaves no global host tool archive behind on preflight failure"
[[ ! -e /tmp/omabackup-tool.tar ]] && ok || fail "global temporary tool archive exists"

it "pins both SSH and SCP to the supplied host key and forwarding port"
if [[ "$SOURCE" == *'StrictHostKeyChecking=yes'* \
      && "$SOURCE" == *'UserKnownHostsFile="$KNOWN_HOSTS"'* \
      && "$SOURCE" == *' -p "$SSH_PORT")'* \
      && "$SOURCE" == *' -P "$SSH_PORT")'* \
      && "$SOURCE" != *'StrictHostKeyChecking=no'* ]]; then
    ok
else
    fail "runner does not keep SSH and SCP host verification/port handling aligned"
fi

it "uses one absolute deadline for guest calls and graphical readiness"
if [[ "$SOURCE" == *'RUN_DEADLINE=$((SECONDS + TIMEOUT_SEC))'* \
      && "$SOURCE" == *'while (( SECONDS < RUN_DEADLINE ))'* \
      && "$SOURCE" == *'timeout --foreground --kill-after=5s'* ]]; then
    ok
else
    fail "runner is missing its absolute timeout contract"
fi

it "validates archive member type before hashing restored content"
if [[ "$SOURCE" == *'zstd -dc -- "$artifact" | tar -xf - -C "$archive_dir" ./worktree'* \
      && "$SOURCE" == *'archive_member="$archive_dir/worktree/$repo"'* \
      && "$SOURCE" == *'expected_link="$(readlink -- "$archive_member")"'* \
      && "$SOURCE" == *'[[ -f "$dest" && ! -L "$dest" ]]'* \
      && "$SOURCE" == *'expected_mode="$(stat -c '\''%A'\'' -- "$archive_member")"'* ]]; then
    ok
else
    fail "runner does not verify archive type, mode, and content"
fi

it "checks a live user Wayland compositor after SDDM restart"
if [[ "$SOURCE" == *'loginctl show-user "$user" -p State --value'* \
      && "$SOURCE" == *'hyprctl monitors -j'* \
      && "$SOURCE" == *'namespace? == "omarchy-bar"'* ]]; then
    ok
else
    fail "runner only checks process names, not the graphical session"
fi

it "distinguishes an explicitly empty expected-escape policy from its default"
if [[ "$SOURCE" == *'OMABACKUP_VM_EXPECTED_ESCAPE_REPO-state/omarchy/current/background'* \
      && "$SOURCE" == *'[[ "$ESCAPE_REPOS" == "$EXPECTED_ESCAPE_REPO" ]]'* \
      && "$SOURCE" == *'restore plan contains escapes under a zero-escape policy'* ]]; then
    ok
else
    fail "empty expected-escape policy still falls back to the known escape"
fi

it "makes golden readiness and cold-boot shutdown failures fatal"
if [[ "$BUILDER_SOURCE" == *'could not enable sshd and sddm in the golden guest'* \
      && "$BUILDER_SOURCE" != *'sudo systemctl enable sshd sddm >/dev/null 2>&1 || true'* \
      && "$BUILDER_SOURCE" == *'validating a cold boot of the golden image'* \
      && "$BUILDER_SOURCE" == *'cp -- "$OVMF_VARS" "$RUN_DIR/cold-OVMF_VARS.fd"'* \
      && "$BUILDER_SOURCE" == *'golden guest did not expose SSH after cold boot'* \
      && "$BUILDER_SOURCE" == *'golden guest did not shut down cleanly after cold boot'* \
      && "$BUILDER_SOURCE" == *'mv -- "$PROVISION_KNOWN_HOSTS" "$KNOWN_HOSTS"'* ]]; then
    ok
else
    fail "golden builder does not verify service enablement and a cold boot"
fi

it "rejects an empty or uniform successful QMP screenshot"
if [[ "$SOURCE" == *'screenshot is visually empty'* \
      && "$SOURCE" == *'len(sample) < 4'* \
      && "$SOURCE" == *'SUCCESS_SCREENSHOT="$RESULTS_DIR/restore-'* ]]; then
    ok
else
    fail "successful QMP evidence is not semantically validated and preserved"
fi

it "captures QMP evidence while QEMU is still running and keeps tool files scoped"
if [[ "$SOURCE" == *'capture_qmp "$failure_dir/screenshot.ppm"'* \
      && "$SOURCE" == *'qmp_quit'* \
      && "$SOURCE" == *'HOST_TOOL="$RUN_DIR/omabackup-tool.tar"'* \
      && "$SOURCE" != *'HOST_TOOL="/tmp/omabackup-tool.tar"'* ]]; then
    ok
else
    fail "runner cleanup/evidence paths are not scoped to the disposable run"
fi

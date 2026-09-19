# What this tool requires of a machine, and how it behaves when something is
# missing.
#
# The audit that produced these specs: `jq` and `git` are direct dependencies of
# the `omarchy` package itself, so they are guaranteed anywhere this plugin can
# even be installed. coreutils, findutils, sed, gawk, tar and systemd come from
# Arch `base`. But `rsync` and `zstd` are neither -- no omarchy script uses
# either one -- and `hostname` comes from `inetutils`, which on this machine is
# "Explicitly installed / Required By: None", meaning it is present only because
# somebody installed it by hand.
#
# So a clean Omarchy install can genuinely lack three things this tool used, and
# two of them are not optional. That is an adoption impediment, and silence
# about it is worse than the missing package.

OB="$PWD/bin/omabackup"
# `test/run.sh` executes this spec from a disposable checkout whose entry
# points deliberately retain fixture PATH shims. These assertions must run the
# shipped executable, not that test build, so a fake command cannot hide a
# production bypass.
PROD_ROOT="${OMABACKUP_PRODUCTION_ROOT:-$PWD}"
PROD_OB="$PROD_ROOT/bin/omabackup"

# A PATH containing exactly the named tools and nothing else, so "missing" is a
# fact rather than a simulation.
#
# `type -P`, not `command -v`: test/run.sh overrides mktemp as a shell
# function (a safety net, unrelated to this file -- see its own comment), and
# `command -v` reports a shadowing function by NAME, not by path, for
# whichever tool it happens to be defined for. Handed that bare name, `ln -sf`
# below made a symlink pointing at a relative, nonexistent target instead of
# the real binary -- silently, since ln -sf does not care whether what it
# links to exists. `type -P` does a real PATH search and ignores functions
# entirely, which is the question this helper is actually asking: where does
# this tool live on disk, not what does this shell currently call it.
_only_path() {  # _only_path <dir> <tool...>
    local d="$1"; shift
    mkdir -p "$d"
    local t p
    for t in "$@"; do
        p="$(type -P "$t" 2>/dev/null)" && ln -sf "$p" "$d/$t"
    done
}

# ── inherited PATH cannot select a tool ─────────────────────────────────────
# The graphical user systemd manager on this machine inherited user-writable
# mise/bun/rbenv directories before /usr/bin. A program planted there was the
# command `require_tools` and the later operation both ran. This test leaves a
# fake git at the front of the inherited PATH and also supplies the obsolete
# seam name: bundle must complete with the real git and the fake must never
# execute. This proves no environment value can opt out of production policy.
PATHH="$(mktemp -d)"; PATHBIN="$PATHH/bin"; PATHREPO="$PATHH/repo"
mkdir -p "$PATHBIN" "$PATHREPO/configs/app" "$PATHH/home/.config/app"
git init -q "$PATHREPO"; git -C "$PATHREPO" config user.email t@t; git -C "$PATHREPO" config user.name t
printf 'repo\n' >"$PATHREPO/configs/app/f.txt"
git -C "$PATHREPO" add -A && git -C "$PATHREPO" commit -qm one
printf 'live\n' >"$PATHH/home/.config/app/f.txt"
cat >"$PATHH/groups.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/app"]}]}
JSON
cat >"$PATHBIN/git" <<'SH'
#!/bin/bash
printf 'fake git ran\n' >>"$OMABACKUP_PATH_PROBE"
exec /usr/bin/git "$@"
SH
chmod +x "$PATHBIN/git"
PATHPROBE="$PATHH/fake-git-ran"
PATHOUT="$(env OMABACKUP_TEST_ALLOW_INHERITED_PATH=1 \
    PATH="$PATHBIN:$PATH" OMABACKUP_PATH_PROBE="$PATHPROBE" HOME="$PATHH/home" \
    OMABACKUP_GROUPS="$PATHH/groups.json" OMABACKUP_STATE="$PATHH/state" \
    OMABACKUP_REPO="$PATHREPO" XDG_RUNTIME_DIR=/nonexistent \
    "$PROD_OB" bundle 2>&1)"
PATHRC=$?

it "bundle ignores a fake git and the obsolete test seam on inherited PATH"
[[ ! -e "$PATHPROBE" ]] && ok || fail "the inherited-PATH git executed"

it "and still resolves the real git from its fixed system PATH"
[[ $PATHRC -eq 0 ]] && ok || fail "bundle failed after rejecting the inherited PATH: $PATHOUT"

FUNCPROBE="$PATHH/imported-function-ran"
FUNCOUT="$(env 'BASH_FUNC_git%%=() { printf imported-function-ran >>"$OMABACKUP_PATH_PROBE"; }' \
    OMABACKUP_PATH_PROBE="$FUNCPROBE" HOME="$PATHH/home" \
    OMABACKUP_GROUPS="$PATHH/groups.json" OMABACKUP_STATE="$PATHH/state-function" \
    OMABACKUP_REPO="$PATHREPO" XDG_RUNTIME_DIR=/nonexistent \
    "$PROD_OB" bundle 2>&1)"
FUNCRC=$?

it "the production shebang rejects an imported git function before tool lookup"
[[ ! -e "$FUNCPROBE" && $FUNCRC -eq 0 ]] && ok || fail "the imported function ran or bundle failed: $FUNCOUT"

# A shell cannot export a malformed environment name, but execve can. The
# startup scrub must reject one rather than handing it to `env`, where the
# first entry without NAME=VALUE syntax becomes a command to execute.
MALENVOUT="$(PROD_OB="$PROD_OB" /usr/bin/python3 - 2>&1 <<'PY'
import ctypes
import os

program = os.environ['PROD_OB'].encode()
argv = (ctypes.c_char_p * 5)(program, b'not-a-cli', b'config', b'token', None)
envp = (ctypes.c_char_p * 5)(
    b'BASH_ENV=/dev/null',
    b'/usr/bin/printf',
    b'PATH=/usr/bin:/bin',
    b'HOME=/tmp',
    None,
)
ctypes.CDLL(None).execve(program, argv, envp)
raise OSError(ctypes.get_errno(), 'execve')
PY
)"
MALENVRC=$?

it "a malformed inherited environment is refused before env can execute it"
[[ $MALENVRC -eq 126 && "$MALENVOUT" == *"invalid inherited environment entry"* ]] \
    && ok || fail "the malformed entry reached env instead: rc=$MALENVRC output=$MALENVOUT"

_unit_is_self_contained() {  # _unit_is_self_contained <unit>
    ! grep -q '^EnvironmentFile=' "$1" \
        && [[ "$(grep -cx 'Environment=PATH=/usr/bin:/bin' "$1")" == 1 ]]
}

it "entry points use privileged Bash and services do not import arbitrary env"
if grep -q '^#!/usr/bin/bash -p$' "$PROD_OB" \
   && grep -q '^#!/usr/bin/bash -p$' "$PROD_ROOT/bin/omabackup-tui" \
   && grep -q '^PATH="$OMABACKUP_SYSTEM_PATH"$' "$PROD_OB" \
   && grep -q '^PATH="$OMABACKUP_SYSTEM_PATH"$' "$PROD_ROOT/bin/omabackup-tui" \
   && _unit_is_self_contained "$PROD_ROOT/systemd/omabackup-sync.service" \
   && _unit_is_self_contained "$PROD_ROOT/systemd/omabackup-push.service"; then
    ok
else
    fail "a user service can still import an arbitrary environment file"
fi

it "the disposable test build verifies both production PATH pins before patching"
if grep -q '_unpin_test_copy' "$PROD_ROOT/test/run.sh" \
   && grep -q 'expected exactly one production PATH assignment' "$PROD_ROOT/test/run.sh"; then
    ok
else
    fail "the test-copy patch can silently become a no-op"
fi

# The TUI's own privileged shebang is insufficient if its launcher gives
# BASH_ENV back to a non-privileged child shell. The fake CLI must run, but the
# startup file must never be sourced by the wrapper, its launcher, or an IPC
# helper it starts after the CLI returns.
TUIH="$(mktemp -d)"; TUI_PROBE="$TUIH/probe"; TUI_CLI="$TUIH/cli"; TUI_ENV="$TUIH/bash-env"
cat >"$TUI_CLI" <<'SH'
#!/bin/bash
[[ "$1" == config ]] && printf 'cli-ran\n' >>"$OMABACKUP_TUI_PROBE"
SH
cat >"$TUI_ENV" <<'SH'
printf 'bash-env-ran\n' >>"$OMABACKUP_TUI_PROBE"
SH
chmod +x "$TUI_CLI"
TUIOUT="$(env BASH_ENV="$TUI_ENV" OMABACKUP_TUI_PROBE="$TUI_PROBE" \
    OMABACKUP_LOG_SKIP=1 XDG_RUNTIME_DIR=/nonexistent \
    "$PROD_ROOT/bin/omabackup-tui" "$TUI_CLI" config token 2>&1)"
TUIRC=$?

it "the TUI strips BASH_ENV before launching its CLI and helpers"
if [[ $TUIRC -eq 0 && "$(cat "$TUI_PROBE" 2>/dev/null)" == 'cli-ran' ]]; then
    ok
else
    fail "the TUI launched a child with BASH_ENV: $TUIOUT"
fi

# Everything the tool legitimately expects, minus hostname. `timeout` is a
# genuinely new addition (round omabackup-27, marketplace security review):
# _zstd_extract now wraps its whole extraction pipeline in it, a wall-clock
# ceiling independent of the byte/member/depth ceilings that only bound
# WHAT gets written, not HOW LONG getting there can take. Part of the same
# GNU coreutils package as head/tail/mv/cp/chmod already in this list, so
# it costs nothing new to actually depend on.
DEPS_CORE=(bash jq git rsync sed awk gawk find sort uniq grep cut wc tr head tail
           basename dirname mkdir mktemp rm mv cp cat chmod ln readlink stat du
           date uname sha256sum xargs diff tar zstd env sleep touch printf test
           timeout)

# ── hostname is not a dependency ─────────────────────────────────────────────
# It was, in the bundle's filename and in the retention pattern that decides
# what gets deleted. A missing `hostname` would have produced bundles named
# `omabackup--<stamp>` and a prune regex that matched nothing -- or, worse,
# matched differently than the names being written.
XH="$(mktemp -d)"; XBIN="$XH/bin"
_only_path "$XBIN" "${DEPS_CORE[@]}"
XR="$XH/repo"; mkdir -p "$XR/configs/app"
git init -q "$XR"; git -C "$XR" config user.email t@t; git -C "$XR" config user.name t
printf 'x\n' >"$XR/configs/app/f.txt"
git -C "$XR" add -A && git -C "$XR" commit -qm one

it "hostname is genuinely absent from the test PATH"
PATH="$XBIN" command -v hostname >/dev/null 2>&1 && fail "the fixture still has hostname" || ok

XOUT="$(PATH="$XBIN" HOME="$XH" OMABACKUP_ROOT="$PWD" \
    OMABACKUP_GROUPS="$PWD/groups.default.json" OMABACKUP_STATE="$XH/.state" \
    OMABACKUP_REPO="$XR" XDG_RUNTIME_DIR=/nonexistent \
    "$OB" bundle --json 2>&1)"

it "bundle still builds with no hostname binary on the system"
[[ -n "$(printf '%s' "$XOUT" | jq -r '.path // empty' 2>/dev/null)" ]] \
    && ok || fail "bundle failed without hostname: $(printf '%s' "$XOUT" | head -c 200)"

it "and the machine name still lands in the published name"
assert_contains "$(printf '%s' "$XOUT" | jq -r '.publishName' 2>/dev/null)" "$(uname -n)"

it "so the retention pattern and the filename agree on the same host"
assert_contains "$(printf '%s' "$XOUT" | jq -r '.publishName' 2>/dev/null)" "omabackup-$(uname -n)-"

# ── a genuinely missing tool is named, not stumbled over ─────────────────────
# rsync is what collect copies with: without it the tool cannot work at all, and
# it is not pulled in by omarchy or by base. Failing early with the package name
# is the difference between a two-second fix and a confusing afternoon.
YH="$(mktemp -d)"; YBIN="$YH/bin"
_only_path "$YBIN" bash jq git sed awk gawk find sort grep cut wc tr head tail mktemp \
    basename dirname mkdir rm mv cp cat chmod ln readlink stat du date uname \
    sha256sum xargs diff tar env printf test
mkdir -p "$YH/.config/app"; printf 'x\n' >"$YH/.config/app/f.txt"
cat >"$YH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/app"]}]}
JSON
YOUT="$(PATH="$YBIN" HOME="$YH" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$YH/g.json" \
    OMABACKUP_STATE="$YH/.state" XDG_RUNTIME_DIR=/nonexistent \
    "$OB" collect 2>&1)"
YRC=$?

it "collect without rsync fails instead of half-working"
[[ $YRC -ne 0 ]] && ok || fail "collect exited 0 with no rsync installed"

it "and names the missing tool"
assert_contains "$YOUT" "rsync"

it "and names the package that provides it, not just the binary"
assert_contains "$YOUT" "pacman -S"

it "an incomplete collect leaves no half-built staging behind"
[[ ! -d "$YH/.state/staging" ]] && ok || fail "staging was created before the dependency check"

# ── the check is scoped to what each command actually needs ──────────────────
# zstd and tar only matter for `bundle` and `push`. Refusing to run `verify`
# because the machine cannot compress an archive would be its own kind of
# nonsense -- verify is the command that has to work everywhere, including on a
# recovery tty.
ZH="$(mktemp -d)"; ZBIN="$ZH/bin"
_only_path "$ZBIN" bash jq git rsync sed awk gawk find sort grep cut wc tr head tail mktemp \
    basename dirname mkdir rm mv cp cat chmod ln readlink stat du date uname \
    sha256sum xargs diff env printf test
mkdir -p "$ZH/.config/app"; printf 'x\n' >"$ZH/.config/app/f.txt"
cp "$YH/g.json" "$ZH/g.json"

it "zstd is genuinely absent from this fixture"
PATH="$ZBIN" command -v zstd >/dev/null 2>&1 && fail "the fixture still has zstd" || ok

PATH="$ZBIN" HOME="$ZH" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$ZH/g.json" \
    OMABACKUP_STATE="$ZH/.state" XDG_RUNTIME_DIR=/nonexistent \
    "$OB" verify >/dev/null 2>&1
ZRC=$?

it "verify still runs on a machine with no zstd and no tar"
[[ $ZRC -eq 0 ]] && ok || fail "verify refused to run over a bundle-only dependency (exit $ZRC)"

it "collect too -- copying files needs no archiver"
PATH="$ZBIN" HOME="$ZH" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$ZH/g.json" \
    OMABACKUP_STATE="$ZH/.state2" XDG_RUNTIME_DIR=/nonexistent \
    "$OB" collect >/dev/null 2>&1
[[ $? -eq 0 ]] && ok || fail "collect refused to run over a bundle-only dependency"

ZR="$ZH/repo"; mkdir -p "$ZR"; git init -q "$ZR"
git -C "$ZR" config user.email t@t; git -C "$ZR" config user.name t
printf 'x\n' >"$ZR/f.txt"; git -C "$ZR" add -A; git -C "$ZR" commit -qm one
ZOUT="$(PATH="$ZBIN" HOME="$ZH" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$ZH/g.json" \
    OMABACKUP_STATE="$ZH/.state" OMABACKUP_REPO="$ZR" XDG_RUNTIME_DIR=/nonexistent \
    "$OB" bundle 2>&1)"

it "but bundle says exactly what it needs"
assert_contains "$ZOUT" "zstd"

# ── curl is needed to ask GitHub, and only to ask GitHub ─────────────────────
# `push` asks GitHub whether the remote is publicly readable before anything
# leaves the machine (docs/PLAN.md Phase 1, T89). With no curl that question
# cannot be asked, and "could not ask" must never read as "the answer was no".
#
# Found by review (PR #1): the first version added curl to cmd_push's own
# require_tools line, so a machine with only a NAS or a pendrive destination --
# which never asks GitHub anything -- was refused its backup over a tool it had
# no use for. Same rule as "verify must work on a recovery tty" above: the
# check belongs to the path that needs the tool. Without curl the github
# destination fails on its own, names what is missing, and everything else
# still receives its bundle.
QH="$(mktemp -d)"; QBIN="$QH/bin"
_only_path "$QBIN" bash jq rsync zstd tar timeout python3 sed awk gawk find sort grep cut wc tr head tail mktemp \
    basename dirname mkdir rm mv cp cat chmod ln readlink realpath stat du date uname hostname sleep \
    sha256sum xargs diff env printf test
QREAL_GIT="$(type -P git)"
cat >"$QBIN/git" <<EOF
#!/bin/bash
if [[ " \$* " == *" push origin HEAD "* ]]; then printf 'pushed\n' >>"$QH/git.pushes"; exit 0; fi
exec "$QREAL_GIT" "\$@"
EOF
chmod +x "$QBIN/git"
QR="$QH/repo"; mkdir -p "$QR"; "$QREAL_GIT" init -q "$QR"
"$QREAL_GIT" -C "$QR" config user.email t@t; "$QREAL_GIT" -C "$QR" config user.name t
printf 'x\n' >"$QR/f.txt"; "$QREAL_GIT" -C "$QR" add -A; "$QREAL_GIT" -C "$QR" commit -qm one
"$QREAL_GIT" -C "$QR" remote add origin 'https://github.com/user/dotfiles.git'
cat >"$QH/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"nas","type":"dir","path":"$QH/nas","keep":2}]}
JSON

it "curl is genuinely absent from this fixture"
PATH="$QBIN" command -v curl >/dev/null 2>&1 && fail "the fixture still has curl" || ok

_q_push() {  # _q_push <state-dir> [push args...]
    local st="$1"; shift
    PATH="$QBIN" HOME="$QH" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$YH/g.json" \
        OMABACKUP_STATE="$st" OMABACKUP_REPO="$QR" OMABACKUP_DESTINATIONS="$QH/destinations.json" \
        XDG_RUNTIME_DIR=/nonexistent "$OB" push "$@" 2>&1
}
QOUT="$(_q_push "$QH/.state")"
QRC=$?

it "without curl the github destination is refused rather than pushed to unchecked"
[[ $QRC -ne 0 && ! -e "$QH/git.pushes" ]] && ok || fail "rc=$QRC pushed=$([[ -e "$QH/git.pushes" ]] && echo yes || echo no)"

it "and the refusal names curl, with the package that provides it"
[[ "$QOUT" == *curl* && "$QOUT" == *"pacman -S curl"* ]] && ok || fail "got: $QOUT"

it "but a dir destination never asks GitHub anything, and still receives its bundle with no curl installed"
[[ -n "$(find "$QH/nas" -name 'omabackup-*' 2>/dev/null)" ]] && ok || fail "the nas destination received nothing: $QOUT"

"$QREAL_GIT" -C "$QR" remote set-url origin "$QH/remote.git"; "$QREAL_GIT" init -q --bare "$QH/remote.git"
rm -f "$QH/git.pushes"
_q_push "$QH/.state2" github >/dev/null
Q2RC=$?

it "and a non-GitHub origin needs no curl at all -- there is nobody to ask"
[[ $Q2RC -eq 0 && -e "$QH/git.pushes" ]] && ok || fail "rc=$Q2RC pushed=$([[ -e "$QH/git.pushes" ]] && echo yes || echo no)"

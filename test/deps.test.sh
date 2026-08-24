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

# A PATH containing exactly the named tools and nothing else, so "missing" is a
# fact rather than a simulation.
_only_path() {  # _only_path <dir> <tool...>
    local d="$1"; shift
    mkdir -p "$d"
    local t p
    for t in "$@"; do
        p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$d/$t"
    done
}

# Everything the tool legitimately expects, minus hostname.
DEPS_CORE=(bash jq git rsync sed awk gawk find sort uniq grep cut wc tr head tail
           basename dirname mkdir mktemp rm mv cp cat chmod ln readlink stat du
           date uname sha256sum xargs diff tar zstd env sleep touch printf test)

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
    bash "$OB" bundle --json 2>&1)"

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
    bash "$OB" collect 2>&1)"
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
    bash "$OB" verify >/dev/null 2>&1
ZRC=$?

it "verify still runs on a machine with no zstd and no tar"
[[ $ZRC -eq 0 ]] && ok || fail "verify refused to run over a bundle-only dependency (exit $ZRC)"

it "collect too -- copying files needs no archiver"
PATH="$ZBIN" HOME="$ZH" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$ZH/g.json" \
    OMABACKUP_STATE="$ZH/.state2" XDG_RUNTIME_DIR=/nonexistent \
    bash "$OB" collect >/dev/null 2>&1
[[ $? -eq 0 ]] && ok || fail "collect refused to run over a bundle-only dependency"

ZR="$ZH/repo"; mkdir -p "$ZR"; git init -q "$ZR"
git -C "$ZR" config user.email t@t; git -C "$ZR" config user.name t
printf 'x\n' >"$ZR/f.txt"; git -C "$ZR" add -A; git -C "$ZR" commit -qm one
ZOUT="$(PATH="$ZBIN" HOME="$ZH" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$ZH/g.json" \
    OMABACKUP_STATE="$ZH/.state" OMABACKUP_REPO="$ZR" XDG_RUNTIME_DIR=/nonexistent \
    bash "$OB" bundle 2>&1)"

it "but bundle says exactly what it needs"
assert_contains "$ZOUT" "zstd"

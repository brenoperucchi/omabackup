#!/bin/bash
# Minimal runner. Usage: ./test/run.sh [pattern]
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Specs never clean up their own `mktemp -d` fixtures -- 216 calls across the
# suite, zero of them removed. Scoped to a throwaway TMPDIR and torn down on
# exit instead of leaking into the shared /tmp forever: a full run left ~20k
# orphaned directories behind, enough to exhaust /tmp's INODE table on a
# tmpfs long before its byte capacity, which stopped the harness itself from
# writing anywhere. A spec that names /tmp directly still escapes this -- a
# handful do -- but the overwhelming majority are ordinary `mktemp -d` calls
# with no opinion about where, and this is where.
TMPDIR="$(mktemp -d)"
export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT

# A failed mktemp inside a spec used to be worse than a failed test: dozens of
# fixtures build a throwaway repo as `r="$(mktemp -d)"` and then run
# `git -C "$r" add -A && git -C "$r" commit -qm base` against it. mktemp
# failing (this suite hit exactly that once, mid-run, when /tmp's inode table
# filled -- the TMPDIR scoping above exists because of it) leaves $r empty on
# a bare `command mktemp` failure path, and `git -C ""` does not refuse an
# empty path -- confirmed directly -- it silently operates on the CURRENT
# directory instead. During a test run that directory is this repository, not
# a fixture: `git -C "$r" commit -qm base` became a real commit against the
# real git identity on `main`, git log shows it as commit 142ffb1. Overriding
# mktemp itself, once, here -- before any spec is sourced, in the same shell
# every spec runs in -- closes the whole class in one place: no spec
# anywhere in the suite can ever again turn a disk-full moment into a write
# against the wrong repository, without auditing the ~250 individual
# `mktemp -d` call sites this would otherwise require.
#
# `exit` alone does not do it: every spec calls this as `r="$(mktemp -d)"`,
# and `$(...)` always forks a subshell -- `exit` inside this function then
# only kills THAT subshell, and the spec's own script keeps running past it
# with $r empty, exactly the bug this exists to close. Confirmed by first
# writing it that way and watching the fake-failure test below still reach
# the git commit. `$$` still names the top-level shell's PID from inside a
# `$(...)` subshell (unlike $BASHPID, which would name the subshell's own),
# so a signal aimed at $$ reaches the process actually running the spec.
mktemp() {
    local out
    out="$(command mktemp "$@")" || {
        printf 'FATAL: mktemp failed (disk or inode exhaustion?) -- refusing to let a spec fall through to an empty path\n' >&2
        kill -s TERM "$$"
        exit 90
    }
    printf '%s' "$out"
}

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; DIM=$'\033[2m'; NC=$'\033[0m'
PASS=0; FAIL=0; CURRENT=""

it()   { CURRENT="$1"; }
ok()   { PASS=$((PASS + 1)); printf "  ${GREEN}✓${NC} %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  ${RED}✗${NC} %s\n    ${DIM}%s${NC}\n" "$CURRENT" "$1"; }

assert_eq() {
    [[ "$1" == "$2" ]] && ok || fail "expected «$2», got «$1»"
}
assert_contains() {
    [[ "$1" == *"$2"* ]] && ok || fail "expected «$2» in: $(printf '%s' "$1" | head -c 200)"
}
assert_not_contains() {
    [[ "$1" != *"$2"* ]] && ok || fail "should not contain «$2»"
}

for spec in test/*.test.sh; do
    [[ -e "$spec" ]] || continue
    [[ $# -gt 0 && "$spec" != *"$1"* ]] && continue
    printf "\n%s\n" "${spec##*/}"
    # shellcheck disable=SC1090
    source "$spec"
done

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
(( FAIL == 0 ))

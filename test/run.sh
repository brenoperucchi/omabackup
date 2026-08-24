#!/bin/bash
# Minimal runner. Usage: ./test/run.sh [pattern]
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

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

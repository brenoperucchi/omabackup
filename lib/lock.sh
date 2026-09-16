#!/bin/bash
# The Python boundary is the only code that opens a lock pathname. Bash then
# operates on the inherited descriptor, never reopening the name.

_OMABACKUP_ROOT="${OMABACKUP_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
_OMABACKUP_LOCK_HELPER="$_OMABACKUP_ROOT/lib/lock.py"
_OMABACKUP_LOCK_PYTHON_BIN=""
_OMABACKUP_LOCK_PYTHON_CHECKED=0

_lock_python_available() {
    if (( _OMABACKUP_LOCK_PYTHON_CHECKED )); then
        [[ -n "$_OMABACKUP_LOCK_PYTHON_BIN" ]]
        return
    fi
    _OMABACKUP_LOCK_PYTHON_CHECKED=1
    _OMABACKUP_LOCK_PYTHON_BIN="$(type -P python3 2>/dev/null || true)"
    [[ -n "$_OMABACKUP_LOCK_PYTHON_BIN" ]]
}

_lock_exec() {
    local directory="$1" name="$2"; shift 2
    # `bin/omabackup` pins PATH to the package-owned directories before this
    # file is sourced. Resolve the same interpreter that require_tools checks,
    # then isolate it: PYTHONPATH/PYTHONHOME, user-site .pth files and
    # sitecustomize/usercustomize must not become startup code in a new lock
    # boundary. Logging checks this availability before entering its
    # best-effort suppression; config's caller performs the explicit fatal
    # dependency check before it asks for a destination lock.
    _lock_python_available || return 127
    "$_OMABACKUP_LOCK_PYTHON_BIN" -I -S "$_OMABACKUP_LOCK_HELPER" \
        exec-with-lock "$directory" "$name" 9 -- "$@"
}

#!/bin/bash
# Small terminal primitives shared by the interactive configuration and
# restore surfaces. The CLI owns the interaction; this file only keeps their
# framing and cancellation affordance consistent over a tty or SSH.

tui_header() {
    local title="$1"
    printf '\033[2J\033[H'
    printf 'OmaBackup %s\n\n' "$title"
}

tui_sanitize() {
    # Keep this streaming: previews and status output can contain one line per
    # file. Strip byte-level CSI/C0/DEL first, then let a stable UTF-8 locale
    # replace C1 controls without mistaking ordinary UTF-8 continuation bytes
    # for controls when the caller inherited LC_ALL=C.
    if (($# > 0)); then
        printf '%s' "$1"
    else
        cat
    fi |
        LC_ALL=C sed -E \
            -e $'s/\x1b\\[[0-9;]*[A-Za-z]//g' \
            -e $'s/[\x01-\x09\x0b-\x1f\x7f]/?/g' |
        LC_ALL=C.UTF-8 sed -E 's/[[:cntrl:]]/?/g'
}

tui_sanitize_field() {
    local value
    value="$(tui_sanitize "$1")"
    # Metadata is rendered inline. Do not let a malformed path, URL, or
    # notice inject a second terminal line into the TUI.
    value="${value//$'\n'/?}"
    printf '%s' "$value"
}

_tui_restore_saved_traps() {
    local saved_exit="${1:-}" saved_hup="${2:-}" saved_int="${3:-}" saved_term="${4:-}"
    if [[ -n "$saved_exit" ]]; then eval "$saved_exit"; else trap - EXIT; fi
    if [[ -n "$saved_hup" ]]; then eval "$saved_hup"; else trap - HUP; fi
    if [[ -n "$saved_int" ]]; then eval "$saved_int"; else trap - INT; fi
    if [[ -n "$saved_term" ]]; then eval "$saved_term"; else trap - TERM; fi
}

# Read one human input value. Pipes keep the old line-oriented behavior for
# automation; a real terminal switches briefly to character mode so Escape
# cancels immediately, without requiring a second keypress. Basic echo and
# backspace are handled here so every Config/Restore prompt shares the same
# semantics.
tui_read_line() {
    local variable="$1" value="" char tty_state next tail_char
    if [[ ! -t 0 || ! -t 1 ]]; then
        IFS= read -r value || return 1
        printf -v "$variable" '%s' "$value"
        return 0
    fi

    tty_state="$(stty -g 2>/dev/null)" || {
        IFS= read -r value || return 1
        printf -v "$variable" '%s' "$value"
        return 0
    }
    local previous_exit previous_hup previous_int previous_term
    previous_exit="$(trap -p EXIT)"
    previous_hup="$(trap -p HUP)"
    previous_int="$(trap -p INT)"
    previous_term="$(trap -p TERM)"
    local tty_restored=0 tui_signal=""

    # Signals can interrupt a blocking read. Restore immediately in the trap,
    # then let the bounded read loop return so the caller can close the TUI.
    # The prior traps are restored below before this function returns; the
    # EXIT trap is also a last-resort guard if the shell itself exits here.
    trap 'if (( !tty_restored )); then stty "$tty_state" >/dev/null 2>&1 || true; tty_restored=1; fi; tui_signal=HUP' HUP
    trap 'if (( !tty_restored )); then stty "$tty_state" >/dev/null 2>&1 || true; tty_restored=1; fi; tui_signal=INT' INT
    trap 'if (( !tty_restored )); then stty "$tty_state" >/dev/null 2>&1 || true; tty_restored=1; fi; tui_signal=TERM' TERM
    trap 'if (( !tty_restored )); then stty "$tty_state" >/dev/null 2>&1 || true; tty_restored=1; fi; if [[ -n "$previous_exit" ]]; then eval "$previous_exit"; fi' EXIT
    if ! stty -icanon -echo min 1 time 0; then
        _tui_restore_saved_traps "$previous_exit" "$previous_hup" "$previous_int" "$previous_term"
        return 1
    fi
    while [[ -z "$tui_signal" ]]; do
        char=""
        if ! IFS= read -r -N 1 -t 0.2 char; then
            [[ -n "$tui_signal" ]] && break
            continue
        fi
        case "$char" in
            $'\033')
                # Cursor/function keys begin with Escape too (for example,
                # Up is ESC [ A). Only a bare Escape cancels; consume the
                # short control sequence and keep this prompt alive.
                next=""
                tail_char=""
                if IFS= read -r -N 1 -t 0.05 next; then
                    if [[ "$next" == '[' || "$next" == 'O' ]]; then
                        while IFS= read -r -N 1 -t 0.05 tail_char; do
                            [[ "$tail_char" == [A-Za-z~] ]] && break
                        done
                    fi
                    continue
                fi
                stty "$tty_state" >/dev/null 2>&1 || true
                tty_restored=1
                _tui_restore_saved_traps "$previous_exit" "$previous_hup" "$previous_int" "$previous_term"
                printf '\n'
                printf -v "$variable" '%s' "$char"
                return 0
                ;;
            $'\n'|$'\r')
                stty "$tty_state" >/dev/null 2>&1 || true
                tty_restored=1
                _tui_restore_saved_traps "$previous_exit" "$previous_hup" "$previous_int" "$previous_term"
                printf '\n'
                printf -v "$variable" '%s' "$value"
                return 0
                ;;
            $'\177'|$'\b')
                if [[ -n "$value" ]]; then
                    value="${value%?}"
                    printf '\b \b'
                fi
                ;;
            *)
                value+="$char"
                printf '%s' "$char"
                ;;
        esac
    done
    stty "$tty_state" >/dev/null 2>&1 || true
    tty_restored=1
    _tui_restore_saved_traps "$previous_exit" "$previous_hup" "$previous_int" "$previous_term"
    printf -v "$variable" '%s' "$value"
    case "$tui_signal" in
        HUP) kill -HUP "$$" >/dev/null 2>&1 || true ;;
        INT) kill -INT "$$" >/dev/null 2>&1 || true ;;
        TERM) kill -TERM "$$" >/dev/null 2>&1 || true ;;
    esac
    return 1
}

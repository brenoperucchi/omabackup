#!/bin/bash
# Small terminal primitives shared by the interactive configuration and
# restore surfaces. The CLI owns the interaction; this file only keeps their
# framing and cancellation affordance consistent over a tty or SSH.

tui_header() {
    local title="$1"
    printf '\033[2J\033[H'
    printf 'OmaBackup %s\n' "$title"
    # LOG_DIR (lib/log.sh) and _tilde (bin/omabackup) are both already
    # defined by the time any TUI screen actually runs -- shared by both
    # config (lib/config.sh) and restore (bin/omabackup), so a user hunting
    # for "what actually happened" (the case the log feature itself exists
    # for) does not need to already know this path to find it.
    #
    # Piped through tui_sanitize_field, not printed raw -- found by review
    # (round omabackup-33, `omabackup-rev`): LOG_DIR is derived from
    # OMABACKUP_LOG_DIR/OMABACKUP_STATE, both user-settable environment
    # values, and `_tilde` only does a HOME-prefix string substitution --
    # nothing about it strips a CSI/C0/C1 sequence or an embedded newline
    # that a crafted value could use to clear the screen or forge an extra
    # line in this banner. This is the same function `_log_write` already
    # trusts to make a log LINE safe to display; using it here too closes
    # the same class of risk for this new display path.
    printf 'Log: %s\n\n' "$(tui_sanitize_field "$(_tilde "$LOG_DIR")")"
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
    # The accumulator below is deliberately not named "value": a caller
    # passing that exact string as $1 (a very natural choice, and the one
    # `cmd_config_tui`'s own repository/enabled prompts used) would have its
    # `local variable="$1"` shadow this function's own local of the same
    # name. `printf -v "$variable"` would then write to THIS function's
    # local instead of the caller's, so the caller's variable would stay
    # unset -- and any `set -u` read of it afterward dies with "unbound
    # variable" instead of getting the typed line. Found live: both of
    # lib/config.sh's `tui_read_line value` call sites crashed exactly this
    # way the first time they were actually exercised interactively.
    #
    # Renaming the accumulator only narrows the collision class, it does not
    # close it: any of THIS function's own local names -- "input_buf" itself
    # included, along with "variable", "char", "tty_state", and the rest
    # declared below -- reproduces the identical silent failure if a future
    # caller happens to choose one. Refuse those explicitly instead, the same
    # way `_verify_extracted` (lib/bundle.sh) uses `${2?...}` to make bash
    # itself refuse to run rather than trust every future call site to dodge
    # a name it cannot see.
    local variable="$1"
    case "$variable" in
        variable|input_buf|char|tty_state|next|tail_char| \
        previous_exit|previous_hup|previous_int|previous_term| \
        tty_restored|tui_signal)
            printf 'tui_read_line: unsupported destination variable name: %q\n' "$variable" >&2
            return 1
            ;;
    esac
    local input_buf="" char tty_state next tail_char
    if [[ ! -t 0 || ! -t 1 ]]; then
        IFS= read -r input_buf || return 1
        printf -v "$variable" '%s' "$input_buf"
        return 0
    fi

    tty_state="$(stty -g 2>/dev/null)" || {
        IFS= read -r input_buf || return 1
        printf -v "$variable" '%s' "$input_buf"
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
                printf -v "$variable" '%s' "$input_buf"
                return 0
                ;;
            $'\177'|$'\b')
                if [[ -n "$input_buf" ]]; then
                    input_buf="${input_buf%?}"
                    printf '\b \b'
                fi
                ;;
            *)
                input_buf+="$char"
                printf '%s' "$char"
                ;;
        esac
    done
    stty "$tty_state" >/dev/null 2>&1 || true
    tty_restored=1
    _tui_restore_saved_traps "$previous_exit" "$previous_hup" "$previous_int" "$previous_term"
    printf -v "$variable" '%s' "$input_buf"
    case "$tui_signal" in
        HUP) kill -HUP "$$" >/dev/null 2>&1 || true ;;
        INT) kill -INT "$$" >/dev/null 2>&1 || true ;;
        TERM) kill -TERM "$$" >/dev/null 2>&1 || true ;;
    esac
    return 1
}

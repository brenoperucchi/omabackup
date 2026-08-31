# Regressions for lib/tui.sh's tui_read_line, exercised directly rather than
# through a CLI wrapper. It is the primitive every interactive Config and
# Restore prompt is built on, so a bug here stays invisible until some
# specific call site happens to pass the one destination name that collides
# with the function's own locals -- see test/config.test.sh's "Backup
# repository"/"Automatic backups" regressions for the incident this closes.
#
# Each case runs `tui_read_line` inside its own `bash -c` subshell (the same
# isolation test/bundle.test.sh already uses for sourced library functions)
# so nothing it does leaks a variable into this runner's own shell, which
# every other spec in the suite also runs in.

it "tui_read_line reads a piped line into an ordinary destination variable"
TRL_OK="$(bash -c 'source lib/tui.sh; tui_read_line answer <<< "typed line"; printf "%s" "$answer"')"
assert_eq "$TRL_OK" "typed line"

it "tui_read_line correctly reads into a variable named \"value\" -- the exact name that used to collide"
TRL_VALUE="$(bash -c 'source lib/tui.sh; tui_read_line value <<< "typed line"; printf "%s" "$value"')"
assert_eq "$TRL_VALUE" "typed line"

it "tui_read_line refuses a destination name that collides with one of its own current locals"
TRL_BAD_RC=0
bash -c 'source lib/tui.sh; tui_read_line input_buf <<< "typed line"' >/dev/null 2>&1 || TRL_BAD_RC=$?
[[ $TRL_BAD_RC -ne 0 ]] && ok || fail "a colliding destination name was silently accepted instead of refused"

it "the reserved-name guard covers every one of tui_read_line's own locals, not just the renamed one"
TRL_FIRST_ACCEPTED=""
for reserved in variable input_buf char tty_state next tail_char \
    previous_exit previous_hup previous_int previous_term tty_restored tui_signal; do
    TRL_RC=0
    bash -c 'source lib/tui.sh; tui_read_line "$1" <<< x' _ "$reserved" >/dev/null 2>&1 || TRL_RC=$?
    if [[ $TRL_RC -eq 0 ]]; then
        TRL_FIRST_ACCEPTED="$reserved"
        break
    fi
done
[[ -z "$TRL_FIRST_ACCEPTED" ]] \
    && ok || fail "tui_read_line accepted the reserved name '$TRL_FIRST_ACCEPTED' as a destination"

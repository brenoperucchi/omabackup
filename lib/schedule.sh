#!/bin/bash

# User-facing schedules use the familiar five-field crontab form. systemd is
# still the scheduler underneath, but its OnCalendar grammar never leaks into
# the settings surface.

_schedule_number() {
    local value="$1" minimum="$2" maximum="$3" normalized
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    normalized="$value"
    while [[ ${#normalized} -gt 1 && ${normalized:0:1} == 0 ]]; do
        normalized="${normalized:1}"
    done
    # Bound the decimal string before Bash arithmetic sees it. Without this
    # guard, an integer larger than the shell's arithmetic width can wrap and
    # pass a range check as a small number.
    (( ${#normalized} <= ${#maximum} )) || return 1
    (( 10#$normalized >= minimum && 10#$normalized <= maximum ))
}

_schedule_time() {
    local value="$1" hour minute
    [[ "$value" =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || return 1
    hour="${BASH_REMATCH[1]}"
    minute="${BASH_REMATCH[2]}"
    _schedule_number "$hour" 0 23 || return 1
    _schedule_number "$minute" 0 59 || return 1
    printf '%02d:%02d' "$((10#$hour))" "$((10#$minute))"
}

schedule_normalize_cron() {
    local value="$1" fields=()
    [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
    read -r -a fields <<<"$value"
    (( ${#fields[@]} == 5 )) || return 1
    [[ "${fields[*]}" == "$value" || -n "$value" ]] || return 1
    printf '%s %s %s %s %s' "${fields[0]}" "${fields[1]}" "${fields[2]}" "${fields[3]}" "${fields[4]}"
}

schedule_alias_to_cron() {
    case "$1" in
        @hourly|hourly)   printf '0 * * * *' ;;
        @daily|daily)     printf '0 0 * * *' ;;
        @weekly|weekly)   printf '0 0 * * 0' ;;
        @monthly|monthly) printf '0 0 1 * *' ;;
        *)                schedule_normalize_cron "$1" ;;
    esac
}

# Turn the stable five-field value into a sentence for a person. The cron
# string remains available in JSON for scripts; normal terminal status should
# answer when the backup runs without making the user decode five columns.
schedule_cron_description() {
    local cron minute hour dom month dow day
    cron="$(schedule_alias_to_cron "$1")" || return 1
    read -r minute hour dom month dow <<<"$cron"
    if [[ "$minute" == "*" && "$hour" == "*" && "$dom" == "*" && "$month" == "*" && "$dow" == "*" ]]; then
        printf 'Every minute'
    elif [[ "$minute" =~ ^\*/([0-9]+)$ && "$hour" == "*" && "$dom" == "*" && "$month" == "*" && "$dow" == "*" ]]; then
        local step="${BASH_REMATCH[1]}"
        _schedule_number "$step" 1 59 || return 1
        printf 'Every %d minutes' "$((10#$step))"
    elif [[ "$hour" == "*" && "$dom" == "*" && "$month" == "*" && "$dow" == "*" ]]; then
        _schedule_number "$minute" 0 59 || return 1
        printf 'Every hour at minute %02d' "$((10#$minute))"
    elif [[ "$dom" == "*" && "$month" == "*" && "$dow" == "*" ]]; then
        _schedule_number "$hour" 0 23 && _schedule_number "$minute" 0 59 || return 1
        printf 'Every day at %02d:%02d' "$((10#$hour))" "$((10#$minute))"
    elif [[ "$dom" == "*" && "$month" == "*" && "$dow" != "*" ]]; then
        day="$(_schedule_dow_name "$dow")" || return 1
        _schedule_number "$hour" 0 23 && _schedule_number "$minute" 0 59 || return 1
        printf 'Every %s at %02d:%02d' "$day" "$((10#$hour))" "$((10#$minute))"
    else
        printf 'Custom schedule'
    fi
}

_schedule_dow_name() {
    case "$1" in
        0|7) printf 'Sun' ;;
        1)   printf 'Mon' ;;
        2)   printf 'Tue' ;;
        3)   printf 'Wed' ;;
        4)   printf 'Thu' ;;
        5)   printf 'Fri' ;;
        6)   printf 'Sat' ;;
        *)   return 1 ;;
    esac
}

schedule_cron_to_calendar() {
    local cron minute hour dom month dow n day time
    cron="$(schedule_alias_to_cron "$1")" || return 1
    read -r minute hour dom month dow <<<"$cron"

    if [[ "$minute" == "*" && "$hour" == "*" && "$dom" == "*" && "$month" == "*" && "$dow" == "*" ]]; then
        printf '*:*:00'
        return
    fi
    if [[ "$minute" =~ ^\*/([0-9]+)$ && "$hour" == "*" && "$dom" == "*" && "$month" == "*" && "$dow" == "*" ]]; then
        n="${BASH_REMATCH[1]}"
        _schedule_number "$n" 1 59 || return 1
        printf '*:0/%d' "$((10#$n))"
        return
    fi
    [[ "$minute" != *,* && "$minute" != *-* && "$hour" != *,* && "$hour" != *-* \
       && "$dom" != *,* && "$dom" != *-* && "$month" != *,* && "$month" != *-* \
       && "$dow" != *,* && "$dow" != *-* ]] || return 1
    _schedule_number "$minute" 0 59 || return 1
    if [[ "$hour" != "*" ]]; then _schedule_number "$hour" 0 23 || return 1; fi
    if [[ "$dom" != "*" ]]; then _schedule_number "$dom" 1 31 || return 1; fi
    if [[ "$month" != "*" ]]; then _schedule_number "$month" 1 12 || return 1; fi
    if [[ "$dow" != "*" ]]; then day="$(_schedule_dow_name "$dow")" || return 1; fi
    [[ "$dom" == "*" || "$dow" == "*" ]] || return 1

    if [[ "$hour" == "*" ]]; then
        [[ "$dom" == "*" && "$month" == "*" && "$dow" == "*" ]] || return 1
        printf '*-*-* *:%02d:00' "$((10#$minute))"
    elif [[ "$dom" == "*" && "$month" == "*" && "$dow" == "*" ]]; then
        printf '*-*-* %02d:%02d:00' "$((10#$hour))" "$((10#$minute))"
    elif [[ "$dom" != "*" && "$month" == "*" && "$dow" == "*" ]]; then
        printf '*-*-%02d %02d:%02d:00' "$((10#$dom))" "$((10#$hour))" "$((10#$minute))"
    elif [[ "$month" != "*" && "$dom" == "*" && "$dow" == "*" ]]; then
        printf '*-%02d-* %02d:%02d:00' "$((10#$month))" "$((10#$hour))" "$((10#$minute))"
    elif [[ "$month" != "*" && "$dom" != "*" && "$dow" == "*" ]]; then
        printf '*-%02d-%02d %02d:%02d:00' "$((10#$month))" "$((10#$dom))" "$((10#$hour))" "$((10#$minute))"
    elif [[ "$dow" != "*" && "$dom" == "*" && "$month" == "*" ]]; then
        printf '%s *-*-* %02d:%02d:00' "$day" "$((10#$hour))" "$((10#$minute))"
    else
        return 1
    fi
}

schedule_calendar_to_cron() {
    local value="$1" minute hour dom month dow day rest n
    case "$value" in
        hourly)   printf '0 * * * *'; return ;;
        daily)    printf '0 0 * * *'; return ;;
        weekly)   printf '0 0 * * 0'; return ;;
        monthly)  printf '0 0 1 * *'; return ;;
        '*:0')    printf '0 * * * *'; return ;;
        '*:*:00') printf '* * * * *'; return ;;
        '*-*-* *:*:00') printf '* * * * *'; return ;;
    esac
    if [[ "$value" =~ ^\*:0/([0-9]+)$ ]]; then
        n="${BASH_REMATCH[1]}"
        _schedule_number "$n" 1 59 || return 1
        printf '*/%d * * * *' "$((10#$n))"
        return
    fi
    if [[ "$value" =~ ^\*-\*-\*\ \*:00/([0-9]+):00$ ]]; then
        n="${BASH_REMATCH[1]}"
        _schedule_number "$n" 1 59 || return 1
        printf '*/%d * * * *' "$((10#$n))"
        return
    fi
    if [[ "$value" =~ ^\*-\*-\*\ \*:([0-9]{2}):00$ ]]; then
        minute="${BASH_REMATCH[1]}"
        _schedule_number "$minute" 0 59 || return 1
        printf '%d * * * *' "$((10#$minute))"
        return
    fi
    if [[ "$value" =~ ^\*-\*-\*\ ([0-9]{1,2}):([0-9]{2}):00$ ]]; then
        hour="${BASH_REMATCH[1]}"; minute="${BASH_REMATCH[2]}"
        _schedule_number "$hour" 0 23 && _schedule_number "$minute" 0 59 || return 1
        printf '%d %d * * *' "$((10#$minute))" "$((10#$hour))"
        return
    fi
    if [[ "$value" =~ ^([A-Z][a-z]{2})\ \*-\*-\*\ ([0-9]{1,2}):([0-9]{2}):00$ ]]; then
        day="${BASH_REMATCH[1]}"; hour="${BASH_REMATCH[2]}"; minute="${BASH_REMATCH[3]}"
        case "$day" in Sun) dow=0;; Mon) dow=1;; Tue) dow=2;; Wed) dow=3;; Thu) dow=4;; Fri) dow=5;; Sat) dow=6;; *) return 1;; esac
        _schedule_number "$hour" 0 23 && _schedule_number "$minute" 0 59 || return 1
        printf '%d %d * * %d' "$((10#$minute))" "$((10#$hour))" "$dow"
        return
    fi
    if [[ "$value" =~ ^\*-\*-([0-9]{1,2})\ ([0-9]{1,2}):([0-9]{2}):00$ ]]; then
        dom="${BASH_REMATCH[1]}"; hour="${BASH_REMATCH[2]}"; minute="${BASH_REMATCH[3]}"
        _schedule_number "$dom" 1 31 && _schedule_number "$hour" 0 23 && _schedule_number "$minute" 0 59 || return 1
        printf '%d %d %d * *' "$((10#$minute))" "$((10#$hour))" "$((10#$dom))"
        return
    fi
    if [[ "$value" =~ ^\*-([0-9]{1,2})-\*\ ([0-9]{1,2}):([0-9]{2}):00$ ]]; then
        month="${BASH_REMATCH[1]}"; hour="${BASH_REMATCH[2]}"; minute="${BASH_REMATCH[3]}"
        _schedule_number "$month" 1 12 && _schedule_number "$hour" 0 23 && _schedule_number "$minute" 0 59 || return 1
        printf '%d %d * %d *' "$((10#$minute))" "$((10#$hour))" "$((10#$month))"
        return
    fi
    if [[ "$value" =~ ^\*-([0-9]{1,2})-([0-9]{1,2})\ ([0-9]{1,2}):([0-9]{2}):00$ ]]; then
        month="${BASH_REMATCH[1]}"; dom="${BASH_REMATCH[2]}"
        hour="${BASH_REMATCH[3]}"; minute="${BASH_REMATCH[4]}"
        _schedule_number "$month" 1 12 && _schedule_number "$dom" 1 31 \
            && _schedule_number "$hour" 0 23 && _schedule_number "$minute" 0 59 || return 1
        printf '%d %d %d %d *' "$((10#$minute))" "$((10#$hour))" "$((10#$dom))" "$((10#$month))"
        return
    fi
    return 1
}

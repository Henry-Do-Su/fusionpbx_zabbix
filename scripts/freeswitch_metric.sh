#!/bin/bash
# =============================================================================
# freeswitch_metric.sh - Collects FreeSWITCH, FusionPBX and Event Guard metrics
# Place in: /etc/zabbix/scripts/freeswitch_metric.sh
# =============================================================================

set -euo pipefail

CONFIG_FILE="/etc/zabbix/freeswitch_monitor.conf"

if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1091
    . "${CONFIG_FILE}"
fi

# --- FreeSWITCH defaults ---
FS_CLI="${FS_CLI:-/usr/local/freeswitch/bin/fs_cli}"
FS_TIMEOUT="${FS_TIMEOUT:-5}"

# --- iptables / FusionPBX Event Guard defaults ---
IPTABLES="${IPTABLES:-/usr/sbin/iptables}"
IPTABLES_TIMEOUT="${IPTABLES_TIMEOUT:-5}"
EVENT_GUARD_CHAINS="${EVENT_GUARD_CHAINS:-sip-auth-ip sip-auth-fail}"

fs_cmd() {
    local result
    result=$(timeout "${FS_TIMEOUT}" "${FS_CLI}" -x "$1" 2>/dev/null) || true
    printf '%s\n' "${result}"
}

first_int() {
    awk '
        BEGIN { found = 0 }
        {
            for (i = 1; i <= NF; i++) {
                gsub(/,/, "", $i)
                if ($i ~ /^[0-9]+$/) {
                    print $i
                    found = 1
                    exit
                }
            }
        }
        END {
            if (!found) print 0
        }
    ' <<< "${1:-}"
}

clean_text() {
    tr -d ',' <<< "${1:-}"
}

iptables_cmd() {
    timeout "${IPTABLES_TIMEOUT}" sudo -n "${IPTABLES}" "$@" 2>/dev/null || true
}

iptables_check() {
    timeout "${IPTABLES_TIMEOUT}" sudo -n "${IPTABLES}" "$@" >/dev/null 2>&1
}

event_guard_chain_allowed() {
    case "${1:-}" in
        sip-auth-ip|sip-auth-fail)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

valid_event_guard_chain() {
    if event_guard_chain_allowed "${1:-}"; then
        return 0
    fi

    echo "ZBX_NOTSUPPORTED: invalid Event Guard chain '${1:-}'"
    exit 1
}

event_guard_ips() {
    local chain="${1:-}"
    valid_event_guard_chain "${chain}"

    iptables_cmd -S "${chain}" | awk -v chain="${chain}" '
        $1 == "-A" && $2 == chain {
            source = ""
            target = ""

            for (i = 3; i <= NF; i++) {
                if ($i == "-s" && (i + 1) <= NF) {
                    source = $(i + 1)
                }
                if ($i == "-j" && (i + 1) <= NF) {
                    target = $(i + 1)
                }
            }

            if (source != "" && (target == "DROP" || target == "REJECT")) {
                print source
            }
        }
    ' | sed 's#/32$##'
}

event_guard_counter() {
    local chain="${1:-}"
    local mode="${2:-packets}"
    valid_event_guard_chain "${chain}"

    iptables_cmd -L "${chain}" -n -v -x | awk -v mode="${mode}" '
        NR > 2 && ($3 == "DROP" || $3 == "REJECT") {
            packets += $1
            bytes += $2
        }
        END {
            if (mode == "bytes") {
                print bytes + 0
            }
            else {
                print packets + 0
            }
        }
    '
}

event_guard_lld() {
    local first=1
    local chain

    printf '{"data":['

    for chain in ${EVENT_GUARD_CHAINS}; do
        if ! event_guard_chain_allowed "${chain}"; then
            continue
        fi

        if iptables_check -S "${chain}"; then
            if [[ ${first} -eq 0 ]]; then
                printf ','
            fi

            printf '{"{#CHAIN}":"%s"}' "${chain}"
            first=0
        fi
    done

    printf ']}\n'
}

event_guard_all_total() {
    local chain
    local total=0
    local count

    for chain in ${EVENT_GUARD_CHAINS}; do
        if ! event_guard_chain_allowed "${chain}"; then
            continue
        fi

        count=$(event_guard_ips "${chain}" | awk 'END { print NR + 0 }')
        total=$((total + count))
    done

    echo "${total}"
}

event_guard_all_unique() {
    local chain

    for chain in ${EVENT_GUARD_CHAINS}; do
        if ! event_guard_chain_allowed "${chain}"; then
            continue
        fi

        event_guard_ips "${chain}"
    done | sort -u | awk 'END { print NR + 0 }'
}

event_guard_all_duplicates() {
    local total
    local unique

    total=$(event_guard_all_total)
    unique=$(event_guard_all_unique)

    echo $((total - unique))
}

event_guard_all_counter() {
    local mode="${1:-packets}"
    local chain
    local total=0
    local count

    for chain in ${EVENT_GUARD_CHAINS}; do
        if ! event_guard_chain_allowed "${chain}"; then
            continue
        fi

        count=$(event_guard_counter "${chain}" "${mode}")
        total=$((total + count))
    done

    echo "${total}"
}

METRIC="${1:-}"

case "${METRIC}" in

    # -------------------------------------------------------------------------
    # FreeSWITCH calls
    # -------------------------------------------------------------------------

    calls_total)
        RAW=$(fs_cmd "show calls count")
        first_int "${RAW}"
        ;;

    calls_inbound)
        RAW=$(fs_cmd "show calls count inbound")
        first_int "${RAW}"
        ;;

    calls_outbound)
        RAW=$(fs_cmd "show calls count outbound")
        first_int "${RAW}"
        ;;

    # -------------------------------------------------------------------------
    # FreeSWITCH channels
    # -------------------------------------------------------------------------

    channels_count)
        RAW=$(fs_cmd "show channels count")
        first_int "${RAW}"
        ;;

    # -------------------------------------------------------------------------
    # FreeSWITCH sessions
    # -------------------------------------------------------------------------

    sessions_current)
        RAW=$(clean_text "$(fs_cmd "status")")
        awk '
            BEGIN { found = 0 }
            /^[0-9]+ session\(s\) - peak [0-9]+/ {
                print $1
                found = 1
                exit
            }
            END {
                if (!found) print 0
            }
        ' <<< "${RAW}"
        ;;

    sessions_peak)
        RAW=$(clean_text "$(fs_cmd "status")")
        awk '
            BEGIN { found = 0 }
            /^[0-9]+ session\(s\) - peak [0-9]+/ {
                for (i = 1; i <= NF; i++) {
                    if ($i == "peak" && (i + 1) <= NF && $(i + 1) ~ /^[0-9]+$/) {
                        print $(i + 1)
                        found = 1
                        exit
                    }
                }
            }
            END {
                if (!found) print 0
            }
        ' <<< "${RAW}"
        ;;

    sessions_max)
        RAW=$(clean_text "$(fs_cmd "status")")
        awk '
            BEGIN { found = 0 }
            /^[0-9]+ session\(s\) max$/ {
                print $1
                found = 1
                exit
            }
            END {
                if (!found) print 0
            }
        ' <<< "${RAW}"
        ;;

    sessions_per_sec_current)
        RAW=$(clean_text "$(fs_cmd "status")")
        awk '
            BEGIN { found = 0 }
            /^[0-9]+ session\(s\) per Sec out of max [0-9]+/ {
                print $1
                found = 1
                exit
            }
            END {
                if (!found) print 0
            }
        ' <<< "${RAW}"
        ;;

    sessions_per_sec_max)
        RAW=$(clean_text "$(fs_cmd "status")")
        awk '
            BEGIN { found = 0 }
            /^[0-9]+ session\(s\) per Sec out of max [0-9]+/ {
                for (i = 1; i <= NF; i++) {
                    if ($i == "max" && (i + 1) <= NF && $(i + 1) ~ /^[0-9]+$/) {
                        print $(i + 1)
                        found = 1
                        exit
                    }
                }
            }
            END {
                if (!found) print 0
            }
        ' <<< "${RAW}"
        ;;

    # -------------------------------------------------------------------------
    # FreeSWITCH registrations
    # -------------------------------------------------------------------------

    registrations)
        RAW=$(fs_cmd "show registrations count")
        first_int "${RAW}"
        ;;

    # -------------------------------------------------------------------------
    # FreeSWITCH health
    # -------------------------------------------------------------------------

    uptime)
        RAW=$(clean_text "$(fs_cmd "status")")
        awk '
            BEGIN {
                years = 0
                days = 0
                hours = 0
                minutes = 0
                seconds = 0
            }
            {
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /^years?$/) {
                        years = $(i - 1)
                    }
                    if ($i ~ /^days?$/) {
                        days = $(i - 1)
                    }
                    if ($i ~ /^hours?$/) {
                        hours = $(i - 1)
                    }
                    if ($i ~ /^minutes?$/) {
                        minutes = $(i - 1)
                    }
                    if ($i ~ /^seconds?$/) {
                        seconds = $(i - 1)
                    }
                }
            }
            END {
                print years * 31536000 + days * 86400 + hours * 3600 + minutes * 60 + seconds
            }
        ' <<< "${RAW}"
        ;;

    ready)
        RAW=$(fs_cmd "status")
        if [[ -n "${RAW}" && "${RAW}" == *"is ready"* ]]; then
            echo 1
        else
            echo 0
        fi
        ;;

    gateways_failed)
        RAW=$(fs_cmd "sofia status")
        COUNT=$(grep -cE 'UNREGED|FAILED|EXPIRED' <<< "${RAW}" || true)
        echo "${COUNT:-0}"
        ;;

    # -------------------------------------------------------------------------
    # FusionPBX Event Guard / iptables
    # -------------------------------------------------------------------------

    event_guard_lld)
        event_guard_lld
        ;;

    event_guard_chain_exists)
        CHAIN="${2:-}"
        valid_event_guard_chain "${CHAIN}"

        if iptables_check -S "${CHAIN}"; then
            echo 1
        else
            echo 0
        fi
        ;;

    event_guard_banned_total)
        CHAIN="${2:-}"
        event_guard_ips "${CHAIN}" | awk 'END { print NR + 0 }'
        ;;

    event_guard_banned_unique)
        CHAIN="${2:-}"
        event_guard_ips "${CHAIN}" | sort -u | awk 'END { print NR + 0 }'
        ;;

    event_guard_banned_duplicates)
        CHAIN="${2:-}"
        TOTAL=$(event_guard_ips "${CHAIN}" | awk 'END { print NR + 0 }')
        UNIQUE=$(event_guard_ips "${CHAIN}" | sort -u | awk 'END { print NR + 0 }')
        echo $((TOTAL - UNIQUE))
        ;;

    event_guard_banned_list)
        CHAIN="${2:-}"
        event_guard_ips "${CHAIN}" | sort -u | paste -sd ',' -
        ;;

    event_guard_packets)
        CHAIN="${2:-}"
        event_guard_counter "${CHAIN}" packets
        ;;

    event_guard_bytes)
        CHAIN="${2:-}"
        event_guard_counter "${CHAIN}" bytes
        ;;

    event_guard_banned_total_all)
        event_guard_all_total
        ;;

    event_guard_banned_unique_all)
        event_guard_all_unique
        ;;

    event_guard_banned_duplicates_all)
        event_guard_all_duplicates
        ;;

    event_guard_packets_all)
        event_guard_all_counter packets
        ;;

    event_guard_bytes_all)
        event_guard_all_counter bytes
        ;;

    *)
        echo "ZBX_NOTSUPPORTED: unknown metric '${METRIC}'"
        exit 1
        ;;
esac

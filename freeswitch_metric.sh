#!/bin/bash
# =============================================================================
# freeswitch_metric.sh - Collects FreeSWITCH metrics for Zabbix
# Place in: /etc/zabbix/scripts/freeswitch_metric.sh
# =============================================================================

set -euo pipefail

CONFIG_FILE="/etc/zabbix/freeswitch_monitor.conf"

if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1091
    . "${CONFIG_FILE}"
fi

FS_CLI="${FS_CLI:-/usr/local/freeswitch/bin/fs_cli}"
FS_TIMEOUT="${FS_TIMEOUT:-5}"

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

METRIC="${1:-}"

case "${METRIC}" in

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

    channels_count)
        RAW=$(fs_cmd "show channels count")
        first_int "${RAW}"
        ;;

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
                    if ($i == "peak" && (i+1) <= NF && $(i+1) ~ /^[0-9]+$/) {
                        print $(i+1)
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
                    if ($i == "max" && (i+1) <= NF && $(i+1) ~ /^[0-9]+$/) {
                        print $(i+1)
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

    registrations)
        RAW=$(fs_cmd "sofia status profile internal reg_count")
        first_int "${RAW}"
        ;;

    uptime)
        RAW=$(clean_text "$(fs_cmd "status")")
        # NOTE: Uses 365-day year (approximate). Acceptable since this metric
        # is only used for restart detection, not precise timekeeping.
        YEARS=$(awk '{for(i=1;i<=NF;i++) if($i ~ /^years?$/)  {print $(i-1); found=1; exit}} END{if(!found) print 0}' found=0 <<< "${RAW}")
        DAYS=$(awk  '{for(i=1;i<=NF;i++) if($i ~ /^days?$/)   {print $(i-1); found=1; exit}} END{if(!found) print 0}' found=0 <<< "${RAW}")
        HOURS=$(awk '{for(i=1;i<=NF;i++) if($i ~ /^hours?$/)  {print $(i-1); found=1; exit}} END{if(!found) print 0}' found=0 <<< "${RAW}")
        MINS=$(awk  '{for(i=1;i<=NF;i++) if($i ~ /^minutes?$/){print $(i-1); found=1; exit}} END{if(!found) print 0}' found=0 <<< "${RAW}")
        SECS=$(awk  '{for(i=1;i<=NF;i++) if($i ~ /^seconds?$/){print $(i-1); found=1; exit}} END{if(!found) print 0}' found=0 <<< "${RAW}")

        echo $(( YEARS*31536000 + DAYS*86400 + HOURS*3600 + MINS*60 + SECS ))
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
        # Approximate count of unhealthy gateways from sofia status output.
        # This is a rough indicator based on CLI text matching, not an
        # authoritative per-gateway health check.
        RAW=$(fs_cmd "sofia status")
        COUNT=$(grep -cE 'UNREGED|FAILED|EXPIRED' <<< "${RAW}" || true)
        echo "${COUNT:-0}"
        ;;

    *)
        echo "ZBX_NOTSUPPORTED: unknown metric '${METRIC}'"
        exit 1
        ;;
esac

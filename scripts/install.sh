#!/bin/bash
# =============================================================================
# install.sh - Installs Zabbix FreeSWITCH / FusionPBX monitoring UserParameters
#
# Usage:
#   sudo bash scripts/install.sh
#   sudo bash scripts/install.sh --fs-cli /usr/bin/fs_cli
#   sudo bash scripts/install.sh --iptables /usr/sbin/iptables
#   sudo bash scripts/install.sh --install-sudoers
#   sudo bash scripts/install.sh --restart
#
# Environment variables:
#   FS_CLI=/path/to/fs_cli
#   IPTABLES=/path/to/iptables
#   RESTART_AGENT=1
#   INSTALL_SUDOERS=1
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --- Defaults, overridable via env or flags ---
FS_CLI="${FS_CLI:-/usr/local/freeswitch/bin/fs_cli}"
IPTABLES="${IPTABLES:-/usr/sbin/iptables}"
RESTART_AGENT="${RESTART_AGENT:-0}"
INSTALL_SUDOERS="${INSTALL_SUDOERS:-0}"

# --- Parse flags ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --fs-cli)
            FS_CLI="$2"
            shift 2
            ;;
        --iptables)
            IPTABLES="$2"
            shift 2
            ;;
        --restart)
            RESTART_AGENT=1
            shift
            ;;
        --install-sudoers)
            INSTALL_SUDOERS=1
            shift
            ;;
        --help)
            echo "Usage: sudo bash scripts/install.sh [--fs-cli PATH] [--iptables PATH] [--install-sudoers] [--restart]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "=== FreeSWITCH / FusionPBX Zabbix Monitor - Installer ==="

# --- Must be root ---
if [[ ${EUID} -ne 0 ]]; then
    echo "ERROR: Run as root, for example:"
    echo "  sudo bash scripts/install.sh"
    exit 1
fi

# --- Validate repo files ---
if [[ ! -f "${REPO_DIR}/scripts/freeswitch_metric.sh" ]]; then
    echo "ERROR: Missing ${REPO_DIR}/scripts/freeswitch_metric.sh"
    exit 1
fi

if [[ ! -f "${REPO_DIR}/conf/userparameter_freeswitch.conf" ]]; then
    echo "ERROR: Missing ${REPO_DIR}/conf/userparameter_freeswitch.conf"
    exit 1
fi

if [[ ! -f "${REPO_DIR}/conf/freeswitch_monitor.conf.example" ]]; then
    echo "ERROR: Missing ${REPO_DIR}/conf/freeswitch_monitor.conf.example"
    exit 1
fi

# --- Detect Zabbix agent config ---
ZABBIX_MAIN_CONF=""
AGENT_BIN=""
AGENT_SERVICE=""

if [[ -f /etc/zabbix/zabbix_agent2.conf ]]; then
    ZABBIX_MAIN_CONF="/etc/zabbix/zabbix_agent2.conf"
    AGENT_BIN="zabbix_agent2"
    AGENT_SERVICE="zabbix-agent2"
elif [[ -f /etc/zabbix/zabbix_agentd.conf ]]; then
    ZABBIX_MAIN_CONF="/etc/zabbix/zabbix_agentd.conf"
    AGENT_BIN="zabbix_agentd"
    AGENT_SERVICE="zabbix-agent"
else
    echo "ERROR: Could not find Zabbix agent config in /etc/zabbix/"
    exit 1
fi

echo "Agent config: ${ZABBIX_MAIN_CONF}"

# --- Detect Include directory from Zabbix config ---
INCLUDE_RAW="$(awk -F= '
    /^[[:space:]]*Include[[:space:]]*=/ {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
        print $2
        exit
    }
' "${ZABBIX_MAIN_CONF}")"

if [[ -z "${INCLUDE_RAW}" ]]; then
    echo "ERROR: Could not find uncommented Include= line in ${ZABBIX_MAIN_CONF}"
    exit 1
fi

case "${INCLUDE_RAW}" in
    */*.conf)
        ZABBIX_CONF_DIR="$(dirname "${INCLUDE_RAW}")"
        ;;
    */\*)
        ZABBIX_CONF_DIR="${INCLUDE_RAW%/*}"
        ;;
    *)
        ZABBIX_CONF_DIR="${INCLUDE_RAW}"
        ;;
esac

if [[ ! -d "${ZABBIX_CONF_DIR}" ]]; then
    echo "ERROR: Include directory does not exist: ${ZABBIX_CONF_DIR}"
    exit 1
fi

echo "Include dir:  ${ZABBIX_CONF_DIR}"

# --- Detect Zabbix agent runtime user ---
ZABBIX_USER=""
if systemctl status "${AGENT_SERVICE}" >/dev/null 2>&1; then
    ZABBIX_USER="$(systemctl show -p User --value "${AGENT_SERVICE}" 2>/dev/null || true)"
fi

ZABBIX_USER="${ZABBIX_USER:-zabbix}"
echo "Agent user:   ${ZABBIX_USER}"

# --- Validate binaries ---
if [[ ! -x "${FS_CLI}" ]]; then
    echo "WARNING: fs_cli not found or not executable at: ${FS_CLI}"
    echo "         FreeSWITCH metrics may fail until FS_CLI is corrected in /etc/zabbix/freeswitch_monitor.conf"
else
    echo "fs_cli:       ${FS_CLI}"
fi

if [[ ! -x "${IPTABLES}" ]]; then
    echo "WARNING: iptables not found or not executable at: ${IPTABLES}"
    echo "         Event Guard metrics may fail until IPTABLES is corrected in /etc/zabbix/freeswitch_monitor.conf"
else
    echo "iptables:     ${IPTABLES}"
fi

# --- Install metric script ---
ZABBIX_SCRIPT_DIR="/etc/zabbix/scripts"

echo ""
echo "Installing metric script to ${ZABBIX_SCRIPT_DIR}/..."
mkdir -p "${ZABBIX_SCRIPT_DIR}"
chown root:root "${ZABBIX_SCRIPT_DIR}"
chmod 755 "${ZABBIX_SCRIPT_DIR}"

cp "${REPO_DIR}/scripts/freeswitch_metric.sh" "${ZABBIX_SCRIPT_DIR}/freeswitch_metric.sh"
chown root:"${ZABBIX_USER}" "${ZABBIX_SCRIPT_DIR}/freeswitch_metric.sh"
chmod 750 "${ZABBIX_SCRIPT_DIR}/freeswitch_metric.sh"

# --- Install config file if not present ---
if [[ ! -f /etc/zabbix/freeswitch_monitor.conf ]]; then
    echo "Installing config to /etc/zabbix/freeswitch_monitor.conf..."
    cp "${REPO_DIR}/conf/freeswitch_monitor.conf.example" /etc/zabbix/freeswitch_monitor.conf
else
    echo "Config /etc/zabbix/freeswitch_monitor.conf already exists; preserving it."
fi

# Ensure newer keys exist in config.
grep -q '^FS_CLI=' /etc/zabbix/freeswitch_monitor.conf || echo "FS_CLI=\"${FS_CLI}\"" >> /etc/zabbix/freeswitch_monitor.conf
grep -q '^FS_TIMEOUT=' /etc/zabbix/freeswitch_monitor.conf || echo "FS_TIMEOUT=5" >> /etc/zabbix/freeswitch_monitor.conf
grep -q '^IPTABLES=' /etc/zabbix/freeswitch_monitor.conf || echo "IPTABLES=\"${IPTABLES}\"" >> /etc/zabbix/freeswitch_monitor.conf
grep -q '^IPTABLES_TIMEOUT=' /etc/zabbix/freeswitch_monitor.conf || echo "IPTABLES_TIMEOUT=5" >> /etc/zabbix/freeswitch_monitor.conf
grep -q '^EVENT_GUARD_CHAINS=' /etc/zabbix/freeswitch_monitor.conf || echo 'EVENT_GUARD_CHAINS="sip-auth-ip sip-auth-fail"' >> /etc/zabbix/freeswitch_monitor.conf

chown root:"${ZABBIX_USER}" /etc/zabbix/freeswitch_monitor.conf
chmod 640 /etc/zabbix/freeswitch_monitor.conf

# --- Install UserParameter config ---
echo "Installing UserParameter config to ${ZABBIX_CONF_DIR}/..."
cp "${REPO_DIR}/conf/userparameter_freeswitch.conf" "${ZABBIX_CONF_DIR}/userparameter_freeswitch.conf"
chown root:root "${ZABBIX_CONF_DIR}/userparameter_freeswitch.conf"
chmod 644 "${ZABBIX_CONF_DIR}/userparameter_freeswitch.conf"

# --- Optional sudoers install for Event Guard iptables metrics ---
if [[ "${INSTALL_SUDOERS}" == "1" ]]; then
    echo ""
    echo "Installing sudoers rule for read-only Event Guard iptables metrics..."

    SUDOERS_FILE="/etc/sudoers.d/zabbix-event-guard-iptables"

    cat > "${SUDOERS_FILE}" <<EOF
Cmnd_Alias ZBX_EVENT_GUARD_IPTABLES = \\
    ${IPTABLES} -S sip-auth-ip, \\
    ${IPTABLES} -S sip-auth-fail, \\
    ${IPTABLES} -L sip-auth-ip -n -v -x, \\
    ${IPTABLES} -L sip-auth-fail -n -v -x

${ZABBIX_USER} ALL=(root) NOPASSWD: ZBX_EVENT_GUARD_IPTABLES
Defaults:${ZABBIX_USER} !requiretty
EOF

    chmod 440 "${SUDOERS_FILE}"

    if visudo -cf "${SUDOERS_FILE}" >/dev/null; then
        echo "OK: sudoers file validated: ${SUDOERS_FILE}"
    else
        echo "ERROR: sudoers validation failed. Removing ${SUDOERS_FILE}"
        rm -f "${SUDOERS_FILE}"
        exit 1
    fi
else
    echo ""
    echo "Skipping sudoers install."
    echo "Event Guard iptables metrics require sudoers. To install it:"
    echo "  sudo bash scripts/install.sh --install-sudoers"
fi

# --- Verify fs_cli access as agent user ---
echo ""
echo "Testing FreeSWITCH access as ${ZABBIX_USER}..."
if sudo -u "${ZABBIX_USER}" timeout 5 "${FS_CLI}" -x "status" &>/dev/null; then
    echo "OK: ${ZABBIX_USER} can reach FreeSWITCH."
else
    echo "WARNING: ${ZABBIX_USER} cannot run fs_cli or FreeSWITCH did not respond."
    echo "Possible fix:"
    echo "  usermod -aG freeswitch ${ZABBIX_USER}"
    echo "Then log out/restart the Zabbix agent service."
fi

# --- Smoke tests ---
echo ""
echo "Running metric smoke tests as ${ZABBIX_USER}..."

for TEST_METRIC in \
    ready \
    calls_total \
    registrations \
    sessions_current \
    sessions_per_sec_current \
    event_guard_banned_total_all \
    event_guard_banned_unique_all \
    event_guard_banned_duplicates_all
do
    RESULT="$(sudo -u "${ZABBIX_USER}" "${ZABBIX_SCRIPT_DIR}/freeswitch_metric.sh" "${TEST_METRIC}" 2>/dev/null || echo "ERROR")"

    if [[ "${RESULT}" =~ ^[0-9]+$ ]]; then
        echo "  ${TEST_METRIC}: ${RESULT} (OK)"
    else
        echo "  ${TEST_METRIC}: ${RESULT} (CHECK)"
    fi
done

echo ""
echo "Testing Event Guard discovery..."
DISCOVERY_RESULT="$(sudo -u "${ZABBIX_USER}" "${ZABBIX_SCRIPT_DIR}/freeswitch_metric.sh" event_guard_lld 2>/dev/null || echo "ERROR")"
echo "  event_guard_lld: ${DISCOVERY_RESULT}"

# --- Restart agent ---
if [[ "${RESTART_AGENT}" == "1" ]]; then
    echo ""
    echo "Restarting ${AGENT_SERVICE}..."
    systemctl restart "${AGENT_SERVICE}"
    echo "Agent restarted."
else
    echo ""
    echo "Skipping agent restart. Restart manually with:"
    echo "  systemctl restart ${AGENT_SERVICE}"
fi

echo ""
echo "=== Installation complete ==="
echo ""
echo "Next steps:"
echo "  1. Import/update the Zabbix template"
echo "  2. Assign the template to your FreeSWITCH/FusionPBX hosts"
echo "  3. Restart the Zabbix agent if not already restarted"
echo ""
if command -v "${AGENT_BIN}" >/dev/null 2>&1; then
    echo "Useful tests:"
    echo "  ${AGENT_BIN} -t freeswitch.status.ready"
    echo "  ${AGENT_BIN} -t fusionpbx.event_guard.banned.total.all"
    echo "  ${AGENT_BIN} -t 'fusionpbx.event_guard.banned.unique[sip-auth-ip]'"
fi

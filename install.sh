#!/bin/bash
# =============================================================================
# install.sh - Installs Zabbix FreeSWITCH monitoring UserParameters
#
# Usage:
#   sudo bash install.sh                             # defaults
#   sudo bash install.sh --fs-cli /usr/bin/fs_cli    # custom fs_cli path
#   sudo bash install.sh --restart                   # auto-restart agent
#
# Environment variables (for automation):
#   FS_CLI=/path/to/fs_cli  RESTART_AGENT=1  sudo -E bash install.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Defaults (overridable via env or flags) ---
FS_CLI="${FS_CLI:-/usr/local/freeswitch/bin/fs_cli}"
RESTART_AGENT="${RESTART_AGENT:-0}"

# --- Parse flags ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --fs-cli)   FS_CLI="$2"; shift 2 ;;
        --restart)  RESTART_AGENT=1; shift ;;
        --help)
            echo "Usage: sudo bash install.sh [--fs-cli PATH] [--restart]"
            echo "  Also accepts FS_CLI and RESTART_AGENT environment variables."
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo "=== FreeSWITCH Zabbix Monitor - Installer ==="

# --- Must be root ---
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root (sudo bash install.sh)"
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

# --- Detect Include directory from config ---
ZABBIX_CONF_DIR=$(awk -F= '/^Include=/{print $2}' "${ZABBIX_MAIN_CONF}" | head -1 | sed 's:/\*$::')
if [[ -z "${ZABBIX_CONF_DIR}" || ! -d "${ZABBIX_CONF_DIR}" ]]; then
    echo "ERROR: Could not determine Include directory from ${ZABBIX_MAIN_CONF}"
    echo "Ensure there is an uncommented Include= line in the config."
    exit 1
fi
echo "Include dir:  ${ZABBIX_CONF_DIR}"

# --- Detect Zabbix agent runtime user via systemd ---
ZABBIX_USER=""
if systemctl is-enabled "${AGENT_SERVICE}" >/dev/null 2>&1 || \
   systemctl status "${AGENT_SERVICE}" >/dev/null 2>&1; then
    ZABBIX_USER=$(systemctl show -p User --value "${AGENT_SERVICE}" 2>/dev/null || true)
fi
ZABBIX_USER="${ZABBIX_USER:-zabbix}"
echo "Agent user:   ${ZABBIX_USER}"

# --- Validate fs_cli ---
if [[ ! -x "${FS_CLI}" ]]; then
    echo "ERROR: fs_cli not found or not executable at: ${FS_CLI}"
    echo "Set the correct path:  sudo bash install.sh --fs-cli /path/to/fs_cli"
    exit 1
fi
echo "fs_cli:       ${FS_CLI}"

# --- Install metric script ---
ZABBIX_SCRIPT_DIR="/etc/zabbix/scripts"
echo ""
echo "Installing metric script to ${ZABBIX_SCRIPT_DIR}/..."
mkdir -p "${ZABBIX_SCRIPT_DIR}"
cp "${SCRIPT_DIR}/scripts/freeswitch_metric.sh" "${ZABBIX_SCRIPT_DIR}/"
chown root:"${ZABBIX_USER}" "${ZABBIX_SCRIPT_DIR}/freeswitch_metric.sh"
chmod 750 "${ZABBIX_SCRIPT_DIR}/freeswitch_metric.sh"

# --- Install config file if not present ---
if [[ ! -f /etc/zabbix/freeswitch_monitor.conf ]]; then
    echo "Installing example config to /etc/zabbix/freeswitch_monitor.conf..."
    cp "${SCRIPT_DIR}/conf/freeswitch_monitor.conf.example" /etc/zabbix/freeswitch_monitor.conf
    # Write actual fs_cli path into the config
    sed -i "s|^#FS_CLI=.*|FS_CLI=\"${FS_CLI}\"|" /etc/zabbix/freeswitch_monitor.conf
else
    echo "Config /etc/zabbix/freeswitch_monitor.conf already exists, skipping."
fi

# --- Install UserParameter config ---
echo "Installing UserParameter config to ${ZABBIX_CONF_DIR}/..."
cp "${SCRIPT_DIR}/conf/userparameter_freeswitch.conf" "${ZABBIX_CONF_DIR}/"

# --- Verify fs_cli access as agent user ---
echo ""
echo "Testing fs_cli access as ${ZABBIX_USER}..."
if sudo -u "${ZABBIX_USER}" timeout 5 "${FS_CLI}" -x "status" &>/dev/null; then
    echo "OK: ${ZABBIX_USER} can reach FreeSWITCH."
else
    echo ""
    echo "WARNING: ${ZABBIX_USER} cannot run fs_cli."
    echo "Fix this by adding the user to the freeswitch group:"
    echo "  usermod -aG freeswitch ${ZABBIX_USER}"
    echo ""
    echo "Then ensure the event socket allows local connections"
    echo "(check /etc/freeswitch/autoload_configs/event_socket.conf.xml)."
fi

# --- Run metric smoke tests as agent user ---
echo ""
echo "Running metric smoke tests as ${ZABBIX_USER}..."
SMOKE_PASS=0
SMOKE_FAIL=0
for TEST_METRIC in ready calls_total registrations sessions_current sessions_per_sec_current; do
    RESULT=$(sudo -u "${ZABBIX_USER}" "${ZABBIX_SCRIPT_DIR}/freeswitch_metric.sh" "${TEST_METRIC}" 2>/dev/null || echo "ERROR")
    if [[ "${RESULT}" =~ ^[0-9]+$ ]]; then
        echo "  ${TEST_METRIC}: ${RESULT} (OK)"
        ((SMOKE_PASS++))
    else
        echo "  ${TEST_METRIC}: ${RESULT} (FAIL)"
        ((SMOKE_FAIL++))
    fi
done
echo "Smoke tests: ${SMOKE_PASS} passed, ${SMOKE_FAIL} failed"

# --- Restart agent ---
if [[ "${RESTART_AGENT}" == "1" ]]; then
    echo ""
    echo "Restarting ${AGENT_SERVICE}..."
    systemctl restart "${AGENT_SERVICE}"
    echo "Agent restarted."
else
    echo ""
    echo "Skipping agent restart. Run manually or use --restart flag:"
    echo "  systemctl restart ${AGENT_SERVICE}"
fi

echo ""
echo "=== Installation complete ==="
echo ""
echo "Next steps:"
echo "  1. Import templates/freeswitch_template.yaml into your Zabbix server"
echo "  2. Assign the template to your FreeSWITCH hosts"
if command -v "${AGENT_BIN}" >/dev/null 2>&1; then
    echo "  3. Test: ${AGENT_BIN} -t freeswitch.status.ready"
fi

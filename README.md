# Zabbix FreeSWITCH / FusionPBX Monitor

Monitor FreeSWITCH via Zabbix Agent UserParameters — no SNMP, no mod_snmp, no FreeSWITCH restarts.

Uses `fs_cli` read-only queries to collect metrics with zero impact on active calls.

## Metrics Collected

| Item Key | Description | Interval |
|---|---|---|
| `freeswitch.calls.total` | Total active calls | 30s |
| `freeswitch.calls.inbound` | Inbound call count | 30s |
| `freeswitch.calls.outbound` | Outbound call count | 30s |
| `freeswitch.channels.count` | Active channels | 30s |
| `freeswitch.sessions.current` | Current concurrent sessions | 30s |
| `freeswitch.sessions.peak` | Peak sessions since startup | 60s |
| `freeswitch.sessions.max` | Configured session limit | 5m |
| `freeswitch.sessions_per_sec.current` | Current CPS | 30s |
| `freeswitch.sessions_per_sec.max` | Configured max CPS | 5m |
| `freeswitch.registrations.count` | SIP registration count | 60s |
| `freeswitch.uptime.seconds` | Uptime in seconds (approximate) | 5m |
| `freeswitch.status.ready` | 1 = UP and ready, 0 = DOWN | 30s |
| `freeswitch.gateways.failed` | Approximate count of unhealthy gateways | 60s |

## Triggers

- **DISASTER** — FreeSWITCH is down
- **HIGH** — Failed gateways detected
- **HIGH** — Sessions above 90% capacity
- **WARNING** — CPS above 80% of max
- **WARNING** — FreeSWITCH was restarted (uptime < 5 min)

## Graphs

- Active Calls (total / inbound / outbound)
- Sessions & Channels (current / peak / channels / max)
- SIP Registrations
- Sessions per Second (current / max)

## Requirements

- Zabbix Agent 2 or legacy agent (`zabbix_agentd`) on the FreeSWITCH host
- `fs_cli` accessible to the Zabbix agent user
- FreeSWITCH event socket accepting local connections

## Quick Install

```bash
git clone https://github.com/Henry-Do-Su/fusionpbx_zabbix
cd fusionpbx_zabbix
sudo bash scripts/install.sh
```

The installer will:
1. Auto-detect your Zabbix agent config and `Include=` directory
2. Detect the agent runtime user via systemd
3. Copy the metric script to `/etc/zabbix/scripts/` (root-owned, agent-group-executable)
4. Copy the UserParameter config to the detected include directory
5. Create `/etc/zabbix/freeswitch_monitor.conf` with your fs_cli path
6. Run smoke tests as the agent user
7. Optionally restart the agent

### Installer Options

```bash
# Custom fs_cli path
sudo bash install.sh --fs-cli /usr/bin/fs_cli

# Auto-restart agent after install
sudo bash install.sh --restart

# Environment variables (for Ansible/automation)
sudo FS_CLI=/usr/bin/fs_cli RESTART_AGENT=1 bash install.sh
```

Then import `templates/freeswitch_template.yaml` into your Zabbix server and assign it to your hosts.

## Configuration

The metric script sources `/etc/zabbix/freeswitch_monitor.conf` on each run. Available settings:

```bash
# Path to fs_cli binary
FS_CLI="/usr/local/freeswitch/bin/fs_cli"

# Timeout in seconds for fs_cli commands
FS_TIMEOUT=5
```

An example is provided in `conf/freeswitch_monitor.conf.example`.

## Manual Install

```bash
# Copy files
sudo cp scripts/freeswitch_metric.sh /etc/zabbix/scripts/
sudo chmod 750 /etc/zabbix/scripts/freeswitch_metric.sh
sudo chown root:zabbix /etc/zabbix/scripts/freeswitch_metric.sh

# Create config
sudo cp conf/freeswitch_monitor.conf.example /etc/zabbix/freeswitch_monitor.conf

# Copy UserParameter to your agent's Include directory
sudo cp conf/userparameter_freeswitch.conf /etc/zabbix/zabbix_agent2.d/

# Grant fs_cli access
sudo usermod -aG freeswitch zabbix

# Restart agent
sudo systemctl restart zabbix-agent2
```

## Testing

```bash
# Test via the agent
zabbix_agent2 -t freeswitch.calls.total

# Test the script directly as the agent user (recommended — validates
# permissions, timeout, fs_cli access, and parsing in one shot)
sudo -u zabbix /etc/zabbix/scripts/freeswitch_metric.sh ready
sudo -u zabbix /etc/zabbix/scripts/freeswitch_metric.sh calls_total
sudo -u zabbix /etc/zabbix/scripts/freeswitch_metric.sh registrations
sudo -u zabbix /etc/zabbix/scripts/freeswitch_metric.sh sessions_per_sec_current
```

## Troubleshooting

**"ZBX_NOTSUPPORTED"** — The Zabbix agent user can't run `fs_cli`. Fix:
```bash
sudo usermod -aG freeswitch zabbix
# Verify event_socket.conf.xml allows 127.0.0.1
```

**Timeouts** — If FreeSWITCH is under heavy load:
```bash
# Edit /etc/zabbix/freeswitch_monitor.conf
FS_TIMEOUT=10

# Also set Timeout=15 in your zabbix_agent2.conf
```

**Wrong fs_cli path** — Edit `/etc/zabbix/freeswitch_monitor.conf`.

## Repo Structure

```
├── README.md
├── LICENSE
├── install.sh                              # Automated installer (no interactive prompts)
├── conf/
│   ├── userparameter_freeswitch.conf       # Zabbix UserParameter definitions
│   └── freeswitch_monitor.conf.example     # Example config for fs_cli path & timeout
├── scripts/
│   └── freeswitch_metric.sh                # Metric collection script (called by agent)
└── templates/
    └── freeswitch_template.yaml            # Zabbix template (items, triggers, graphs)
```

## Design Decisions

- **Config file sourcing** — The metric script reads `/etc/zabbix/freeswitch_monitor.conf` for fs_cli path and timeout, keeping configuration separate from code.
- **awk over grep -P** — All parsing uses POSIX awk for portability across distros.
- **Comma stripping** — FreeSWITCH status output contains commas in numbers (`peak 168, last 5min 17`). These are stripped before parsing.
- **Root-owned scripts** — The metric script is owned by root with group-execute for the agent user.
- **No interactive prompts** — The installer accepts flags and environment variables for automation.
- **Config auto-detection** — Reads `Include=` from the actual agent config rather than hardcoding paths.
- **Systemd user detection** — Queries the systemd unit for the runtime user rather than parsing config files.
- **Approximate uptime** — Uses 365-day years. Acceptable since this only drives restart-detection triggers.
- **Approximate gateway count** — Counts UNREGED/FAILED/EXPIRED in `sofia status` output. Rough indicator, not authoritative.

## Template Note

The included YAML template was hand-authored as a starting point for Zabbix 7.0 If it fails to import:
1. Create a minimal template manually in the Zabbix UI
2. Export it as YAML
3. Merge the items, triggers, and graphs from this repo into the exported structure
4. Re-import and commit the corrected version back

## Why UserParameters Instead of SNMP?

- **No mod_snmp** — no extra FreeSWITCH modules to compile or maintain
- **No restarts** — deploy and update without touching running calls
- **Simple** — plain shell, easy to debug and extend
- **Safe** — `fs_cli -x` is read-only; `UnsafeUserParameters` stays disabled

## Contributing

PRs welcome. Planned additions:
- Per-domain/tenant metrics via Zabbix LLD (Low-Level Discovery)
- Gateway-level discovery and per-gateway status
- Codec distribution metrics

## License

MIT

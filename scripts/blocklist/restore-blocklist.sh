#!/usr/bin/env bash
#
# restore-blocklist.sh — Restore ipsets at boot before UFW starts
#
# Runs on boot via blocklist-restore.service. Creates the ipsets if missing
# and loads saved entries from /var/lib/blocklist/. iptables rules referencing
# these sets are managed by UFW (via /etc/ufw/before.rules), so this script
# only handles the ipset state — not firewall rules.
#
# Idempotent: safe to run multiple times.

set -euo pipefail

STATE_DIR="${STATE_DIR:-/var/lib/blocklist}"

# Ipset parameters — must match setup-blocklist.sh. timeout 2592000 (30 days)
# provides automatic cleanup of stale entries; the update script refreshes
# TTLs for IPs/subnets that continue to attack.
IPS_PARAMS="hash:ip family inet hashsize 4096 maxelem 65536 timeout 2592000 comment"
NET_PARAMS="hash:net family inet hashsize 1024 maxelem 8192 timeout 2592000 comment"

restore_set() {
    local name="$1"
    local params="$2"
    local save_file="$STATE_DIR/${name}.save"

    # Create the set if it doesn't exist (fresh boot)
    if ! ipset list "$name" >/dev/null 2>&1; then
        # shellcheck disable=SC2086  # intentional word splitting for params
        ipset create "$name" $params
    fi

    # Restore saved entries. The save file contains a `create` line which
    # we strip — we already created the set above with known parameters.
    # Then entries are added with -exist so conflicts are harmless.
    if [ -s "$save_file" ]; then
        grep -v '^create ' "$save_file" | ipset restore -exist 2>/dev/null || \
            echo "WARNING: partial restore of $name from $save_file" >&2
    fi
}

restore_set abuse-ips "$IPS_PARAMS"
restore_set abuse-subnets "$NET_PARAMS"

ips_count=$(ipset list abuse-ips -terse 2>/dev/null | awk '/Number of entries/{print $4}')
nets_count=$(ipset list abuse-subnets -terse 2>/dev/null | awk '/Number of entries/{print $4}')

echo "Blocklist restored: ${ips_count:-0} IPs, ${nets_count:-0} subnets"

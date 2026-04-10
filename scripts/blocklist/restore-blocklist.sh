#!/usr/bin/env bash
#
# restore-blocklist.sh — Restore ipsets and re-add iptables rules at boot
#
# Runs on boot via blocklist-restore.service. Recreates the ipsets from saved
# state in /var/lib/blocklist/ and adds the iptables DROP rules if missing.
# Idempotent: safe to run multiple times.

set -euo pipefail

STATE_DIR="${STATE_DIR:-/var/lib/blocklist}"

# Create ipsets if missing (they may not exist after reboot)
if ! ipset list abuse-ips >/dev/null 2>&1; then
    ipset create abuse-ips hash:ip family inet hashsize 4096 maxelem 65536 comment
fi

if ! ipset list abuse-subnets >/dev/null 2>&1; then
    ipset create abuse-subnets hash:net family inet hashsize 1024 maxelem 8192 comment
fi

# Restore saved entries
if [ -f "$STATE_DIR/abuse-ips.save" ]; then
    # ipset restore expects a header; save files include it, but we use -exist
    # to handle cases where the set was just created.
    ipset restore -exist < "$STATE_DIR/abuse-ips.save" 2>/dev/null || true
fi

if [ -f "$STATE_DIR/abuse-subnets.save" ]; then
    ipset restore -exist < "$STATE_DIR/abuse-subnets.save" 2>/dev/null || true
fi

# Ensure iptables DROP rules exist
if ! iptables -C INPUT -m set --match-set abuse-ips src -j DROP 2>/dev/null; then
    iptables -I INPUT 1 -m set --match-set abuse-ips src -j DROP
fi

if ! iptables -C INPUT -m set --match-set abuse-subnets src -j DROP 2>/dev/null; then
    iptables -I INPUT 1 -m set --match-set abuse-subnets src -j DROP
fi

echo "Blocklist restored: $(ipset list abuse-ips -terse | grep -c 'Number of entries') ip-entries set, rules applied."

#!/usr/bin/env bash
#
# setup-blocklist.sh — One-time setup for automated IP blocklist
#
# Installs ipset, creates the abuse-ips and abuse-subnets sets, adds iptables
# rules to drop matching packets, configures persistence across reboots, and
# installs the systemd timer that runs update-blocklist.sh hourly.
#
# Run once as root:
#   sudo ./setup-blocklist.sh
#
# Idempotent — safe to run multiple times.

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: must be run as root (use sudo)" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/var/lib/blocklist"
CONFIG_DIR="/etc/blocklist"
INSTALL_DIR="/usr/local/bin"

echo "==> Installing dependencies..."
apt-get update -qq
apt-get install -y ipset

echo "==> Creating state and config directories..."
mkdir -p "$STATE_DIR" "$CONFIG_DIR"
chmod 750 "$STATE_DIR" "$CONFIG_DIR"

echo "==> Creating ipsets..."
# abuse-ips: individual IPs (hash:ip)
if ! ipset list abuse-ips >/dev/null 2>&1; then
    ipset create abuse-ips hash:ip family inet hashsize 4096 maxelem 65536 comment
    echo "    Created abuse-ips"
else
    echo "    abuse-ips already exists"
fi

# abuse-subnets: CIDR ranges (hash:net)
if ! ipset list abuse-subnets >/dev/null 2>&1; then
    ipset create abuse-subnets hash:net family inet hashsize 1024 maxelem 8192 comment
    echo "    Created abuse-subnets"
else
    echo "    abuse-subnets already exists"
fi

echo "==> Adding iptables rules..."
# Rules are inserted at position 1 so they execute before UFW and any other rules.
# Packets matching either set are dropped silently.
if ! iptables -C INPUT -m set --match-set abuse-ips src -j DROP 2>/dev/null; then
    iptables -I INPUT 1 -m set --match-set abuse-ips src -j DROP
    echo "    Added abuse-ips DROP rule"
else
    echo "    abuse-ips DROP rule already present"
fi

if ! iptables -C INPUT -m set --match-set abuse-subnets src -j DROP 2>/dev/null; then
    iptables -I INPUT 1 -m set --match-set abuse-subnets src -j DROP
    echo "    Added abuse-subnets DROP rule"
else
    echo "    abuse-subnets DROP rule already present"
fi

echo "==> Saving initial ipset state..."
ipset save abuse-ips > "$STATE_DIR/abuse-ips.save" 2>/dev/null || true
ipset save abuse-subnets > "$STATE_DIR/abuse-subnets.save" 2>/dev/null || true

echo "==> Installing whitelist..."
WHITELIST_FILE="$CONFIG_DIR/whitelist.conf"
if [ ! -f "$WHITELIST_FILE" ]; then
    cat > "$WHITELIST_FILE" << 'EOF'
# Blocklist whitelist — IPs and subnets that will NEVER be blocked.
# One entry per line. Lines starting with # are comments.
# Supports single IPs (1.2.3.4) and CIDR subnets (1.2.3.0/24).

# Loopback and private ranges (always whitelisted)
127.0.0.0/8
10.0.0.0/8
172.16.0.0/12
192.168.0.0/16

# Add trusted IPs below (e.g. your home/office IP).
# Example:
# 203.0.113.42
EOF
    chmod 640 "$WHITELIST_FILE"
    echo "    Created $WHITELIST_FILE"
    echo ""
    echo "    ⚠️  IMPORTANT: edit $WHITELIST_FILE and add any trusted IPs"
    echo "       before running update-blocklist.sh for the first time."
else
    echo "    Whitelist already exists at $WHITELIST_FILE"
fi

echo "==> Installing scripts..."
install -m 755 "$SCRIPT_DIR/update-blocklist.sh" "$INSTALL_DIR/update-blocklist.sh"
install -m 755 "$SCRIPT_DIR/restore-blocklist.sh" "$INSTALL_DIR/restore-blocklist.sh"

echo "==> Installing systemd units..."
install -m 644 "$SCRIPT_DIR/blocklist.service" /etc/systemd/system/blocklist.service
install -m 644 "$SCRIPT_DIR/blocklist.timer" /etc/systemd/system/blocklist.timer
install -m 644 "$SCRIPT_DIR/blocklist-restore.service" /etc/systemd/system/blocklist-restore.service
systemctl daemon-reload
systemctl enable blocklist-restore.service
systemctl enable --now blocklist.timer

echo "==> Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Edit $WHITELIST_FILE and add your trusted IPs"
echo "  2. Run the first update manually: sudo $INSTALL_DIR/update-blocklist.sh"
echo "  3. Monitor with: sudo ipset list abuse-ips | head -20"
echo "  4. Check timer: systemctl status blocklist.timer"
echo "  5. View logs:   journalctl -u blocklist.service -n 20"

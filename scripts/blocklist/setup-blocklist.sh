#!/usr/bin/env bash
#
# setup-blocklist.sh — One-time setup for automated IP blocklist
#
# Installs ipset, creates the abuse-ips and abuse-subnets sets, adds DROP
# rules to UFW's before.rules (so they survive `ufw reload`), configures the
# boot-time restore service, and installs the hourly update timer.
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
UFW_BEFORE_RULES="/etc/ufw/before.rules"

# Ipset parameters — must match restore-blocklist.sh
IPS_PARAMS="hash:ip family inet hashsize 4096 maxelem 65536 timeout 2592000 comment"
NET_PARAMS="hash:net family inet hashsize 1024 maxelem 8192 timeout 2592000 comment"

MARKER_BEGIN="# BEGIN blocklist (managed by setup-blocklist.sh)"
MARKER_END="# END blocklist"

# --- Dependency check -------------------------------------------------------

if ! command -v ufw >/dev/null 2>&1; then
    echo "ERROR: ufw is not installed. This script requires UFW." >&2
    exit 1
fi

echo "==> Installing ipset..."
apt-get update -qq
apt-get install -y ipset

echo "==> Creating state and config directories..."
mkdir -p "$STATE_DIR" "$CONFIG_DIR"
chmod 750 "$STATE_DIR" "$CONFIG_DIR"
# Ensure the Prometheus textfile collector directory exists
mkdir -p /var/lib/node_exporter/textfile_collector
# Pre-create the log file so systemd ReadWritePaths can reference it
touch /var/log/blocklist-updates.log
chmod 640 /var/log/blocklist-updates.log

echo "==> Creating ipsets..."
# abuse-ips: individual IPs with 30-day TTL (self-cleaning)
if ! ipset list abuse-ips >/dev/null 2>&1; then
    # shellcheck disable=SC2086  # intentional word splitting
    ipset create abuse-ips $IPS_PARAMS
    echo "    Created abuse-ips"
else
    echo "    abuse-ips already exists"
fi

# abuse-subnets: CIDR ranges with 30-day TTL
if ! ipset list abuse-subnets >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    ipset create abuse-subnets $NET_PARAMS
    echo "    Created abuse-subnets"
else
    echo "    abuse-subnets already exists"
fi

echo "==> Adding DROP rules to UFW before.rules..."
# We add rules to UFW's before.rules so they're reapplied on `ufw reload`.
# The marker block makes this idempotent.
if grep -Fq "$MARKER_BEGIN" "$UFW_BEFORE_RULES"; then
    echo "    Blocklist rules already present in $UFW_BEFORE_RULES"
else
    # Back up before modifying
    cp -a "$UFW_BEFORE_RULES" "$UFW_BEFORE_RULES.bak.$(date +%Y%m%d%H%M%S)"

    # Insert our rules into the *filter section, just before the COMMIT line.
    # awk tracks whether we're inside the filter section and only inserts at
    # the matching COMMIT.
    awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" '
    /^\*filter/ { in_filter = 1 }
    /^COMMIT$/ && in_filter && !inserted {
        print begin
        print "# Drop packets from abuse IP blocklist (managed by update-blocklist.sh)"
        print "-A ufw-before-input -m set --match-set abuse-ips src -j DROP"
        print "-A ufw-before-input -m set --match-set abuse-subnets src -j DROP"
        print end
        inserted = 1
        in_filter = 0
    }
    { print }
    ' "$UFW_BEFORE_RULES" > "$UFW_BEFORE_RULES.new"

    # Sanity check: verify the marker was actually inserted
    if ! grep -Fq "$MARKER_BEGIN" "$UFW_BEFORE_RULES.new"; then
        rm -f "$UFW_BEFORE_RULES.new"
        echo "ERROR: failed to insert blocklist rules into $UFW_BEFORE_RULES" >&2
        exit 1
    fi

    mv "$UFW_BEFORE_RULES.new" "$UFW_BEFORE_RULES"
    chown root:root "$UFW_BEFORE_RULES"
    chmod 640 "$UFW_BEFORE_RULES"
    echo "    Added blocklist rules to $UFW_BEFORE_RULES"
fi

echo "==> Reloading UFW to apply rules..."
ufw reload >/dev/null

echo "==> Saving initial ipset state..."
ipset save abuse-ips > "$STATE_DIR/abuse-ips.save"
ipset save abuse-subnets > "$STATE_DIR/abuse-subnets.save"

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
echo "  3. Monitor with: sudo ipset list abuse-ips -terse"
echo "  4. Check timer:  systemctl status blocklist.timer"
echo "  5. View logs:    journalctl -u blocklist.service -n 20"
echo "                   tail -f /var/log/blocklist-updates.log"

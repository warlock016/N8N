#!/usr/bin/env bash
#
# update-blocklist.sh — Scan fail2ban logs and promote repeat offenders
#
# Runs periodically (via systemd timer). Parses fail2ban logs, identifies IPs
# with multiple bans, and adds them to the abuse-ips ipset. Also detects /24
# subnets where multiple distinct IPs are attacking and adds those to the
# abuse-subnets ipset.
#
# Whitelist entries in /etc/blocklist/whitelist.conf are never blocked.
#
# Threshold rationale:
#   IP_BAN_THRESHOLD=3 means an IP must accumulate 3 fail2ban bans before being
#   promoted to the permanent blocklist. Since fail2ban's sshd jail triggers on
#   5 failed attempts, this represents ~15 failed login attempts over multiple
#   ban cycles. Lowering this threshold is aggressive; raising it delays the
#   promotion of clear attackers.

set -euo pipefail

# --- Configuration (override via environment) -------------------------------
IP_BAN_THRESHOLD="${IP_BAN_THRESHOLD:-3}"        # IP with N+ bans → block
SUBNET_IP_THRESHOLD="${SUBNET_IP_THRESHOLD:-3}"  # /24 with N+ distinct IPs → block
FAIL2BAN_LOG="${FAIL2BAN_LOG:-/var/log/fail2ban.log}"
WHITELIST_FILE="${WHITELIST_FILE:-/etc/blocklist/whitelist.conf}"
STATE_DIR="${STATE_DIR:-/var/lib/blocklist}"
METRICS_FILE="${METRICS_FILE:-/var/lib/node_exporter/textfile_collector/blocklist.prom}"
LOG_FILE="${LOG_FILE:-/var/log/blocklist-updates.log}"

# --- Helpers -----------------------------------------------------------------

log() {
    local msg="$1"
    echo "$(date -Iseconds) $msg" | tee -a "$LOG_FILE"
}

# Check if an IP falls within any whitelist entry.
# Values are passed to Python via environment variables to prevent command
# injection through whitelist or log content.
is_whitelisted() {
    local ip="$1"
    local entry
    while IFS= read -r entry; do
        # Strip comments and whitespace
        entry="${entry%%#*}"
        entry="${entry// /}"
        entry="${entry//$'\t'/}"
        [ -z "$entry" ] && continue

        # Exact IP match (fast path, no subprocess)
        if [ "$entry" = "$ip" ]; then
            return 0
        fi

        # CIDR match via python (safe env-var passing, no string interpolation)
        if [[ "$entry" == */* ]]; then
            if WL_IP="$ip" WL_ENTRY="$entry" python3 -c '
import ipaddress, os, sys
try:
    ip = ipaddress.ip_address(os.environ["WL_IP"])
    net = ipaddress.ip_network(os.environ["WL_ENTRY"], strict=False)
    sys.exit(0 if ip in net else 1)
except Exception:
    sys.exit(1)
' 2>/dev/null; then
                return 0
            fi
        fi
    done < "$WHITELIST_FILE"
    return 1
}

# Count entries in an ipset (robust against empty/missing sets).
ipset_count() {
    local set_name="$1"
    local count
    count=$(ipset list "$set_name" -terse 2>/dev/null | awk '/Number of entries/{print $4}') || true
    echo "${count:-0}"
}

# --- Sanity checks -----------------------------------------------------------

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: must be run as root" >&2
    exit 1
fi

if [ ! -f "$FAIL2BAN_LOG" ]; then
    log "ERROR: fail2ban log not found at $FAIL2BAN_LOG"
    exit 1
fi

if [ ! -f "$WHITELIST_FILE" ]; then
    log "ERROR: whitelist not found at $WHITELIST_FILE — run setup-blocklist.sh first"
    exit 1
fi

if ! ipset list abuse-ips >/dev/null 2>&1; then
    log "ERROR: abuse-ips ipset missing — run setup-blocklist.sh first"
    exit 1
fi

mkdir -p "$STATE_DIR" "$(dirname "$METRICS_FILE")"

# --- Lock: prevent concurrent runs -------------------------------------------

LOCK_FILE="$STATE_DIR/.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "Another update is in progress, exiting"
    exit 0
fi

# --- Find repeat offender IPs ------------------------------------------------

log "Starting blocklist update (IP threshold=$IP_BAN_THRESHOLD, subnet threshold=$SUBNET_IP_THRESHOLD)"

added_ips=0
added_subnets=0
skipped_ips=0

# Scan current log plus any rotated logs (.1, .2.gz, etc.)
collect_ban_lines() {
    grep "Ban " "$FAIL2BAN_LOG" 2>/dev/null || true
    for f in "${FAIL2BAN_LOG}".*; do
        [ -f "$f" ] || continue
        if [[ "$f" == *.gz ]]; then
            zgrep "Ban " "$f" 2>/dev/null || true
        else
            grep "Ban " "$f" 2>/dev/null || true
        fi
    done
}

mapfile -t ban_lines < <(collect_ban_lines)

# Extract IP counts (guard against empty array under set -u)
declare -A ip_counts
if [ "${#ban_lines[@]}" -gt 0 ]; then
    for line in "${ban_lines[@]}"; do
        ip=$(echo "$line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
        [ -z "$ip" ] && continue
        ip_counts["$ip"]=$((${ip_counts["$ip"]:-0} + 1))
    done
fi

# Process IPs (guard against empty associative array)
if [ "${#ip_counts[@]}" -gt 0 ]; then
    for ip in "${!ip_counts[@]}"; do
        count="${ip_counts[$ip]}"
        [ "$count" -lt "$IP_BAN_THRESHOLD" ] && continue

        # Refresh TTL if already present, skip counting as "added"
        if ipset test abuse-ips "$ip" 2>/dev/null; then
            ipset add abuse-ips "$ip" -exist 2>/dev/null || true
            continue
        fi

        # Skip if whitelisted
        if is_whitelisted "$ip"; then
            log "SKIP (whitelisted): $ip (bans=$count)"
            skipped_ips=$((skipped_ips + 1))
            continue
        fi

        # Add new entry
        if ipset add abuse-ips "$ip" comment "bans=$count added=$(date -Iseconds)" 2>/dev/null; then
            log "ADD IP: $ip (bans=$count)"
            added_ips=$((added_ips + 1))
        fi
    done
fi

# --- Find abusive subnets ----------------------------------------------------

declare -A subnet_ips

if [ "${#ip_counts[@]}" -gt 0 ]; then
    for ip in "${!ip_counts[@]}"; do
        # Extract /24 prefix (first three octets)
        prefix=$(echo "$ip" | cut -d. -f1-3)
        subnet_ips["$prefix"]="${subnet_ips[$prefix]:-} $ip"
    done
fi

if [ "${#subnet_ips[@]}" -gt 0 ]; then
    for prefix in "${!subnet_ips[@]}"; do
        # Count distinct IPs in this /24 (wc -l is safe under set -e, unlike grep -c)
        distinct=$(echo "${subnet_ips[$prefix]}" | tr ' ' '\n' | awk 'NF' | sort -u | wc -l)
        [ "$distinct" -lt "$SUBNET_IP_THRESHOLD" ] && continue

        subnet="${prefix}.0/24"

        # Refresh TTL if already present
        if ipset test abuse-subnets "$subnet" 2>/dev/null; then
            ipset add abuse-subnets "$subnet" -exist 2>/dev/null || true
            continue
        fi

        # Skip if whitelisted (check any IP in the subnet)
        first_ip=$(echo "${subnet_ips[$prefix]}" | awk '{print $1}')
        if is_whitelisted "$first_ip"; then
            log "SKIP subnet (whitelisted): $subnet"
            continue
        fi

        if ipset add abuse-subnets "$subnet" comment "distinct_ips=$distinct added=$(date -Iseconds)" 2>/dev/null; then
            log "ADD SUBNET: $subnet (distinct_ips=$distinct)"
            added_subnets=$((added_subnets + 1))
        fi
    done
fi

# --- Persist state -----------------------------------------------------------

ipset save abuse-ips > "$STATE_DIR/abuse-ips.save" 2>/dev/null || true
ipset save abuse-subnets > "$STATE_DIR/abuse-subnets.save" 2>/dev/null || true

# --- Export metrics ----------------------------------------------------------

total_ips=$(ipset_count abuse-ips)
total_subnets=$(ipset_count abuse-subnets)
now=$(date +%s)

cat > "$METRICS_FILE.tmp" << EOF
# HELP blocklist_ips_total Current number of IPs in the abuse-ips blocklist
# TYPE blocklist_ips_total gauge
blocklist_ips_total $total_ips

# HELP blocklist_subnets_total Current number of subnets in the abuse-subnets blocklist
# TYPE blocklist_subnets_total gauge
blocklist_subnets_total $total_subnets

# HELP blocklist_last_update_timestamp Unix timestamp of the last blocklist update
# TYPE blocklist_last_update_timestamp gauge
blocklist_last_update_timestamp $now

# HELP blocklist_ips_added_last_run Number of IPs added in the most recent update run
# TYPE blocklist_ips_added_last_run gauge
blocklist_ips_added_last_run $added_ips

# HELP blocklist_subnets_added_last_run Number of subnets added in the most recent update run
# TYPE blocklist_subnets_added_last_run gauge
blocklist_subnets_added_last_run $added_subnets
EOF
mv "$METRICS_FILE.tmp" "$METRICS_FILE"

log "Update complete: added ips=$added_ips subnets=$added_subnets skipped=$skipped_ips total_ips=$total_ips total_subnets=$total_subnets"

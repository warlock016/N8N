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
#   IP_BAN_THRESHOLD=3 means an IP must accumulate 3 "Ban" events in
#   fail2ban.log before promotion. This counts Ban lines from any jail
#   (sshd, recidive, recidive-permanent). A single attacker banned once by
#   sshd and then escalated by both recidive jails produces 3 Ban lines,
#   reaching threshold quickly — which is appropriate, because recidive
#   escalation is itself a strong signal that the IP is a persistent
#   offender worth permanent blocking.
#
#   The floor is roughly:
#     - 5 failed SSH attempts (triggers sshd ban)         →  1 Ban line
#     - +2 more ban cycles OR recidive escalation          → +2 Ban lines
#   So 3 counts means clear repeat offender, not transient noise.

set -euo pipefail

# --- Configuration (override via environment) -------------------------------
IP_BAN_THRESHOLD="${IP_BAN_THRESHOLD:-3}"        # IP with N+ bans → block
SUBNET_IP_THRESHOLD="${SUBNET_IP_THRESHOLD:-5}"  # /24 with N+ distinct IPs → block
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

# Validate the whitelist file once at startup. Logs warnings for any
# malformed lines so a typo doesn't silently leave a "trusted" IP unprotected.
validate_whitelist() {
    local warnings
    warnings=$(WL_PATH="$WHITELIST_FILE" python3 -c '
import ipaddress, os, sys
path = os.environ["WL_PATH"]
with open(path) as f:
    for i, raw in enumerate(f, 1):
        entry = raw.split("#", 1)[0].strip()
        if not entry:
            continue
        try:
            if "/" in entry:
                ipaddress.ip_network(entry, strict=False)
            else:
                ipaddress.ip_address(entry)
        except Exception as e:
            print(f"line {i}: {entry!r} ({e})", file=sys.stderr)
' 2>&1 >/dev/null) || true

    if [ -n "$warnings" ]; then
        while IFS= read -r w; do
            [ -z "$w" ] && continue
            log "WARNING: malformed whitelist $w"
        done <<< "$warnings"
    fi
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

# --- Lock: prevent concurrent runs (acquired before any logging) ------------

LOCK_FILE="$STATE_DIR/.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    # Log to stderr only — don't risk a race on the shared log file
    echo "$(date -Iseconds) Another update is in progress, exiting" >&2
    exit 0
fi

# --- Validate whitelist and log any issues ----------------------------------

validate_whitelist

# --- Find repeat offender IPs ------------------------------------------------

log "Starting blocklist update (IP threshold=$IP_BAN_THRESHOLD, subnet threshold=$SUBNET_IP_THRESHOLD)"

added_ips=0
added_subnets=0
skipped_ips=0

# Scan current log plus any rotated logs (.1, .2.gz, etc.)
# Note: "Ban " (capital B) doesn't match "Unban" (lowercase b after U).
collect_ban_lines() {
    local f
    grep "Ban " "$FAIL2BAN_LOG" 2>/dev/null || true
    shopt -s nullglob
    for f in "${FAIL2BAN_LOG}".*; do
        if [[ "$f" == *.gz ]]; then
            zgrep "Ban " "$f" 2>/dev/null || true
        else
            grep "Ban " "$f" 2>/dev/null || true
        fi
    done
    shopt -u nullglob
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

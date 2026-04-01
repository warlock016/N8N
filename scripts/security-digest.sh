#!/bin/bash
# security-digest.sh
# Generates a JSON security digest for N8N webhook consumption.
# Can be called via cron or N8N Execute Command node.
#
# Output: JSON to stdout

set -euo pipefail

# fail2ban status
f2b_running=false
sshd_banned=0
sshd_total_banned=0
recidive_banned=0
banned_ips=""

if fail2ban-client ping > /dev/null 2>&1; then
  f2b_running=true

  sshd_status=$(fail2ban-client status sshd 2>/dev/null || echo "")
  if [ -n "$sshd_status" ]; then
    sshd_banned=$(echo "$sshd_status" | grep "Currently banned:" | awk '{print $NF}')
    sshd_total_banned=$(echo "$sshd_status" | grep "Total banned:" | awk '{print $NF}')
    banned_ips=$(echo "$sshd_status" | grep "Banned IP list:" | sed 's/.*Banned IP list://' | xargs)
  fi

  recidive_status=$(fail2ban-client status recidive 2>/dev/null || echo "")
  if [ -n "$recidive_status" ]; then
    recidive_banned=$(echo "$recidive_status" | grep "Currently banned:" | awk '{print $NF}')
  fi
fi

# SSH attack metrics from auth.log
ssh_failures_24h=0
unique_attackers_24h=0
top_attackers=""
top_usernames=""

if [ -f /var/log/auth.log ]; then
  twenty_four_h_ago=$(date -d '24 hours ago' '+%Y-%m-%dT%H:%M' 2>/dev/null || date -v-24H '+%Y-%m-%dT%H:%M')

  ssh_failures_24h=$(awk -v since="$twenty_four_h_ago" \
    '$0 >= since && (/Invalid user/ || /Connection closed.*preauth/ || /Failed password/) {count++} END {print count+0}' \
    /var/log/auth.log)

  unique_attackers_24h=$(awk -v since="$twenty_four_h_ago" \
    '$0 >= since && (/Invalid user/ || /Failed password/) {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) ips[$i]++} END {for(ip in ips) count++; print count+0}' \
    /var/log/auth.log)

  top_attackers=$(awk -v since="$twenty_four_h_ago" \
    '$0 >= since && (/Invalid user/ || /Failed password/ || /Connection closed.*preauth/) {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) ips[$i]++} END {for(ip in ips) print ips[ip], ip}' \
    /var/log/auth.log | sort -rn | head -5 | awk '{printf "%s (%s attempts), ", $2, $1}' | sed 's/, $//')

  top_usernames=$(awk -v since="$twenty_four_h_ago" \
    '$0 >= since && /Invalid user/ {for(i=1;i<=NF;i++) if($i == "user") users[$(i+1)]++} END {for(u in users) print users[u], u}' \
    /var/log/auth.log | sort -rn | head -5 | awk '{printf "%s (%s), ", $2, $1}' | sed 's/, $//')
fi

# Bans in last 24h from fail2ban log
bans_24h=0
if [ -f /var/log/fail2ban.log ]; then
  twenty_four_h_ago_f2b=$(date -d '24 hours ago' '+%Y-%m-%d %H:%M' 2>/dev/null || date -v-24H '+%Y-%m-%d %H:%M')
  bans_24h=$(awk -v since="$twenty_four_h_ago_f2b" '$0 >= since && /\] Ban / {count++} END {print count+0}' /var/log/fail2ban.log)
fi

# Docker container status
containers_total=$(docker ps -q | wc -l)
containers_healthy=$(docker ps --filter "health=healthy" -q | wc -l)
containers_unhealthy=$(docker ps --filter "health=unhealthy" -q 2>/dev/null | wc -l)

# System resources
disk_usage=$(df / --output=pcent 2>/dev/null | tail -1 | tr -d ' %' || echo "0")
memory_usage=$(free | awk '/Mem:/ {printf "%.0f", $3/$2 * 100}')
load_avg=$(cat /proc/loadavg | awk '{print $1}')

# Output JSON
cat << ENDJSON
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "fail2ban": {
    "running": $f2b_running,
    "sshd_currently_banned": ${sshd_banned:-0},
    "sshd_total_banned": ${sshd_total_banned:-0},
    "recidive_banned": ${recidive_banned:-0},
    "bans_last_24h": $bans_24h,
    "banned_ips": "$banned_ips"
  },
  "ssh_attacks": {
    "failures_last_24h": $ssh_failures_24h,
    "unique_attackers_24h": $unique_attackers_24h,
    "top_attackers": "$top_attackers",
    "top_usernames_tried": "$top_usernames"
  },
  "system": {
    "containers_total": $containers_total,
    "containers_healthy": $containers_healthy,
    "containers_unhealthy": $containers_unhealthy,
    "disk_usage_percent": $disk_usage,
    "memory_usage_percent": $memory_usage,
    "load_average": $load_avg
  }
}
ENDJSON

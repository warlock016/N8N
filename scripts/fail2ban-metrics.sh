#!/bin/bash
# fail2ban-metrics.sh
# Writes fail2ban metrics in Prometheus textfile collector format.
# Intended to run via cron every minute.
#
# Output: /var/lib/node_exporter/textfile_collector/fail2ban.prom

set -euo pipefail

OUTPUT_DIR="/var/lib/node_exporter/textfile_collector"
OUTPUT_FILE="$OUTPUT_DIR/fail2ban.prom"
TEMP_FILE="$OUTPUT_FILE.tmp"

mkdir -p "$OUTPUT_DIR"

# Collect fail2ban metrics
{
  echo "# HELP fail2ban_banned_total Total number of currently banned IPs per jail"
  echo "# TYPE fail2ban_banned_total gauge"

  echo "# HELP fail2ban_failed_total Total number of failed attempts detected per jail"
  echo "# TYPE fail2ban_failed_total gauge"

  echo "# HELP fail2ban_bans_total Cumulative number of bans per jail (from log)"
  echo "# TYPE fail2ban_bans_total counter"

  echo "# HELP fail2ban_up Whether fail2ban is running"
  echo "# TYPE fail2ban_up gauge"

  # Check if fail2ban is running
  if ! fail2ban-client ping > /dev/null 2>&1; then
    echo 'fail2ban_up 0'
    # Write empty metrics
    echo 'fail2ban_banned_total{jail="sshd"} 0'
    echo 'fail2ban_failed_total{jail="sshd"} 0'
  else
    echo 'fail2ban_up 1'

    # Get jail list
    jails=$(fail2ban-client status | grep "Jail list:" | sed 's/.*://;s/,/ /g;s/^[ \t]*//')

    for jail in $jails; do
      status=$(fail2ban-client status "$jail" 2>/dev/null || echo "")
      if [ -n "$status" ]; then
        banned=$(echo "$status" | grep "Currently banned:" | awk '{print $NF}')
        failed=$(echo "$status" | grep "Currently failed:" | awk '{print $NF}')
        total_banned=$(echo "$status" | grep "Total banned:" | awk '{print $NF}')

        echo "fail2ban_banned_total{jail=\"$jail\"} ${banned:-0}"
        echo "fail2ban_failed_total{jail=\"$jail\"} ${failed:-0}"
        echo "fail2ban_bans_total{jail=\"$jail\"} ${total_banned:-0}"
      fi
    done
  fi

  # Parse recent ban events from log (last hour)
  echo "# HELP fail2ban_recent_bans Number of ban events in the last hour"
  echo "# TYPE fail2ban_recent_bans gauge"

  if [ -f /var/log/fail2ban.log ]; then
    one_hour_ago=$(date -d '1 hour ago' '+%Y-%m-%d %H:%M' 2>/dev/null || date -v-1H '+%Y-%m-%d %H:%M')
    recent_bans=$(awk -v since="$one_hour_ago" '$0 >= since && /Ban / {count++} END {print count+0}' /var/log/fail2ban.log)
    echo "fail2ban_recent_bans $recent_bans"
  else
    echo "fail2ban_recent_bans 0"
  fi

  # Top attacking IPs (currently banned)
  echo "# HELP fail2ban_banned_ip Currently banned IPs with jail label"
  echo "# TYPE fail2ban_banned_ip gauge"

  for jail in $jails; do
    banned_ips=$(fail2ban-client status "$jail" 2>/dev/null | grep "Banned IP list:" | sed 's/.*Banned IP list://' | tr -s ' ')
    for ip in $banned_ips; do
      [ -n "$ip" ] && echo "fail2ban_banned_ip{jail=\"$jail\",ip=\"$ip\"} 1"
    done
  done

  # Auth log metrics (failed SSH attempts in last hour)
  echo "# HELP ssh_failed_attempts_last_hour SSH authentication failures in the last hour"
  echo "# TYPE ssh_failed_attempts_last_hour gauge"

  if [ -f /var/log/auth.log ]; then
    one_hour_ago=$(date -d '1 hour ago' '+%Y-%m-%dT%H:%M' 2>/dev/null || date -v-1H '+%Y-%m-%dT%H:%M')
    ssh_failures=$(awk -v since="$one_hour_ago" '$0 >= since && (/Invalid user/ || /Connection closed.*preauth/ || /Failed password/) {count++} END {print count+0}' /var/log/auth.log)
    echo "ssh_failed_attempts_last_hour $ssh_failures"
  else
    echo "ssh_failed_attempts_last_hour 0"
  fi

  # Unique attacking IPs in last hour
  echo "# HELP ssh_unique_attackers_last_hour Unique IPs with failed SSH attempts in the last hour"
  echo "# TYPE ssh_unique_attackers_last_hour gauge"

  if [ -f /var/log/auth.log ]; then
    unique_attackers=$(awk -v since="$one_hour_ago" '$0 >= since && (/Invalid user/ || /Failed password/) {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) ips[$i]=1} END {for(ip in ips) count++; print count+0}' /var/log/auth.log)
    echo "ssh_unique_attackers_last_hour $unique_attackers"
  else
    echo "ssh_unique_attackers_last_hour 0"
  fi

} > "$TEMP_FILE"

# Atomic rename
mv "$TEMP_FILE" "$OUTPUT_FILE"

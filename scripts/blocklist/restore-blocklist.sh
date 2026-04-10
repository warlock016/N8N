#!/usr/bin/env bash
#
# restore-blocklist.sh — Restore ipsets at boot before UFW starts
#
# Runs on boot via blocklist-restore.service. Creates the ipsets (even if
# empty) and loads saved entries from /var/lib/blocklist/. iptables rules
# referencing these sets are managed by UFW (via /etc/ufw/before.rules).
#
# Invariant: at exit, both ipsets must exist (even empty) so UFW can load
# its rules. If set creation fails, exit non-zero so systemd marks the
# restore service failed and (via drop-in) blocks UFW from starting in a
# degraded state.
#
# Idempotent: safe to run multiple times.

# Deliberately NOT set -e. Partial restores should log and continue; only
# a total failure to create the sets should be fatal.
set -uo pipefail

STATE_DIR="${STATE_DIR:-/var/lib/blocklist}"

# Ipset parameters — must match setup-blocklist.sh.
# timeout 2073600 = 24 days (ipset 7.19 on Ubuntu 24.04 caps per-entry
# timeouts at ~24.9 days despite docs suggesting higher; 30 days exceeds
# this limit with "out of range 0-2147483"). The updater refreshes TTLs
# on every run for IPs that continue to attack, so 24-day TTL is ample.
IPS_PARAMS="hash:ip family inet hashsize 4096 maxelem 65536 timeout 2073600 comment"
NET_PARAMS="hash:net family inet hashsize 1024 maxelem 8192 timeout 2073600 comment"

log_info()  { logger -t blocklist-restore "$*"; echo "$*"; }
log_warn()  { logger -t blocklist-restore -p warning "$*"; echo "WARNING: $*" >&2; }
log_error() { logger -t blocklist-restore -p err "$*"; echo "ERROR: $*" >&2; }

if ! command -v ipset >/dev/null 2>&1; then
    log_error "ipset binary not found — cannot restore blocklist"
    exit 1
fi

restore_set() {
    local name="$1" params="$2"
    local save_file="$STATE_DIR/${name}.save"

    # Create the set if missing (fresh boot)
    if ! ipset list "$name" >/dev/null 2>&1; then
        # shellcheck disable=SC2086  # intentional word splitting for params
        if ! ipset create "$name" $params 2>/dev/null; then
            log_error "failed to create ipset $name"
            return 1
        fi
    fi

    # Restore saved entries. The save file contains a `create` line that
    # we strip — the set was just created above. Entries are added with
    # -exist so a partial/corrupt save file at worst loses some entries;
    # the next update run will rebuild them from fail2ban logs.
    if [ -s "$save_file" ]; then
        if ! grep -v '^create ' "$save_file" | ipset restore -exist 2>/dev/null; then
            log_warn "partial restore of $name from $save_file (continuing with what loaded)"
        fi
    fi

    return 0
}

restore_set abuse-ips "$IPS_PARAMS"
ips_rc=$?
restore_set abuse-subnets "$NET_PARAMS"
nets_rc=$?

# Verify the invariant: both sets must exist for UFW to load its rules
if ! ipset list abuse-ips >/dev/null 2>&1 || ! ipset list abuse-subnets >/dev/null 2>&1; then
    log_error "one or more blocklist sets missing after restore — UFW will fail to apply rules"
    exit 1
fi

ips_count=$(ipset list abuse-ips -terse 2>/dev/null | awk '/Number of entries/{print $4}')
nets_count=$(ipset list abuse-subnets -terse 2>/dev/null | awk '/Number of entries/{print $4}')

if [ "$ips_rc" -eq 0 ] && [ "$nets_rc" -eq 0 ]; then
    log_info "Blocklist restored: ${ips_count:-0} IPs, ${nets_count:-0} subnets"
else
    log_warn "Blocklist restored with warnings: ${ips_count:-0} IPs, ${nets_count:-0} subnets"
fi

exit 0

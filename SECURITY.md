# Security Guidelines

## Overview

This document outlines the security posture, known gaps, and remediation plan for the N8N deployment infrastructure. It covers VPS access control, secrets management, container security, network exposure, and operational hardening.

Last audited: 2026-04-02 (all findings resolved)

---

## Security Audit Summary

### Critical Findings

| # | Finding | Status |
|---|---------|--------|
| C1 | All CI/CD and manual access uses `root` SSH — no privilege separation | Resolved — deployer + automat users created, root SSH disabled |
| C2 | Hardcoded Cloudflare tunnel ID in source-controlled files | Resolved — switched to token-based auth |
| C3 | `.env` contains live Cloudflare credentials (token, tunnel secret, account tag) | Resolved — old credentials rotated, new tunnel created |

### High Findings

| # | Finding | Status |
|---|---------|--------|
| H1 | SSH private key written to CI runner disk without cleanup | Resolved — `if: always()` cleanup step added to all workflows |
| H2 | CloudFlared metrics bound to `0.0.0.0:2000` (all interfaces) | Resolved — container has no host ports; only reachable within Docker network |
| H3 | CloudFlared running with `--loglevel debug` in production | Resolved — removed debug flag |
| H4 | Ollama CORS set to `*` (accepts any origin) | Resolved — restricted to internal consumers |
| H5 | Traefik dashboard exposed without authentication | Resolved — basic auth middleware added (defense-in-depth with Cloudflare Access) |
| H6 | Grafana admin password defaults to `admin` if env var unset | Resolved — strong password set via env var |
| H7 | Docker socket mounted directly to Traefik container | Resolved — replaced with tecnativa/docker-socket-proxy |

### Medium Findings

| # | Finding | Status |
|---|---------|--------|
| M1 | cAdvisor runs with `SYS_ADMIN` capability and `apparmor:unconfined` | Accepted risk — required by cAdvisor for cgroup/filesystem metrics |
| M2 | No resource limits on Ollama, Traefik, CloudFlared, Grafana, Prometheus | Resolved — limits added to all containers |
| M3 | Metrics basic auth hash hardcoded in compose file | Resolved — moved to `${METRICS_AUTH}` env var |
| M4 | PostgreSQL passwords passed as env vars (visible via `docker inspect`) | Accepted risk — mitigated with `chmod 600` on compose files; Docker secrets adds complexity for single-host |
| M5 | No rate limiting configured on any Traefik route | Resolved — global rate-limit middleware (100 req/s, 200 burst) with IP strategy |
| M6 | No fail2ban or SSH brute-force protection on VPS | Resolved — fail2ban installed with sshd + recidive jails |
| M7 | No centralized log aggregation | Resolved — Loki + Promtail added to monitoring stack |
| M8 | Backup files created without explicit file permissions | Resolved — explicit `chmod 600/700` after backup creation |
| M9 | Host cert mounted from `/root/.cloudflared/cert.pem` | Resolved — eliminated by token-based auth migration |

---

## VPS Access Model

### Principle

Separate automated deployment access from interactive admin access. Never use `root` directly over SSH.

### User Accounts

#### `deployer` — CI/CD service account

Purpose: Automated deployments via GitHub Actions. Restricted to only the commands needed to deploy and manage Docker services.

```bash
# Create the user
useradd -m -s /bin/bash deployer
mkdir -p /home/deployer/.ssh
chmod 700 /home/deployer/.ssh

# Add the CI/CD public key (generate a NEW keypair for this user)
echo "<deployer-public-key>" > /home/deployer/.ssh/authorized_keys
chown -R deployer:deployer /home/deployer/.ssh
chmod 600 /home/deployer/.ssh/authorized_keys

# Grant scoped sudo permissions
cat > /etc/sudoers.d/deployer << 'SUDOEOF'
# Docker operations
deployer ALL=(root) NOPASSWD: /usr/bin/docker
deployer ALL=(root) NOPASSWD: /usr/bin/docker compose *

# Deployment directory management
deployer ALL=(root) NOPASSWD: /bin/mkdir -p /opt/n8n-*
deployer ALL=(root) NOPASSWD: /bin/ln -sfn /opt/n8n-*/releases/* /opt/n8n-*/current
deployer ALL=(root) NOPASSWD: /bin/tar -xzf /tmp/deployment.tar.gz *
deployer ALL=(root) NOPASSWD: /bin/chown -R deployer\:deployer /opt/n8n-*
deployer ALL=(root) NOPASSWD: /bin/rm -rf /opt/n8n-*/releases/*

# Service management
deployer ALL=(root) NOPASSWD: /bin/systemctl restart docker
deployer ALL=(root) NOPASSWD: /usr/bin/ufw status
SUDOEOF
chmod 440 /etc/sudoers.d/deployer

# Transfer ownership of deployment directories
chown -R deployer:deployer /opt/n8n-v2
chown -R deployer:deployer /opt/n8n-production 2>/dev/null || true
```

#### Personal admin account — interactive SSH access

Purpose: Manual administration, troubleshooting, general-purpose tasks. Has full sudo privileges but requires your personal SSH key and password for sudo.

```bash
# Create your personal admin user
useradd -m -s /bin/bash <your-username> -G sudo
passwd <your-username>

# Add your personal SSH public key
mkdir -p /home/<your-username>/.ssh
echo "<your-personal-public-key>" > /home/<your-username>/.ssh/authorized_keys
chown -R <your-username>:<your-username> /home/<your-username>/.ssh
chmod 700 /home/<your-username>/.ssh
chmod 600 /home/<your-username>/.ssh/authorized_keys
```

With this account you can run `sudo -i` to get a root shell when needed. The difference from logging in as root directly:
- SSH logs show your username, not just "root"
- If your key is compromised, the attacker still needs your sudo password
- You can disable this account independently without affecting deployments

#### Disable root SSH and password authentication

After both accounts are verified working:

```bash
# /etc/ssh/sshd_config
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no

systemctl restart ssh
```

**Important**: Test SSH access with your personal account in a separate terminal BEFORE closing your current root session.

**Note**: With `PasswordAuthentication no`, SSH brute-force attacks are immediately rejected without allowing password attempts. This eliminates the attack surface entirely — attackers need a valid private key to even begin authentication.

---

## GitHub Secrets Management

### Required Secrets

| Secret | Purpose | Format | Rotation |
|--------|---------|--------|----------|
| `VPS_SSH_KEY` | SSH private key for `deployer` user (NOT root) | PEM key | Quarterly or on suspicion |
| `PRODUCTION_VPS_HOST` | Production VPS hostname/IP | Hostname/IP | On infrastructure change |
| `STAGING_VPS_HOST` | Staging VPS hostname/IP (optional) | Hostname/IP | On infrastructure change |
| `CLOUDFLARE_TUNNEL_TOKEN` | Tunnel token (replaces credentials JSON + tunnel ID) | JWT token | Quarterly or on suspicion |
| `CLOUDFLARE_API_TOKEN` | API token with DNS:Edit permissions only | Token string | Quarterly or on suspicion |
| `DOMAIN_NAME` | Primary domain name | Domain string | On domain change |
| `TRAEFIK_DASHBOARD_AUTH` | Traefik dashboard basic auth | Raw bcrypt hash (single `$`) | Quarterly |
| `METRICS_AUTH` | Traefik metrics endpoint basic auth | Raw bcrypt hash (single `$`) | Quarterly |
| `SLACK_WEBHOOK_URL` | Notification webhook (optional) | URL | On rotation |
| `DISCORD_WEBHOOK_URL` | Notification webhook (optional) | URL | On rotation |

**Important**: `TRAEFIK_DASHBOARD_AUTH` and `METRICS_AUTH` must be stored with **single `$` signs** (raw `htpasswd -nB` output). The deploy workflow automatically doubles them for Docker Compose. Do NOT store pre-doubled `$$` values.

### Setting up Secrets

1. Navigate to your GitHub repository
2. Go to Settings > Secrets and variables > Actions
3. Click "New repository secret"
4. Add each required secret with the appropriate value

---

## Credential Rotation

### When to Rotate

Rotate credentials immediately if:
- Credentials are accidentally exposed in code, logs, or conversation context
- A team member with access leaves the organization
- Suspicious activity is detected
- As part of regular security maintenance (quarterly recommended)

### Cloudflare Credential Rotation

**Tunnel token** (replaces old credentials JSON + tunnel ID + tunnel secret):

1. Log into Cloudflare Zero Trust dashboard: https://one.dash.cloudflare.com/
2. Go to Networks > Tunnels
3. Delete the existing tunnel (or create a new one alongside for zero-downtime rotation)
4. Create a new tunnel > name it > choose "cloudflared"
5. Copy the tunnel token from the provided docker command
6. Update GitHub secret: `CLOUDFLARE_TUNNEL_TOKEN`
7. Update local `.env` with the new token (never commit this file)
8. Deploy to verify the new tunnel connects
9. Delete the old tunnel if it still exists

**API token** (for DNS management scripts):

1. Go to https://dash.cloudflare.com/profile/api-tokens
2. Create Token > use "Edit zone DNS" template (scope to your zone only)
3. Update GitHub secret: `CLOUDFLARE_API_TOKEN`
4. Test DNS scripts to verify functionality
5. Delete the old token from the same page

**Note**: `ACCOUNT_TAG` is your Cloudflare account identifier (not a secret, not rotatable). It is safe to keep in configuration but should not be in source-controlled files.

### SSH Key Rotation

1. Generate a new keypair: `ssh-keygen -t ed25519 -C "deployer@github-actions"`
2. Add the new public key to `deployer`'s `authorized_keys` on VPS
3. Update the `VPS_SSH_KEY` GitHub secret with the new private key
4. Test a deployment
5. Remove the old public key from `authorized_keys`

### Post-Rotation Verification

After any rotation, trigger a deployment (staging first) and verify:
- CloudFlare tunnel connects successfully
- DNS records resolve correctly
- All services pass health checks
- Monitoring stack reports healthy

---

## File Security

### Excluded Files

The following files are excluded from git tracking via `.gitignore`:

- `edge/cloudflared/*.json` — Tunnel credential files
- `.env` and `*.env` — Environment files with secrets
- `*.pem`, `*.key`, `*.crt` — Certificate and key files
- `*.sqlite`, `*.sqlite3` — Database files

### Never Commit

**NEVER** commit the following to the repository:
- API tokens or keys
- SSH private keys
- Database passwords
- SSL/TLS certificates or private keys
- Tunnel credential JSON files
- Any file containing sensitive credentials

### Verifying Git History

Periodically verify no secrets have entered git history:

```bash
# Check if .env was ever committed
git log --all -p -- .env

# Search for known secret patterns
git log --all -S "CLOUDFLARE_TOKEN" --oneline
git log --all -S "TUNNEL_SECRET" --oneline
```

If secrets are found in history, use `git filter-repo` to purge them and force-push.

---

## Container & Service Security

### Network Architecture

| Network | Purpose | External Access |
|---------|---------|-----------------|
| `edge` | Traefik + CloudFlared reverse proxy | Via Cloudflare tunnel only |
| `ai-internal` | Ollama, Qdrant, PostgreSQL | None (internal only) |
| `monitoring` | Prometheus, Grafana, AlertManager | Via Cloudflare tunnel only |

All external traffic is routed through the Cloudflare tunnel. No ports are exposed directly on the VPS host.

### Container Hardening Checklist

- [x] **CloudFlared**: Metrics on `0.0.0.0:2000` — safe (no host ports, only reachable within Docker network)
- [x] **CloudFlared**: Set `--loglevel info` (not `debug`)
- [x] **Ollama**: Restrict `OLLAMA_ORIGINS` to known consumers (not `*`)
- [x] **Traefik**: Add authentication middleware to dashboard route
- [x] **Traefik**: Use a Docker socket proxy instead of direct socket mount
- [x] **Grafana**: Remove default password fallback (`:-admin`)
- [x] **All services**: Add `deploy.resources.limits` for memory and CPU
- [x] **Compose**: Switched to token-based auth (no more credentials JSON or tunnel ID in compose)

### Resource Limits

All containers have explicit resource limits:

| Container | Memory | CPUs |
|-----------|--------|------|
| Traefik | 256M | 0.5 |
| CloudFlared | 256M | 0.3 |
| Docker Socket Proxy | 128M | 0.2 |
| Prometheus | 1G | 0.5 |
| Grafana | 512M | 0.5 |
| AlertManager | 128M | 0.2 |
| Loki | 512M | 0.5 |
| Promtail | 256M | 0.3 |
| Node Exporter | 128M | 0.2 |
| cAdvisor | 256M | 0.3 |
| N8N (template) | 1G | 1.0 |
| PostgreSQL (template) | 512M | 0.5 |
| Ollama (template) | 8G | 4.0 |
| Qdrant (template) | 2G | 1.0 |
| Generic App (template) | 512M | 0.5 |

---

## VPS Hardening

### Firewall

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow from <TRUSTED_IP>/32 to any port 22 proto tcp  # SSH from known IPs
ufw deny 80
ufw deny 443
ufw enable
```

All HTTP/HTTPS traffic reaches services exclusively via the Cloudflare tunnel (which originates outbound connections from the VPS), so ports 80/443 do not need to be open.

### fail2ban

Three-tier ban escalation: initial 24h ban, 30-day ban for repeat offenders, permanent ban for persistent attackers.

```bash
apt install fail2ban
systemctl enable fail2ban

# /etc/fail2ban/jail.local
cat > /etc/fail2ban/jail.local << 'EOF'
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 86400       # 24 hours
findtime = 600        # 10 minute window

[recidive]
enabled = true
logpath = /var/log/fail2ban.log
banaction = %(banaction_allports)s
# 30-day ban if banned 3+ times within 7 days
maxretry = 3
bantime = 2592000     # 30 days
findtime = 604800     # 7 day window

[recidive-permanent]
enabled = true
logpath = /var/log/fail2ban.log
banaction = %(banaction_allports)s
# Permanent ban if banned 5+ times within 30 days
maxretry = 5
bantime = -1          # permanent
findtime = 2592000    # 30 day window
EOF

systemctl restart fail2ban
```

Monitor with:
```bash
sudo fail2ban-client status sshd
sudo fail2ban-client status recidive
sudo fail2ban-client status recidive-permanent
```

### Automatic Security Updates

```bash
apt install unattended-upgrades
dpkg-reconfigure -plow unattended-upgrades
```

### Audit Logging

```bash
apt install auditd
auditctl -w /opt/n8n-v2 -p wa -k n8n-deploy
auditctl -w /etc/ssh/sshd_config -p wa -k ssh-config
auditctl -w /etc/sudoers.d/ -p wa -k sudoers-change
```

---

## CI/CD Security

### GitHub Actions

The deployment workflow:
1. Creates `.env` from GitHub secrets using python3 (avoids bash `$` expansion of bcrypt hashes)
2. Never stores credentials in the repository
3. Uses secure environment variable passing via SSH heredocs
4. Sets `umask 077` during deployment to restrict file permissions
5. Cleans up SSH key material after deployment (`if: always()`)
6. Fixes monitoring config permissions (`chmod -R o+rX`) before container start
7. Doubles `$` signs in auth hashes automatically for Docker Compose compatibility

### SSH Key Cleanup

All workflows must include a cleanup step:

```yaml
- name: Cleanup SSH key
  if: always()
  run: |
    rm -f ~/.ssh/id_rsa
    rm -f ~/.ssh/known_hosts
```

### Workflow Protections

- Concurrency groups prevent duplicate deployments
- Pre-deployment validation (Docker Compose config check, shellcheck)
- Automatic rollback on deployment failure
- Health checks after deployment
- Backup creation before every deployment (7-day retention)

---

## Deployment Security

### Environment Variables

When running scripts locally, use environment variables or the `.env` file:

```bash
# Use .env file
cp env.example .env
# Edit .env with your actual values — NEVER commit this file
```

### Backup & Recovery

Automated backups are created before each deployment:
- Service configurations
- PostgreSQL database dumps (`pg_dump` per database)
- Docker volume archives
- Retention: last 7 backups

Backup location on VPS: `/opt/n8n-v2/shared/backups/{configs,databases,volumes}`

---

## Monitoring and Alerts

### Current Stack

- **Prometheus** — Metrics collection (30-day retention), scrapes via Docker socket proxy
- **Grafana** — Dashboard visualization (Prometheus + Loki datasources)
- **AlertManager** — Alert routing → N8N webhook → Telegram
- **Loki** — Log aggregation (7-day retention)
- **Promtail** — Log shipper (Docker container logs + `/var/log/auth.log`)
- **cAdvisor** — Container resource metrics
- **Node Exporter** — System-level metrics + fail2ban textfile collector
- **Hourly monitoring workflow** — Automated health checks via GitHub Actions
- **Daily security digest** — Cron job at 08:00 UTC → N8N webhook → Telegram

### Alert Rules

| Group | Alert | Threshold |
|-------|-------|-----------|
| Security | SSHBruteForceSpike | >200 failures/hour |
| Security | SSHDistributedAttack | >15 unique IPs/hour |
| Security | HighBanCount | >20 banned IPs |
| System | ContainerDown | Any container down >1min |
| System | HighCPUUsage | >85% for 5min |
| System | DiskSpaceCritical | >95% |
| Services | CloudflareTunnelDown | Tunnel metrics unreachable |
| Services | ContainerHighMemory | >90% of limit |

### Operational Notes

- Cross-compose-project Prometheus targets use container names (e.g., `edge-traefik-1`), not service names
- Loki image does not include `wget` — healthcheck uses `curl`
- Monitoring config files require `chmod -R o+rX` after deployment (automated in workflow)

### Future Improvements

- [ ] Traefik access log analysis for anomaly detection
- [ ] Cloudflare audit log monitoring via API
- [ ] Grafana alerting dashboards for Loki log patterns

---

## Incident Response

If credentials are compromised:

1. **Immediate**: Rotate all potentially affected credentials (see rotation procedures above)
2. **Isolate**: If VPS compromise is suspected, restrict firewall to your IP only
3. **Assess**: Review `auth.log`, `audit.log`, Docker logs, and Cloudflare audit logs
4. **Update**: Change all related passwords, tokens, and SSH keys
5. **Document**: Record the incident timeline and lessons learned
6. **Harden**: Update security procedures based on findings

---

## Remediation Action Items

### Phase 1 — Immediate (before next deployment)

- [x] Rotate all Cloudflare credentials (token, tunnel secret, tunnel ID)
- [x] Verify `.env` has never been committed to git history
- [x] Replace credentials JSON auth with token-based tunnel auth (`CLOUDFLARE_TUNNEL_TOKEN`)
- [x] Fix CloudFlared metrics binding (`127.0.0.1:2000`) and log level (`info`)

### Phase 2 — This week

- [x] Create `deployer` user on VPS with scoped sudo
- [x] Upgrade `automat` user to admin with sudo group
- [x] Update `VPS_SSH_KEY` GitHub secret with deployer's ed25519 private key
- [x] Update all workflow files to use `deployer@` instead of `root@`
- [x] Disable root SSH login (`PermitRootLogin no`)
- [x] Add SSH key cleanup step to all workflows
- [x] Add authentication to Traefik dashboard
- [x] Set strong Grafana admin password, remove `:-admin` default

### Phase 3 — This month

- [x] Install and configure fail2ban on VPS (7 IPs already banned)
- [x] Configure UFW — reset to SSH-only, all service ports closed
- [x] Install unattended-upgrades for automatic security patches
- [x] Set up audit logging on VPS (auditd with rules for deploy dir, sshd_config, sudoers)
- [x] Disable SSH password authentication (`PasswordAuthentication no`)
- [x] Replace direct Docker socket mount with socket proxy for Traefik
- [x] Add resource limits to all containers
- [x] Restrict Ollama CORS origins
- [x] PostgreSQL passwords — accepted risk with file permission hardening (`chmod 600`)
- [x] Enable rate limiting on Traefik routes
- [x] Set up centralized logging (Loki + Promtail)

---

## Best Practices

### Development

- Use environment variables for all sensitive configuration
- Never hardcode credentials in source code
- Use separate credentials for development and production
- Regularly update dependencies and base images

### Deployment

- Use least-privilege access for all services and users
- Enable audit logging where possible
- Regularly review and rotate credentials (quarterly)
- Use secure communication channels (HTTPS, SSH with key auth only)

### Team Access

- Limit access to production credentials to essential personnel only
- Use individual accounts rather than shared credentials
- Implement proper offboarding procedures
- Regular access reviews and cleanups

---

**Remember**: Security is everyone's responsibility. When in doubt, ask for guidance rather than compromising security.

# Cloudflare Zero Trust Setup Guide

A complete reference for configuring Cloudflare Tunnels and Access for containerized service deployments. This guide covers the full stack: tunnel creation, DNS records, ingress routing, and access control.

## Architecture Overview

```
Internet
   |
   v
Cloudflare Edge (TLS termination, Access policies, WAF)
   |
   v
Cloudflare Tunnel (outbound connection from VPS — no open ports needed)
   |
   v
Traefik (reverse proxy — routes by subdomain via Docker labels)
   |
   v
Docker containers (n8n, grafana, erpnext, etc.)
```

There are **three layers** you must configure, in order. Missing any one of them breaks connectivity:

| Layer | What it does | Where to configure |
|-------|-------------|-------------------|
| 1. **Tunnel** | Encrypted connection from VPS to Cloudflare edge | Dashboard or `docker compose` with token |
| 2. **Tunnel Ingress** | Maps hostnames to internal services | Dashboard (Public Hostnames) or API |
| 3. **DNS Records** | Points public domains to the tunnel | Dashboard (DNS) or API — often auto-created |

Optional:

| Layer | What it does | Where to configure |
|-------|-------------|-------------------|
| 4. **Access Applications** | Protects services behind SSO/email auth | Dashboard (Zero Trust > Access) or API |
| 5. **Access Policies** | Defines who can access what | Dashboard or API |

---

## Layer 1: Tunnel

### What it is

A Cloudflare Tunnel is a persistent outbound connection from your VPS to Cloudflare's edge. Traffic flows: `User -> Cloudflare Edge -> Tunnel -> Your VPS`. No inbound ports (80, 443) need to be open on your VPS.

### Token-based authentication (recommended)

When you create a tunnel in the dashboard, Cloudflare gives you a **token** — a single base64 string that contains your account ID, tunnel ID, and tunnel secret. This replaces the older credentials JSON + tunnel ID approach.

### Creating a tunnel

1. Go to https://one.dash.cloudflare.com/ > **Networks > Tunnels**
2. Click **Create a tunnel**
3. Name it (e.g., `production`)
4. Choose **cloudflared** as the connector
5. Copy the token from the install command

### Running in Docker Compose

```yaml
cloudflared:
  image: cloudflare/cloudflared:latest
  restart: unless-stopped
  networks: [edge]
  environment:
    - TUNNEL_METRICS=127.0.0.1:2000
  command: tunnel --no-autoupdate run --token ${CLOUDFLARE_TUNNEL_TOKEN}
```

The `CLOUDFLARE_TUNNEL_TOKEN` comes from your `.env` file:

```bash
CLOUDFLARE_TUNNEL_TOKEN=eyJhIjoiNjMyZ...
```

### Common mistakes

- **Metrics bound to `0.0.0.0`**: Always use `127.0.0.1` to avoid exposing metrics externally
- **Debug logging in production**: Use `--loglevel info`, not `debug`
- **Mounting config files with token auth**: When using `--token`, you do NOT need `config.yml`, credentials JSON, or `cert.pem` volume mounts — the token contains everything

---

## Layer 2: Tunnel Ingress

### What it is

Ingress rules tell the tunnel **where to route traffic** for each hostname. Without ingress rules, the tunnel connects to Cloudflare but returns 503 for all requests.

### How to configure

With token-based auth, ingress rules are managed **remotely** via the Cloudflare dashboard or API — not in a local `config.yml` file.

#### Via Dashboard

1. Go to **Networks > Tunnels > [your tunnel] > Public Hostname**
2. Add entries:

| Subdomain | Domain | Type | URL |
|-----------|--------|------|-----|
| `*` | `yourdomain.com` | HTTP | `traefik:80` |
| *(empty)* | `yourdomain.com` | HTTP | `traefik:80` |

The wildcard (`*`) catches all subdomains. The bare domain entry catches `yourdomain.com` itself. Both route to Traefik, which handles subdomain-based routing to individual containers.

#### Via API

```bash
ACCOUNT_ID="your_account_id"
TUNNEL_ID="your_tunnel_id"

curl -X PUT "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{
    "config": {
      "ingress": [
        {"hostname": "*.yourdomain.com", "service": "http://traefik:80", "originRequest": {}},
        {"hostname": "yourdomain.com", "service": "http://traefik:80", "originRequest": {}},
        {"service": "http_status:404"}
      ]
    }
  }'
```

**Important**: The last entry must always be a catch-all with no hostname (`{"service": "http_status:404"}`).

### Common mistakes

- **Forgetting the wildcard**: Only adding `yourdomain.com` but not `*.yourdomain.com` — subdomains won't work
- **Forgetting the catch-all**: The ingress list must end with a service-only entry (no hostname)
- **Wrong service URL**: The URL must be reachable from the cloudflared container. Use Docker service names (e.g., `traefik`) not `localhost`
- **Config not updating**: Token-based tunnels receive config updates automatically. Check `docker logs` for `Updated to new configuration` messages

### Verifying ingress

```bash
# Check the tunnel's current config
curl -s "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | jq '.result.config.ingress'

# Check cloudflared logs for config updates
docker logs edge-cloudflared-1 --tail 20 2>&1 | grep "Updated to new configuration"
```

---

## Layer 3: DNS Records

### What it is

DNS CNAME records point your domain to the tunnel. Without them, browsers can't resolve your domain at all.

### Required records

| Type | Name | Content | Proxied |
|------|------|---------|---------|
| CNAME | `yourdomain.com` | `<tunnel-id>.cfargotunnel.com` | Yes (orange cloud) |
| CNAME | `*.yourdomain.com` | `<tunnel-id>.cfargotunnel.com` | Yes (orange cloud) |

**Proxied must be ON** (orange cloud). If set to DNS-only (grey cloud), Cloudflare won't route through the tunnel.

### Auto-creation

When you add public hostnames via the dashboard (Layer 2), Cloudflare usually auto-creates the DNS records. When using the API, you must create them manually.

### Via API

```bash
ZONE_ID="your_zone_id"

# Get zone ID
curl -s "https://api.cloudflare.com/client/v4/zones?name=yourdomain.com" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | jq '.result[0].id'

# Create wildcard CNAME
curl -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{
    "type": "CNAME",
    "name": "*.yourdomain.com",
    "content": "<tunnel-id>.cfargotunnel.com",
    "ttl": 1,
    "proxied": true
  }'

# Create bare domain CNAME
curl -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{
    "type": "CNAME",
    "name": "yourdomain.com",
    "content": "<tunnel-id>.cfargotunnel.com",
    "ttl": 1,
    "proxied": true
  }'
```

### Common mistakes

- **CNAME pointing to old tunnel ID**: After rotating a tunnel, update all CNAME records to the new tunnel ID
- **Existing A/AAAA records conflicting**: You can't have both an A record and a CNAME for the same hostname. Delete the A record first
- **DNS-only mode (grey cloud)**: Must be proxied (orange cloud) for tunnel routing
- **Local DNS cache**: After changes, flush with `sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder` (macOS)

### Verifying DNS

```bash
# Check what records exist
curl -s "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | \
  jq '[.result[] | {name: .name, type: .type, content: .content, proxied: .proxied}]'

# Test resolution
dig yourdomain.com +short
dig subdomain.yourdomain.com +short
```

---

## Layer 4: Access Applications (Optional)

### What it is

Cloudflare Access puts an authentication gate in front of your services. Users must authenticate (via email OTP, Google, etc.) before reaching the service.

### Access evaluation order

Cloudflare evaluates **more specific hostnames first**:
1. `private.yourdomain.com` (exact match) is checked before `*.yourdomain.com` (wildcard)
2. This lets you bypass specific subdomains while protecting everything else

### Recommended pattern

Use **2 application slots** to protect everything with targeted exceptions:

| Application | Domain | Policy | Purpose |
|-------------|--------|--------|---------|
| All Services | `*.yourdomain.com` | Allow (authenticated) | Protects grafana, traefik, prometheus, etc. |
| Public App | `app.yourdomain.com` | Bypass (everyone) | App has its own auth (e.g., N8N login) |

### Creating via API

```bash
# 1. Create reusable policies
# Allow policy
curl -X POST "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/access/policies" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{"name": "Authorized Users", "decision": "allow", "include": [{"everyone": {}}]}'

# Bypass policy
curl -X POST "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/access/policies" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{"name": "Public Bypass", "decision": "bypass", "include": [{"everyone": {}}]}'

# 2. Create applications and attach policies
curl -X POST "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/access/apps" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{
    "name": "All Services",
    "type": "self_hosted",
    "domain": "*.yourdomain.com",
    "policies": [{"id": "<allow-policy-id>", "precedence": 1}]
  }'
```

### Common mistakes

- **Free plan limit**: 5 application slots. Use wildcard apps to cover many services with one slot
- **Legacy policies**: Always create reusable policies (`POST /access/policies`) and attach them, not inline policies on the app. Legacy inline policies show a warning
- **Wildcard doesn't match bare domain**: `*.yourdomain.com` does NOT protect `yourdomain.com`. Add it separately if needed
- **Bypass breaks webhooks**: If a service receives webhooks (e.g., N8N, payment processors), it must be bypassed or use Cloudflare Service Tokens

---

## Layer 5: Access Policies

### Policy types

| Decision | Effect |
|----------|--------|
| `allow` | Requires authentication. User must match the include rules |
| `bypass` | No authentication required. Requests pass through directly |
| `block` | Denies access entirely |

### Reusable vs legacy

Always create **reusable policies** via the `/access/policies` endpoint, then attach them to applications. Legacy inline policies (created directly on the app) show deprecation warnings.

### Restricting to specific users

Change the `include` rule from `everyone` to specific emails:

```json
{
  "name": "Team Only",
  "decision": "allow",
  "include": [
    {"email": {"email": "alice@example.com"}},
    {"email": {"email": "bob@example.com"}}
  ]
}
```

Or by email domain:

```json
{
  "include": [
    {"email_domain": {"domain": "example.com"}}
  ]
}
```

---

## Complete Setup Checklist

When setting up a new project with Cloudflare Tunnel, go through these steps in order:

### Initial setup

- [ ] Create a Cloudflare Tunnel in Zero Trust dashboard
- [ ] Copy the tunnel token
- [ ] Add `CLOUDFLARE_TUNNEL_TOKEN` to `.env` and GitHub secrets
- [ ] Create an API token with DNS:Edit and Tunnel:Edit permissions
- [ ] Add `CLOUDFLARE_API_TOKEN` to `.env`

### Tunnel ingress (Layer 2)

- [ ] Add public hostname: `*.yourdomain.com` -> `http://traefik:80`
- [ ] Add public hostname: `yourdomain.com` -> `http://traefik:80`
- [ ] Verify catch-all rule exists (404 for unmatched)
- [ ] Check cloudflared logs for `Updated to new configuration`

### DNS (Layer 3)

- [ ] CNAME `*.yourdomain.com` -> `<tunnel-id>.cfargotunnel.com` (proxied)
- [ ] CNAME `yourdomain.com` -> `<tunnel-id>.cfargotunnel.com` (proxied)
- [ ] No conflicting A/AAAA records exist
- [ ] DNS resolves: `dig yourdomain.com +short` returns Cloudflare IPs

### Access control (Layer 4-5)

- [ ] Create reusable "Authorized Users" allow policy
- [ ] Create reusable "Public Bypass" bypass policy
- [ ] Create "All Services" app on `*.yourdomain.com` with allow policy
- [ ] Create bypass app for each public service (e.g., N8N, ERPNext)
- [ ] Verify protected services redirect to Access login
- [ ] Verify bypassed services load directly

### Docker Compose

- [ ] cloudflared uses `--token` (not config file)
- [ ] Metrics bound to `127.0.0.1` (not `0.0.0.0`)
- [ ] Log level set to `info` (not `debug`)
- [ ] cloudflared and traefik on same Docker network
- [ ] `.env` file contains `CLOUDFLARE_TUNNEL_TOKEN` and `DOMAIN_NAME`
- [ ] `docker compose` uses `--env-file .env` if compose file is in a subdirectory

### VPS firewall

- [ ] SSH allowed (port 22)
- [ ] Ports 80, 443 **denied** (traffic goes through tunnel, not direct)
- [ ] No service ports exposed (11434, 6333, etc.)

---

## Verification Commands

### Quick health check

```bash
# Test a bypassed service (should return 200)
curl -s -o /dev/null -w "HTTP %{http_code}" https://app.yourdomain.com

# Test a protected service (should return 302)
curl -s -o /dev/null -w "HTTP %{http_code}" https://grafana.yourdomain.com

# Check tunnel connections
docker logs edge-cloudflared-1 --tail 10 2>&1 | grep "Registered tunnel connection"

# Check ingress config
curl -s "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | jq '.result.config.ingress'

# List DNS records
curl -s "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | \
  jq '[.result[] | {name: .name, type: .type, proxied: .proxied}]'

# List Access apps
curl -s "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/access/apps" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | \
  jq '[.result[] | {name: .name, domain: .domain, policies: [.policies[] | .decision]}]'
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Browser shows "DNS not found" | Missing or non-proxied CNAME record | Add CNAME, ensure orange cloud (proxied) |
| Cloudflare 1033 error | DNS points to tunnel, but tunnel has no matching ingress rule | Add public hostname in tunnel config |
| Cloudflare 502 error | Tunnel can't reach the origin service | Check Docker network — cloudflared and traefik must share a network |
| Cloudflare 503 error | `No ingress rules defined` in cloudflared logs | Add ingress rules via dashboard or API |
| Access login appears on bypassed app | Bypass app not created, or hostname doesn't match exactly | Create specific hostname app with bypass policy |
| Protected app loads without auth | Hostname not covered by wildcard, or Access app misconfigured | Wildcard `*` doesn't match bare domain — add separately |
| `--token` results in empty command | `CLOUDFLARE_TUNNEL_TOKEN` not in `.env` or compose can't read it | Use `--env-file .env` with `docker compose` |
| Token works in `docker run` but not compose | Compose resolves `.env` relative to compose file, not working dir | Pass `--env-file /path/to/.env` explicitly |

---

## API Token Permissions Reference

| Permission | Scope | Needed for |
|-----------|-------|------------|
| Zone > DNS > Edit | Specific zone | Creating/updating CNAME records |
| Account > Cloudflare Tunnel > Edit | Account | Managing tunnel configurations |
| Account > Access: Apps and Policies > Edit | Account | Creating Access applications and policies |

Create tokens at: https://dash.cloudflare.com/profile/api-tokens

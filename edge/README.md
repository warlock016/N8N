# Edge Stack - Traefik + CloudFlared

This is the core routing infrastructure for the decoupled services architecture.

## Setup Instructions

1. **Configure CloudFlare Tunnel:**
   ```bash
   # Replace placeholders in cloudflared/config.yml
   export TUNNEL_ID=your_tunnel_id
   export DOMAIN=example.com
   envsubst < cloudflared/config.yml > cloudflared/config.yml.tmp \
     && mv cloudflared/config.yml.tmp cloudflared/config.yml

   # Place your tunnel credentials in:
   # cloudflared/${TUNNEL_ID}.json
   ```

2. **Update Traefik Dashboard Domain:**
   ```bash
   # Edit docker-compose.yml and replace traefik.example.com
   # with your actual domain for the dashboard
   ```

3. **Deploy the Edge Stack:**
   ```bash
   cd edge
   docker compose up -d
   ```

4. **Verify Deployment:**
   ```bash
   # Check services are running
   docker compose ps
   
   # Check logs
   docker compose logs traefik
   docker compose logs cloudflared
   ```

5. **Metrics Authentication:**
   ```
   # Metrics endpoint (/metrics) is protected with basic auth
   # Default credentials: metrics / metricssecret
   # To change the password, generate a new hash:
   openssl passwd -apr1 NEW_PASSWORD
   # Replace the hashed value in docker-compose.yml
   ```

## How It Works

- **CloudFlared**: Creates a secure tunnel from CloudFlare to your VPS
- **Traefik**: Reverse proxy that routes based on Docker labels
- **Wildcard Routing**: `*.example.com` routes to Traefik, eliminating per-service tunnel configuration

## Adding New Services

Services automatically register with Traefik using Docker labels:

```yaml
services:
  myapp:
    labels:
      - traefik.enable=true
      - traefik.http.routers.myapp.rule=Host(`myapp.example.com`)
      - traefik.http.services.myapp.loadbalancer.server.port=3000
```

No changes needed to this edge stack when adding services!

## Security

- No ports exposed on the host (80/443 stay closed)
- All traffic encrypted through CloudFlare tunnel
- Protect admin interfaces with CloudFlare Access
- Use separate hostnames for webhooks if needed

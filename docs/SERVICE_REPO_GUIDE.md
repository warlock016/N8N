# Creating a Service Repo

Each service deploys independently from its own GitHub repository. This guide covers setup from scratch.

## Prerequisites

- The platform repo (this repo) is deployed and the edge stack (Traefik + Cloudflared) is running
- A DNS CNAME record pointing `<subdomain>.your-domain.com` to the CloudFlare tunnel (for web-facing services)
- `VPS_SSH_KEY` and `PRODUCTION_VPS_HOST` configured as GitHub secrets in the service repo

## Repo Structure

```
my-service/
├── compose.yml                 # Docker Compose with Traefik labels
├── .env.example                # Required env vars (no real values)
├── .gitignore
└── .github/
    └── workflows/
        └── deploy.yml          # Calls the reusable workflow
```

## 1. compose.yml

### Web-facing service (routed through Traefik)

```yaml
services:
  app:
    image: your-image:latest
    restart: unless-stopped
    networks:
      - edge
    labels:
      - traefik.enable=true
      - traefik.http.routers.my-service.rule=Host(`my-service.your-domain.com`)
      - traefik.http.routers.my-service.entrypoints=web
      - traefik.http.services.my-service.loadbalancer.server.port=8080
      - traefik.docker.network=edge

networks:
  edge:
    external: true
```

### Internal-only service (not publicly accessible)

```yaml
services:
  app:
    image: your-image:latest
    restart: unless-stopped
    networks:
      - ai-internal
    labels:
      - traefik.enable=false

networks:
  ai-internal:
    external: true
```

### Service with both public and internal access

```yaml
services:
  app:
    image: your-image:latest
    restart: unless-stopped
    networks:
      - edge
      - ai-internal
    labels:
      - traefik.enable=true
      - traefik.http.routers.my-service.rule=Host(`my-service.your-domain.com`)
      - traefik.http.routers.my-service.entrypoints=web
      - traefik.http.services.my-service.loadbalancer.server.port=8080
      - traefik.docker.network=edge

networks:
  edge:
    external: true
  ai-internal:
    external: true
```

### Adding security headers middleware

```yaml
labels:
  # ... routing labels above ...
  - traefik.http.middlewares.my-service-headers.headers.stsSeconds=31536000
  - traefik.http.middlewares.my-service-headers.headers.contentTypeNosniff=true
  - traefik.http.middlewares.my-service-headers.headers.browserXssFilter=true
  - traefik.http.middlewares.my-service-headers.headers.customFrameOptionsValue=SAMEORIGIN
  - traefik.http.routers.my-service.middlewares=my-service-headers
```

### Adding Prometheus metrics scraping

```yaml
labels:
  # ... routing labels above ...
  - prometheus.io/scrape=true
  - prometheus.io/port=8080
  - prometheus.io/path=/metrics
  - service_name=my-service
```

## 2. .env.example

List all required environment variables without values:

```
DB_PASSWORD=
API_KEY=
SECRET_KEY=
```

## 3. .gitignore

```
.env
*.env
*_data/
data/
```

## 4. Deploy workflow

Create `.github/workflows/deploy.yml`:

```yaml
name: Deploy

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  deploy:
    uses: warlock016/N8N/.github/workflows/deploy-service.yml@main
    with:
      service_name: my-service
    secrets:
      VPS_SSH_KEY: ${{ secrets.VPS_SSH_KEY }}
      VPS_HOST: ${{ secrets.PRODUCTION_VPS_HOST }}
```

## First-time setup

1. Create the service repo with the structure above
2. Add GitHub secrets: `VPS_SSH_KEY` and `PRODUCTION_VPS_HOST` (same values as the platform repo)
3. Create the `.env` file on the VPS:
   ```bash
   ssh hetzner
   mkdir -p /opt/n8n-v2/shared/services/my-service
   nano /opt/n8n-v2/shared/services/my-service/.env
   # Fill in the values from .env.example
   ```
4. Add a DNS CNAME (for web-facing services):
   ```bash
   # From the platform repo on your local machine
   ./scripts/cloudflare-dns-api.sh add my-service.your-domain.com
   ```
5. Push to `main` — the workflow deploys automatically

## Operational commands

Once deployed, manage the service from the VPS using the `svc` CLI:

```bash
ssh hetzner
svc list                    # List all services
svc info my-service         # Show service details
svc logs my-service -f      # Follow logs
svc restart my-service      # Restart
svc remove my-service       # Stop and remove
```

## Available Docker networks

| Network | Purpose | Use when |
|---------|---------|----------|
| `edge` | Traefik routing (public access) | Service needs a subdomain |
| `ai-internal` | Internal service mesh | Service communicates with Ollama, Qdrant, etc. |

Both networks are pre-created on the VPS. Declare them as `external: true` in your compose file.

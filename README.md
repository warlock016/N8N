# N8N AI-Powered Services Stack

A production-ready, low-ops blueprint for hosting multiple independent Docker services (N8N instances, AI services, databases, custom apps) on one VPS using Traefik reverse proxy and CloudFlare tunnel.

> 📖 **New to this repository?** See the [Configuration Guide](docs/CONFIGURATION_GUIDE.md) for detailed setup instructions.

## 🚀 Quick Start

### Prerequisites
- VPS with Docker and Docker Compose v2
- Domain on CloudFlare
- CloudFlare Tunnel setup (get TUNNEL_ID and credentials)
- GitHub repository with configured secrets (for automated deployment)

### 1. Initial Configuration

After cloning this repository, you need to configure it for your environment:

#### Local Environment Setup
```bash
# Install dependencies
pip3 install -r requirements.txt

# Create your environment configuration
cp env.example .env
```

#### Configure `.env` file
Edit `.env` with your actual values:
```bash
# Domain Name Configuration
DOMAIN_NAME=your-domain.com

# Cloudflare Zero Trust Tunnel Configuration & Credentials
CLOUDFLARE_TOKEN=your_cloudflare_api_token
ACCOUNT_TAG=your_account_tag
TUNNEL_SECRET=your_tunnel_secret
TUNNEL_ID=your_tunnel_id
```

### 2. GitHub Repository Setup (For Automated Deployment)

Configure these secrets in your GitHub repository (`Settings > Secrets and variables > Actions`):

#### Required Secrets:
```bash
# VPS Connection
VPS_SSH_KEY=<your-private-ssh-key-content>
PRODUCTION_VPS_HOST=your.vps.ip.address
STAGING_VPS_HOST=your.vps.ip.address    # Same or different VPS

# CloudFlare Configuration
CLOUDFLARE_API_TOKEN=<your-cloudflare-api-token>
CLOUDFLARE_TUNNEL_CREDENTIALS=<tunnel-credentials-json-content>
CLOUDFLARE_TUNNEL_ID=<your-tunnel-id>
DOMAIN_NAME=your-domain.com

# Optional: Notification webhooks
SLACK_WEBHOOK_URL=<your-slack-webhook>
DISCORD_WEBHOOK_URL=<your-discord-webhook>
```

#### SSH Key Setup:
```bash
# Generate SSH key pair for GitHub Actions
ssh-keygen -t rsa -b 4096 -C "github-actions@yourdomain.com" -f ~/.ssh/github-actions

# Copy public key to your VPS
ssh-copy-id -i ~/.ssh/github-actions.pub root@your-vps-ip

# Add private key content to VPS_SSH_KEY secret in GitHub
cat ~/.ssh/github-actions
```

### 3. CloudFlare Tunnel Setup

The configuration files now use environment variables. Your CloudFlare tunnel config will automatically use your domain:

```yaml
# edge/cloudflared/config.yml uses ${DOMAIN_NAME}
ingress:
  - hostname: "*.${DOMAIN_NAME}"
    service: http://traefik:80
```

### 4. Deploy Edge Stack
```bash
# Initialize the project
./scripts/svc init

# Deploy Traefik + CloudFlared
./scripts/svc edge deploy
```

### 4. Create Your First AI-Powered N8N Instance
```bash
# Create AI services (internal only)
./scripts/svc new --name ollama-main --template ollama
./scripts/svc new --name qdrant-vectors --template qdrant

# Deploy AI services
./scripts/svc deploy ollama-main
./scripts/svc deploy qdrant-vectors

# Create N8N instance that can use AI services
./scripts/svc new --name n8n-ai --template n8n --domain n8n.example.com

# Deploy it
./scripts/svc deploy n8n-ai
```

### 5. Access Your Instance
Visit `https://n8n.example.com` - it should be accessible through the CloudFlare tunnel!

Your N8N instance can now connect to:
- **Ollama (LLM)**: `http://ollama-main:11434`
- **Qdrant (Vector DB)**: `http://qdrant-vectors:6333`

## 📁 Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│                   CloudFlare Edge                   │
└────────────────┬────────────────────────────────────┘
                 │ (*.example.com)
                 ▼
┌─────────────────────────────────────────────────────┐
│            CloudFlared Tunnel                       │
└────────────────┬────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────┐
│              Traefik Reverse Proxy                  │
│          (Auto-discovery via Docker labels)         │
└────────────────┬────────────────────────────────────┘
                 │
    ┌────────────┼────────────┬──────────────┬──────────────┐
    ▼            ▼            ▼              ▼              ▼
┌────────┐  ┌────────┐  ┌────────┐    ┌────────┐    ┌────────┐
│  N8N   │  │  N8N   │  │ Custom │    │Monitor-│    │   AI   │
│   AI   │  │Instance│  │Service │    │  ing   │    │Services│
│        │  │   #2   │  │        │    │ Stack  │    │        │
└───┬────┘  └────────┘  └────────┘    └────────┘    └────────┘
    │                                                      ▲
    └───────────┌─────────────┬─────────────┬──────────────┘
                ▼             ▼             ▼
            ┌────────┐    ┌────────┐   ┌────────┐
            │ Ollama │    │ Qdrant │   │Postgres│
            │  (LLM) │    │Vector  │   │   DB   │
            │Internal│    │DB      │   │Internal│
            └────────┘    │Internal│   └────────┘
                          └────────┘
```

### Key Benefits
- **AI-Ready**: Built-in LLM (Ollama) and vector database (Qdrant) support
- **Wildcard tunnel**: Add services without tunnel configuration
- **Zero-touch routing**: Services self-register via Docker labels
- **Security**: No host ports exposed, AI services internal-only
- **Isolation**: Each service has its own network and resources

## 🛠️ Service Management

### CLI Commands

```bash
# List all services
./scripts/svc list

# ===== AI SERVICES (Internal Only) =====

# Create Ollama LLM service (no resource limits)
./scripts/svc new --name ollama-main --template ollama

# Create Qdrant vector database
./scripts/svc new --name qdrant-vectors --template qdrant

# Create shared PostgreSQL database  
./scripts/svc new --name postgres-shared --template postgresql

# ===== N8N SERVICES (Web Accessible) =====

# Create N8N instance with AI capabilities
./scripts/svc new --name n8n-ai --template n8n --domain n8n.example.com

# Create additional N8N instances
./scripts/svc new --name n8n-dev --template n8n --domain n8n-dev.example.com

# ===== GENERIC SERVICES =====

# Create custom service
./scripts/svc new --name wordpress --template generic-app \
  --domain blog.example.com --image wordpress:latest --port 80

# ===== DEPLOYMENT & MANAGEMENT =====

# Deploy service
./scripts/svc deploy myapp

# View service info and status
./scripts/svc info myapp

# View logs
./scripts/svc logs myapp --follow

# Restart service
./scripts/svc restart myapp
# Remove service (with confirmation)
./scripts/svc remove myapp --volumes
```

### Edge Stack Management

```bash
# Deploy edge stack
./scripts/svc edge deploy

# View edge stack logs
./scripts/svc edge logs

# Restart edge stack
./scripts/svc edge restart

# Check edge stack status
./scripts/svc edge status
```

## 🔄 Service Updates

### Updating N8N and Other Services

This architecture provides **zero-data-loss updates** for all services through persistent Docker volumes. All workflows, credentials, execution history, and file uploads are automatically preserved during updates.

#### Quick Update Commands

```bash
# Update a specific service to latest version
./scripts/svc deploy service-name

# Update with fresh image pull
cd /opt/n8n-v2/shared/services/service-name
docker compose -p service-name pull
docker compose -p service-name up -d --remove-orphans

# Force complete container recreation (for testing)
docker compose -p service-name up -d --force-recreate
```

#### Automated Update via GitHub Actions

```bash
# Update specific service via GitHub Actions
gh workflow run service-management.yml \
  -f action=deploy-service \
  -f service_name=n8n-private \
  -f environment=production

# Full deployment update (updates all services)
gh workflow run deploy-to-vps.yml \
  -f environment=production \
  -f dry_run=false
```

### Update Procedure Step-by-Step

#### 1. Pre-Update Safety Check

```bash
# Check current service status
./scripts/svc info service-name

# Verify health before update
docker exec service-name wget -qO- http://localhost:5678/healthz

# Check data integrity
docker exec service-name ls -lah /home/node/.n8n/
```

#### 2. Automatic Backup (Built-in)

The deployment system automatically creates comprehensive backups before any update:

- **Database backups**: PostgreSQL/SQLite dumps
- **Volume backups**: Complete data directory archives
- **Configuration backups**: Service settings and environment files
- **Location**: `/opt/n8n-v2/shared/backups/`

```bash
# Manual backup (optional - auto-backup is recommended)
BACKUP_DIR="/opt/n8n-v2/shared/backups/manual-$(date +%Y%m%d_%H%M%S)"
mkdir -p $BACKUP_DIR

# Backup N8N data volume
docker run --rm \
  -v service-name_n8n_data:/data \
  -v $BACKUP_DIR:/backup \
  alpine sh -c "tar czf /backup/n8n_data.tar.gz -C / data"
```

#### 3. Execute Update

```bash
# Method 1: Using service CLI (recommended)
./scripts/svc deploy service-name

# Method 2: Direct Docker Compose (production)
cd /opt/n8n-v2/shared/services/service-name
docker compose -p service-name pull
docker compose -p service-name up -d --remove-orphans

# Method 3: GitHub Actions (remote deployment)
gh workflow run service-management.yml \
  -f action=deploy-service \
  -f service_name=service-name \
  -f environment=production
```

#### 4. Post-Update Verification

```bash
# Verify service health
docker ps --filter "name=service-name"
./scripts/svc info service-name

# Check N8N specific health
docker exec service-name n8n --version
docker exec service-name wget -qO- http://localhost:5678/healthz

# Verify data preservation
docker exec service-name ls -lah /home/node/.n8n/
docker exec service-name du -sh /home/node/.n8n/

# Test web interface
curl -s https://your-domain.com/healthz
```

### Data Preservation Architecture

#### How Data Survives Updates

1. **Named Docker Volumes**: All critical data stored in persistent volumes
   ```yaml
   volumes:
     service-name_n8n_data:     # Workflows, credentials, settings
     service-name_n8n_files:    # File uploads, binary data
     service-name_postgres_data: # Database (if using PostgreSQL)
   ```

2. **Volume Persistence**: Volumes exist independently of containers
   - Container recreation doesn't affect volumes
   - Data automatically remounts to new containers
   - Zero downtime during volume reattachment

3. **SQLite Database**: N8N data stored in persistent SQLite files
   ```
   /home/node/.n8n/database.sqlite      # Main database
   /home/node/.n8n/database.sqlite-wal  # Write-ahead log
   /home/node/.n8n/database.sqlite-shm  # Shared memory
   ```

#### What Gets Preserved

✅ **Always Preserved**:
- N8N workflows and nodes
- User credentials (encrypted)
- Execution history
- Binary data and file uploads
- Custom settings and configuration
- Database schemas and indexes
- Environment variables (.env files)

❌ **Not Preserved** (by design):
- Container state and processes
- Temporary files in `/tmp`
- Log files (use external logging)
- Memory state and active connections

### Version Management

#### Checking Current Versions

```bash
# Check N8N version
docker exec service-name n8n --version

# Check image information
docker images service-name --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.CreatedAt}}"

# Check for available updates (manual)
docker run --rm n8nio/n8n:latest n8n --version
```

#### Update Strategies

**Rolling Updates (Default)**:
```bash
# Gradual update with health checks
docker compose -p service-name up -d --remove-orphans
```

**Blue-Green Updates**:
```bash
# Create new instance, test, then switch DNS
./scripts/svc new --name service-name-v2 --template n8n --domain staging.example.com
# Test new instance, then update DNS
```

**Canary Updates**:
```bash
# Deploy to staging environment first
gh workflow run deploy-to-vps.yml -f environment=staging
# Test thoroughly, then deploy to production
gh workflow run deploy-to-vps.yml -f environment=production
```

### Rollback Procedures

#### Automatic Rollback

GitHub Actions deployment includes automatic rollback on failure:
```yaml
# Triggers automatically if deployment fails
rollback:
  runs-on: ubuntu-latest
  if: failure()
  steps:
    - name: Rollback to previous release
```

#### Manual Rollback

```bash
# Via GitHub Actions
gh workflow run deploy-to-vps.yml -f environment=production

# Manual rollback to previous container version
cd /opt/n8n-v2/shared/services/service-name
docker compose -p service-name down
docker run --rm -v service-name_n8n_data:/data alpine ls -la /data
# Verify data, then restart with previous image
```

#### Recovery from Backup

```bash
# List available backups
ls -la /opt/n8n-v2/shared/backups/

# Restore from volume backup
BACKUP_FILE="/opt/n8n-v2/shared/backups/volumes/service-name_n8n_data_20240913_111605.tar.gz"
docker volume rm service-name_n8n_data
docker volume create service-name_n8n_data
docker run --rm \
  -v service-name_n8n_data:/data \
  -v /opt/n8n-v2/shared/backups/volumes:/backup \
  alpine sh -c "cd /data && tar xzf /backup/$(basename $BACKUP_FILE)"
```

### Best Practices

#### Production Updates

1. **Always test in staging first**
2. **Schedule updates during low-traffic periods**
3. **Monitor logs during and after updates**
4. **Verify all integrations and webhooks**
5. **Keep rollback procedure ready**

#### Monitoring Updates

```bash
# Watch update progress
docker logs -f service-name

# Monitor resource usage during update
docker stats service-name

# Check update notifications (setup alerts)
# Integration with your monitoring stack
```

#### Update Frequency

- **Security updates**: Apply immediately
- **Feature updates**: Test in staging, deploy weekly
- **Major version updates**: Extensive testing, quarterly
- **Dependencies**: Monitor for CVEs, update as needed

### Troubleshooting Updates

#### Common Update Issues

**Container won't start after update**:
```bash
# Check logs for errors
docker logs service-name

# Verify volume mounts
docker inspect service-name --format "{{range .Mounts}}{{.Name}} -> {{.Destination}}{{end}}"

# Check disk space
df -h
docker system df
```

**Data appears missing**:
```bash
# Verify volumes exist
docker volume ls | grep service-name

# Check volume contents
docker run --rm -v service-name_n8n_data:/data alpine ls -la /data

# Restore from backup if needed
```

**N8N specific issues**:
```bash
# Database corruption check
docker exec service-name sqlite3 /home/node/.n8n/database.sqlite ".integrity_check"

# Reset N8N (preserves data but clears cache)
docker exec service-name rm -f /home/node/.n8n/crash.journal
docker restart service-name
```

#### Emergency Recovery

```bash
# Complete service recreation with data preservation
cd /opt/n8n-v2/shared/services/service-name
docker compose -p service-name down
docker compose -p service-name up -d --force-recreate

# Verify data integrity after recreation
docker exec service-name n8n --version
docker exec service-name ls -la /home/node/.n8n/
```

### System-Wide Container Updates and Cleanup

#### Updating All Containers to Latest Versions

To ensure all containers across your deployment are running the latest versions:

```bash
# Update all containers in a specific service
cd /opt/n8n-v2/shared/services/service-name
docker compose -f compose.yml pull
docker compose -f compose.yml up -d --force-recreate

# Update monitoring stack
cd /opt/n8n-v2/shared/monitoring
docker compose -f compose.yml pull
docker compose -f compose.yml up -d --force-recreate

# Update edge stack (Traefik + CloudFlared)
cd /opt/n8n-v2/shared/edge
docker compose -f docker-compose.yml pull
docker compose -f docker-compose.yml up -d --force-recreate
```

**Automated Update All Services**:
```bash
# Update all services using the management CLI
for service in /opt/n8n-v2/shared/services/*/; do
    service_name=$(basename "$service")
    echo "Updating $service_name..."
    ./scripts/svc deploy "$service_name"
done
```

#### Docker Cleanup and Maintenance

**Check Current Disk Usage**:
```bash
# View disk usage summary
docker system df

# View detailed image information
docker images --all

# View container sizes
docker ps -as
```

**Clean Up Dangling Images** (safe - removes only unused images):
```bash
# Remove dangling images (untagged images)
docker image prune -f

# Expected output: Reclaimed space from unused images
```

**Aggressive Cleanup** (removes all unused Docker resources):
```bash
# Remove all unused images, containers, networks (preserves volumes)
docker system prune -af --volumes=false

# Expected reclaim: ~10-15GB on active systems
```

**Complete Cleanup** (⚠️ use with caution - includes volumes):
```bash
# Remove everything unused INCLUDING VOLUMES
# WARNING: This will delete unused volume data
docker system prune -af --volumes
```

**Clean Up Specific Resources**:
```bash
# Remove unused volumes only
docker volume prune -f

# Remove stopped containers only
docker container prune -f

# Remove unused networks only
docker network prune -f

# Remove dangling build cache
docker builder prune -f
```

#### Maintenance Best Practices

**1. Regular Cleanup Schedule**:
```bash
# Add to crontab for weekly cleanup (Sundays at 2 AM)
0 2 * * 0 /usr/bin/docker system prune -af --volumes=false > /var/log/docker-cleanup.log 2>&1
```

**2. Pre-Update Cleanup**:
```bash
# Clean up before pulling new images to free space
docker image prune -f
docker builder prune -f

# Then update
docker compose pull
docker compose up -d --force-recreate
```

**3. Monitor Disk Usage**:
```bash
# Check before cleanup
docker system df

# Perform cleanup
docker system prune -af --volumes=false

# Check after cleanup to verify reclaimed space
docker system df
```

**4. Keep Only Active Images**:
```bash
# Remove all images not associated with running containers
docker image prune -a -f

# This keeps only images currently in use
```

#### Example Maintenance Workflow

**Monthly Maintenance Routine**:
```bash
#!/bin/bash
# Monthly Docker maintenance script

echo "=== Docker Maintenance Started ==="

# 1. Check current usage
echo "Current disk usage:"
docker system df

# 2. Clean dangling images
echo "Removing dangling images..."
docker image prune -f

# 3. Update all services to latest
echo "Updating all services..."
cd /opt/n8n-v2/shared/edge
docker compose pull && docker compose up -d --force-recreate

cd /opt/n8n-v2/shared/monitoring
docker compose pull && docker compose up -d --force-recreate

for service in /opt/n8n-v2/shared/services/*/; do
    cd "$service"
    docker compose pull && docker compose up -d --force-recreate
done

# 4. Aggressive cleanup (excluding volumes)
echo "Performing aggressive cleanup..."
docker system prune -af --volumes=false

# 5. Check final usage
echo "Final disk usage:"
docker system df

echo "=== Maintenance Completed ==="
```

Save as `/opt/n8n-v2/shared/scripts/maintenance.sh` and run monthly.

#### Troubleshooting Cleanup Issues

**"No space left on device" error**:
```bash
# Emergency cleanup to free space immediately
docker system prune -af --volumes=false
docker volume prune -f

# Check available space
df -h
```

**Images won't delete**:
```bash
# Force remove specific image
docker rmi -f <image_id>

# Stop all containers and remove all images
docker stop $(docker ps -aq)
docker rm $(docker ps -aq)
docker rmi -f $(docker images -q)
```

**Verify cleanup safety**:
```bash
# List volumes before pruning
docker volume ls

# Check what will be removed (dry run)
docker system prune -af --volumes=false --dry-run

# List running containers to ensure they're not affected
docker ps
```

## 📋 Available Templates

The service management CLI supports multiple templates for different use cases:

| Template      | Description                                 | Access                | Default Resources          |
|---------------|---------------------------------------------|-----------------------|----------------------------|
| `n8n`         | N8N workflow automation with AI support     | Web (domain required) | 2G memory, 1 CPU           |
| `ollama`      | Ollama LLM service for AI text generation   | Internal only         | No limits (full resources) |
| `qdrant`      | Qdrant vector database for embeddings       | Internal only         | 2G memory, 1 CPU           |
| `postgresql`  | PostgreSQL database with per-instance setup | Internal only         | 2G memory, 1 CPU           |
| `generic-app` | Custom Docker applications                  | Web (domain required) | User configurable          |

### Template Usage Examples

```bash
# AI-powered N8N instance
./scripts/svc new --name n8n-ai --template n8n --domain ai.example.com

# LLM service (models: llama3.2:1b, nomic-embed-text:latest)  
./scripts/svc new --name ollama-main --template ollama

# Vector database for RAG applications
./scripts/svc new --name vectors --template qdrant

# Dedicated PostgreSQL instance
./scripts/svc new --name db-shared --template postgresql

# Custom application (requires image and port)
./scripts/svc new --name blog --template generic-app \
  --domain blog.example.com --image wordpress:latest --port 80
```

## 🤖 AI Services

### Available AI Services

**Ollama (Large Language Models)**
- **Template**: `ollama`
- **Access**: Internal only (`http://service-name:11434`)
- **Default Models**: `llama3.2:1b`, `nomic-embed-text:latest`
- **Resource Limits**: None (models need full system resources)
- **Use Cases**: Text generation, embeddings, chat completion

**Qdrant (Vector Database)**
- **Template**: `qdrant`
- **Access**: Internal only (`http://service-name:6333`)
- **Resource Limits**: 2G memory, 1 CPU
- **Ports**: HTTP (6333), gRPC (6334)
- **Use Cases**: Similarity search, RAG applications, embedding storage

**PostgreSQL (Database)**
- **Template**: `postgresql`
- **Access**: Internal only (`service-name:5432`)
- **Resource Limits**: 2G memory, 1 CPU
- **Features**: Per-instance databases, automatic backups
- **Use Cases**: Application data, N8N workflows storage

### N8N AI Integration Examples

```bash
# Connect to Ollama in N8N workflows
HTTP Request: POST http://ollama-main:11434/api/generate
Body: {"model": "llama3.2:1b", "prompt": "Hello World"}

# Connect to Qdrant for vector operations
HTTP Request: POST http://qdrant-vectors:6333/collections
Body: {"name": "documents", "vectors": {"size": 384, "distance": "Cosine"}}

# Connect to shared PostgreSQL
Database Host: postgres-shared
Database: postgres-shared_db  
User: postgres-shared
Password: [check services/postgres-shared/.env]
```

### AI Service Deployment Pattern

```bash
# 1. Deploy AI infrastructure
./scripts/svc new --name ollama-prod --template ollama
./scripts/svc new --name qdrant-prod --template qdrant
./scripts/svc deploy ollama-prod
./scripts/svc deploy qdrant-prod

# 2. Create N8N with AI access
./scripts/svc new --name n8n-ai --template n8n --domain ai.example.com  
./scripts/svc deploy n8n-ai

# 3. Build AI workflows in N8N using:
# - ollama-prod:11434 for LLM operations
# - qdrant-prod:6333 for vector operations
```

## 📊 Monitoring

### Built-in Stack
- **Prometheus**: Metrics collection
- **Grafana**: Dashboards and visualization  
- **AlertManager**: Alert notifications
- **Node Exporter**: System metrics
- **cAdvisor**: Container metrics

### Deploy Monitoring
```bash
cd monitoring
docker compose up -d

# Access dashboards (protect with CloudFlare Access)
# - Grafana: https://grafana.example.com (admin/admin)
# - Prometheus: https://prometheus.example.com
# - AlertManager: https://alerts.example.com
```

### Service Metrics
Add these labels to any service for automatic Prometheus scraping:
```yaml
labels:
  - prometheus.io/scrape=true
  - prometheus.io/port=9090
  - prometheus.io/path=/metrics
```

## 🔒 Security

### CloudFlare Access (Recommended)
Protect admin interfaces with CloudFlare Access:
- `traefik.example.com` - Traefik dashboard
- `grafana.example.com` - Grafana
- `prometheus.example.com` - Prometheus
- `n8n.example.com` - N8N UI

### Webhook Security
For N8N webhooks that need external access:
1. Use separate webhook domains (unprotected by Access)
2. Or allow specific paths: `/webhook*` on main domain

### Firewall
```bash
# Only SSH should be open to the internet
# CloudFlare tunnel handles all web traffic
ufw allow ssh
ufw deny 80,443
ufw enable
```

## 🗂️ Directory Structure

```
├── edge/                    # Traefik + CloudFlared
│   ├── docker-compose.yml
│   └── cloudflared/
│       ├── config.yml
│       └── YOUR_TUNNEL_ID.json
├── services/               # Individual services
│   ├── n8n-prod/
│   │   ├── compose.yml
│   │   └── .env
│   └── n8n-dev/
│       ├── compose.yml
│       └── .env
├── monitoring/             # Monitoring stack
│   ├── compose.yml
│   ├── prometheus/
│   └── grafana/
├── templates/             # Service templates
│   ├── n8n.yml              # N8N with AI support
│   ├── ollama.yml           # Ollama LLM service  
│   ├── qdrant.yml           # Qdrant vector database
│   ├── postgresql.yml       # PostgreSQL database
│   └── generic-app.yml      # Custom applications
└── scripts/
    └── svc               # Management CLI
```


## 🚨 Troubleshooting

### Common Issues

**Service returns 404 after update (requires Traefik restart)**:

This is a common issue where Traefik doesn't detect service updates automatically. After updating any service, you might need to restart Traefik.

**Why this happens:**
1. **Missed Docker events**: When containers are recreated, Traefik relies on Docker events to detect changes. Under load or during simultaneous updates, these events can be missed.
2. **IP address changes**: Recreated containers get new internal IP addresses, but Traefik's routing table might still point to old IPs.
3. **Stale configuration cache**: Traefik caches backend service information, and this cache doesn't always refresh on container recreation.
4. **Timing issues**: Services might restart faster than Traefik can detect the change.

**Immediate Fix:**
```bash
# Quick fix - restart Traefik to force configuration reload
docker restart edge-traefik-1

# Or restart entire edge stack
./scripts/svc edge restart
```

**Permanent Solution (already implemented):**

Your Traefik configuration has been updated with:
```yaml
# These settings ensure Traefik detects service changes reliably
- --providers.docker.watch=true           # Enable event watching
- --providers.docker.pollinterval=10s     # Poll Docker API every 10s as backup
- --providers.docker.refreshseconds=15    # Refresh configuration every 15s
```

After deploying this update, Traefik will:
- Watch Docker events in real-time
- Poll Docker API every 10 seconds as a fallback
- Refresh its configuration every 15 seconds
- Automatically detect service IP changes

**Deploy the fix:**
```bash
# Update Traefik with new configuration
cd /opt/n8n-v2/shared/edge
docker compose pull
docker compose up -d --force-recreate

# Verify Traefik is watching correctly
docker logs edge-traefik-1 2>&1 | grep -i "provider.docker"
```

**Alternative: Automated Traefik Restart**

If you still experience issues, add a post-update hook:
```bash
#!/bin/bash
# /opt/n8n-v2/shared/scripts/post-service-update.sh

SERVICE_NAME=$1

echo "Service $SERVICE_NAME updated, checking Traefik..."

# Give service time to start
sleep 5

# Test if service is accessible
if ! curl -s -o /dev/null -w "%{http_code}" https://your-service-domain.com | grep -q "200\|301\|302"; then
    echo "Service not accessible, restarting Traefik..."
    docker restart edge-traefik-1
    sleep 5
    echo "Traefik restarted"
fi
```

**Monitoring Traefik Configuration Updates:**
```bash
# Watch Traefik logs during service updates
docker logs -f edge-traefik-1

# Look for these messages:
# - "Configuration received from provider docker"
# - "Creating service" or "Updating service"
# - "Server status changed"

# Check current routing configuration
curl -s http://localhost:8080/api/http/routers | jq '.'
```

**Prevention Best Practices:**
1. **Update edge stack first**: Always ensure Traefik is on the latest version
2. **One service at a time**: Update services sequentially, not in parallel
3. **Monitor during updates**: Watch Traefik logs during service updates
4. **Health checks**: Ensure services have proper health checks configured
5. **Grace periods**: Wait 10-15 seconds between service updates

**Service not accessible**:
```bash
# Check if edge stack is running
./scripts/svc edge status

# Check service status
./scripts/svc info myservice

# Check Traefik dashboard
https://traefik.example.com
```

**Traefik not detecting service**:
- Ensure service is on `edge` network
- Check Traefik labels syntax
- Verify `traefik.enable=true` label

**CloudFlare tunnel issues**:
```bash
# Check tunnel logs
./scripts/svc edge logs

# Verify tunnel configuration
cat edge/cloudflared/config.yml
```

**N8N webhook issues**:
- Verify `WEBHOOK_URL` environment variable
- Check if CloudFlare Access is blocking webhooks
- Use separate webhook domain if needed

### Debug Commands
```bash
# Docker network inspection
docker network ls
docker network inspect edge

# Service logs
docker compose -f services/myapp/compose.yml logs -f

# Container inspection
docker inspect <container_name>
```

## 📈 Scaling

### Adding More Services
Services scale horizontally - just add more:
```bash
./scripts/svc new --name app-2 --domain app2.example.com
./scripts/svc deploy app-2
```

### Resource Management
Configure in compose files:
```yaml
deploy:
  resources:
    limits:
      memory: 1G
      cpus: '1.0'
    reservations:
      memory: 512M
      cpus: '0.5'
```

### Load Balancing
Traefik can load balance multiple containers:
```yaml
# Deploy multiple replicas
deploy:
  replicas: 3
```

## 🔧 Advanced Configuration

### Custom Traefik Middlewares
```yaml
labels:
  # Rate limiting
  - traefik.http.middlewares.myapp-ratelimit.ratelimit.average=100
  - traefik.http.middlewares.myapp-ratelimit.ratelimit.burst=200
  
  # Basic Auth
  - traefik.http.middlewares.myapp-auth.basicauth.users=user:$$2y$$10$$...
  
  # Apply middlewares
  - traefik.http.routers.myapp.middlewares=myapp-ratelimit,myapp-auth
```

### Environment-specific Configurations
Use different compose files:
```bash
# Development
docker compose -f compose.yml -f compose.dev.yml up -d

# Production  
docker compose -f compose.yml -f compose.prod.yml up -d
```

## 📚 Additional Resources

- [Traefik Documentation](https://doc.traefik.io/traefik/)
- [CloudFlare Tunnel Setup](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/)
- [N8N Documentation](https://docs.n8n.io/)
- [Docker Compose Reference](https://docs.docker.com/compose/)

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make changes and test
4. Submit a pull request

## 📄 License

MIT License - see LICENSE file for details.
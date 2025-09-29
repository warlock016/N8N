# Configuration Guide

This guide walks you through configuring this repository for your own use after downloading/cloning it.

## 🎯 Overview

This repository uses **environment variables** and **GitHub secrets** to keep sensitive information secure. After downloading, you need to:

1. Configure local environment for development/testing
2. Set up GitHub secrets for automated deployment
3. Configure CloudFlare tunnel and domain

## 📋 Prerequisites

- **VPS**: Ubuntu/Debian server with Docker and Docker Compose v2
- **Domain**: Registered domain with CloudFlare DNS management
- **CloudFlare Account**: With API access and tunnel setup
- **GitHub Repository**: Fork or private copy of this repo

## 🔧 Step 1: Local Environment Setup

### Install Dependencies

```bash
# Clone the repository (if not already done)
git clone https://github.com/your-username/your-repo-name.git
cd your-repo-name

# Install Python dependencies
pip3 install -r requirements.txt
```

### Configure Environment File

```bash
# Copy the example environment file
cp env.example .env

# Edit with your actual values
nano .env
```

Edit `.env` with your information:

```bash
# Domain Name Configuration
DOMAIN_NAME=yourdomain.com

# Cloudflare Zero Trust Tunnel Configuration & Credentials
CLOUDFLARE_TOKEN=your_cloudflare_api_token_here
ACCOUNT_TAG=your_account_tag_here
TUNNEL_SECRET=your_tunnel_secret_here
TUNNEL_ID=your_tunnel_id_here
```

> ⚠️ **Important**: Never commit the `.env` file to git. It's already in `.gitignore`.

## 🔑 Step 2: CloudFlare Setup

### 2.1 Get CloudFlare API Token

1. Go to [CloudFlare Dashboard](https://dash.cloudflare.com/profile/api-tokens)
2. Click "Create Token"
3. Use "Custom token" template with these permissions:
   - **Zone** - `Zone:Read`, `DNS:Edit`
   - **Account** - `Cloudflare Tunnel:Edit`
4. Include your specific zone
5. Copy the token to your `.env` file

### 2.2 Create CloudFlare Tunnel

```bash
# Install cloudflared CLI
# macOS:
brew install cloudflared

# Ubuntu/Debian:
wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
sudo dpkg -i cloudflared-linux-amd64.deb

# Create tunnel
cloudflared tunnel login
cloudflared tunnel create your-tunnel-name

# Get tunnel info
cloudflared tunnel list
```

Record the tunnel ID and credentials file location.

### 2.3 Configure DNS

Set up CNAME records pointing to your tunnel:

```bash
# Example DNS records to create
*.yourdomain.com     CNAME   your-tunnel-id.cfargotunnel.com
yourdomain.com       CNAME   your-tunnel-id.cfargotunnel.com
```

## 🚀 Step 3: GitHub Repository Setup

### 3.1 Create GitHub Secrets

Go to your GitHub repository → Settings → Secrets and variables → Actions

Add these **Repository Secrets**:

#### VPS Access
```
VPS_SSH_KEY=<your-private-ssh-key-content>
PRODUCTION_VPS_HOST=your.vps.ip.address
STAGING_VPS_HOST=your.vps.ip.address
```

#### CloudFlare Configuration
```
CLOUDFLARE_API_TOKEN=<your-cloudflare-api-token>
CLOUDFLARE_TUNNEL_CREDENTIALS=<tunnel-credentials-json-content>
CLOUDFLARE_TUNNEL_ID=<your-tunnel-id>
DOMAIN_NAME=yourdomain.com
```

#### Optional Notifications
```
SLACK_WEBHOOK_URL=<your-slack-webhook>
DISCORD_WEBHOOK_URL=<your-discord-webhook>
```

### 3.2 SSH Key Setup for GitHub Actions

Generate an SSH key pair specifically for automated deployment:

```bash
# Generate new SSH key pair
ssh-keygen -t rsa -b 4096 -C "github-actions@yourdomain.com" -f ~/.ssh/github-actions

# Copy public key to your VPS
ssh-copy-id -i ~/.ssh/github-actions.pub root@your-vps-ip

# Get private key content for GitHub secret
cat ~/.ssh/github-actions
```

Copy the **entire private key content** (including `-----BEGIN` and `-----END` lines) to the `VPS_SSH_KEY` secret.

## 🏗️ Step 4: VPS Preparation

### 4.1 Install Prerequisites

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# Install Docker Compose v2
sudo apt install docker-compose-plugin

# Verify installation
docker compose version
```

### 4.2 Create Directory Structure

```bash
# Create deployment directory
sudo mkdir -p /opt/n8n-v2/{releases,shared/{services,env,backups}}
sudo chown -R $USER:$USER /opt/n8n-v2
```

## 🧪 Step 5: Test Configuration

### 5.1 Test Local Scripts

```bash
# Test environment loading
./scripts/svc --help

# Test CloudFlare API connection
./scripts/cloudflare-dns-api.sh list
```

### 5.2 Test GitHub Actions

1. Push changes to your repository
2. Go to Actions tab in GitHub
3. Manually trigger "Deploy to VPS" workflow
4. Check deployment logs

## 🎉 Step 6: First Deployment

### 6.1 Deploy Edge Stack

```bash
# Trigger deployment via GitHub Actions
# Or deploy manually:

# On your VPS:
git clone https://github.com/your-username/your-repo-name.git /opt/n8n-v2/current
cd /opt/n8n-v2/current

# Create .env file on VPS
echo "DOMAIN_NAME=yourdomain.com" > .env

# Deploy edge services
docker compose -p edge -f edge/compose.yml up -d
```

### 6.2 Create First Service

```bash
# Create your first N8N instance
./scripts/svc new --name n8n-main --template n8n --domain n8n.yourdomain.com
./scripts/svc deploy n8n-main
```

## 📊 Step 7: Monitoring Setup (Optional)

Deploy the monitoring stack:

```bash
# Deploy monitoring
docker compose -p monitoring -f monitoring/compose.yml up -d

# Access dashboards:
# Grafana: https://grafana.yourdomain.com
# Prometheus: https://prometheus.yourdomain.com
```

## 🔧 Customization

### Environment Variables Used

| Variable | Purpose | Example |
|----------|---------|---------|
| `DOMAIN_NAME` | Your primary domain | `example.com` |
| `CLOUDFLARE_TOKEN` | API access | `abc123...` |
| `TUNNEL_ID` | CloudFlare tunnel ID | `fac1d753-...` |

### File Structure

```
├── .env                    # Your local config (never commit)
├── env.example            # Template for .env
├── edge/                  # Traefik + CloudFlared
│   └── cloudflared/
│       └── config.yml     # Uses ${DOMAIN_NAME}
├── monitoring/            # Prometheus + Grafana
├── scripts/               # Management scripts
└── templates/             # Service templates
```

## ❓ Troubleshooting

### Common Issues

1. **"Permission denied" SSH errors**
   - Check SSH key format in GitHub secret
   - Ensure public key is on VPS
   - Verify VPS IP is correct

2. **CloudFlare tunnel not connecting**
   - Verify tunnel credentials are correct
   - Check tunnel is active in CloudFlare dashboard
   - Ensure DNS records point to tunnel

3. **Domain not resolving**
   - DNS propagation can take up to 48 hours
   - Use `dig` to test DNS resolution
   - Check CloudFlare DNS settings

4. **Environment variables not working**
   - Ensure `.env` file exists on VPS
   - Check environment variable names match exactly
   - Verify GitHub secrets are set correctly

### Debug Commands

```bash
# Check environment loading
env | grep DOMAIN

# Test SSH connection
ssh -i ~/.ssh/github-actions root@your-vps-ip

# Check Docker services
docker compose -p edge ps
docker compose -p edge logs

# Test DNS resolution
dig +short n8n.yourdomain.com
```

## 🔒 Security Notes

- **Never commit** `.env` files or credential files
- **Rotate secrets** regularly (quarterly recommended)
- **Use least-privilege** access for API tokens
- **Monitor** CloudFlare audit logs
- **Enable** GitHub security alerts

## 📞 Support

- Check [SECURITY.md](../SECURITY.md) for security best practices
- Review [CI/CD Setup Guide](./CI_CD_SETUP_GUIDE.md) for deployment details
- Open GitHub issues for bugs or questions

---

🎉 **Congratulations!** Your N8N deployment stack is now configured and ready to use.
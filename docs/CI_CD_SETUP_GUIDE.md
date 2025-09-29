# CI/CD Pipeline Setup Guide

This guide explains how to set up automated deployment using GitHub Actions for the decoupled N8N architecture.

## Overview

The CI/CD pipeline provides:
- **Automated deployments** on push to main/production branches
- **Service management** via GitHub Actions UI
- **System health monitoring** with automated checks
- **Rollback capabilities** for failed deployments
- **Environment separation** (staging/production)

## Setup Instructions

### 1. GitHub Repository Secrets

Configure these secrets in your GitHub repository settings (`Settings > Secrets and variables > Actions`):

#### Required Secrets:
```bash
# SSH access to your VPS
VPS_SSH_KEY=<your-private-ssh-key>

# VPS connection details
PRODUCTION_VPS_HOST=your.vps.ip.address  # Your VPS IP
STAGING_VPS_HOST=your.vps.ip.address     # Same or different VPS for staging

# Optional: Notification webhooks
SLACK_WEBHOOK_URL=<your-slack-webhook>
DISCORD_WEBHOOK_URL=<your-discord-webhook>
```

#### Environment Variables (Optional):
```bash
# Set in repository variables
DEPLOYMENT_URL=https://n8n-prod.example.com

# Repository Secrets (Required):
DOMAIN_NAME=example.com                    # Your domain name
```

### 2. SSH Key Setup

Generate and configure SSH keys for automated access:

```bash
# On your local machine
ssh-keygen -t rsa -b 4096 -C "github-actions@yourdomain.com" -f ~/.ssh/github-actions

# Copy public key to VPS
ssh-copy-id -i ~/.ssh/github-actions.pub root@your-vps-ip

# Copy private key content for GitHub secret
cat ~/.ssh/github-actions
# Paste this content into VPS_SSH_KEY secret
```

### 3. VPS Preparation

Ensure your VPS has the required setup:

```bash
# SSH to your VPS
ssh root@your-vps-ip

# Ensure Docker is installed and running
docker --version
systemctl status docker

# Create necessary directories (if not already created)
mkdir -p /opt/backups

# Test Docker access
docker ps
```

### 4. GitHub Environments (Optional)

Set up GitHub environments for better control:

1. Go to `Settings > Environments`
2. Create environments: `staging`, `production`
3. Add environment-specific secrets
4. Configure protection rules (e.g., require reviews for production)

## Workflow Files

The pipeline consists of three main workflows:

### 1. Main Deployment (`deploy-to-vps.yml`)

**Triggers:**
- Push to `main` branch → deploys to staging
- Push to `production` branch → deploys to production
- Manual trigger → choice of environment

**Features:**
- ✅ Configuration validation
- ✅ Automated backup before deployment
- ✅ Zero-downtime deployment
- ✅ Health checks after deployment
- ✅ Rollback on failure

### 2. Service Management (`service-management.yml`)

**Triggers:**
- Manual trigger via GitHub Actions UI

**Actions:**
- **Create Service**: Generate new N8N or generic app
- **Deploy Service**: Deploy specific service
- **Remove Service**: Remove service and volumes
- **Restart Service**: Restart existing service

### 3. System Monitoring (`monitoring.yml`)

**Triggers:**
- Hourly schedule (automated)
- Manual trigger for immediate checks

**Checks:**
- Container health status
- Service connectivity (Traefik, CloudFlared)
- System resources (CPU, memory, disk)
- Security status (open ports, firewall)

## Usage Examples

### Deploying Changes

#### Automatic Deployment:
```bash
# Deploy to staging
git push origin main

# Deploy to production
git push origin production
```

#### Manual Deployment:
1. Go to `Actions` tab in GitHub
2. Select `Deploy to VPS`
3. Click `Run workflow`
4. Choose environment and options
5. Click `Run workflow`

### Managing Services

#### Create New N8N Instance:
1. Go to `Actions` → `Service Management`
2. Select `create-service`
3. Enter:
   - **Service name**: `n8n-client1`
   - **Domain**: `client1.example.com`
   - **Template**: `n8n`
   - **Environment**: `production`
4. Run workflow

#### Remove Service:
1. Go to `Actions` → `Service Management`
2. Select `remove-service`
3. Enter service name and environment
4. Run workflow (⚠️ This removes all data!)

### Health Monitoring

#### Manual Health Check:
1. Go to `Actions` → `System Monitoring`
2. Select check type (`full`, `services`, `performance`, `security`)
3. Choose environment
4. Run workflow

#### View Automated Checks:
- Health checks run hourly automatically
- Check `Actions` tab for results
- Failed checks can trigger notifications

## Deployment Process

### What Happens During Deployment:

1. **Pre-deployment Validation**:
   - Lint shell scripts
   - Validate Docker Compose files
   - Test service templates

2. **Backup Creation**:
   - Current system backed up to `/opt/backups/`
   - Timestamped backup directory created

3. **Service Shutdown**:
   - Existing services stopped gracefully
   - 30-second timeout for clean shutdown

4. **New Code Deployment**:
   - New code extracted to deployment directory
   - File permissions set correctly
   - Python dependencies updated

5. **Service Startup**:
   - Edge stack (Traefik + CloudFlared) started first
   - Monitoring services started
   - Individual services restarted
   - Health checks performed

6. **Post-deployment Verification**:
   - Container status checked
   - Service connectivity tested
   - Summary report generated

### Rollback Process:

If deployment fails:
1. Services stopped
2. Most recent backup restored
3. Services restarted from backup
4. Rollback confirmation

## Security Considerations

### SSH Security:
- Use dedicated SSH key for CI/CD
- Restrict SSH key to specific IP ranges if possible
- Regularly rotate SSH keys

### Secrets Management:
- Store all sensitive data in GitHub Secrets
- Use environment-specific secrets
- Never commit credentials to repository

### VPS Security:
- Keep VPS updated
- Use firewall to restrict access
- Monitor system logs
- Regular security audits

### Access Control:
- Use GitHub environments for production protection
- Require code reviews for production deployments
- Limit who can trigger manual deployments

## Monitoring and Notifications

### Built-in Monitoring:
- Automated hourly health checks
- Container health monitoring
- Resource usage tracking
- Security status verification

### Notification Setup:

#### Slack Integration:
```yaml
# Add to secrets
SLACK_WEBHOOK_URL: https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK

# Notifications sent on:
- Deployment failures
- Health check failures
- Service creation/removal
```

#### Discord Integration:
```yaml
# Add to secrets  
DISCORD_WEBHOOK_URL: https://discord.com/api/webhooks/YOUR/DISCORD/WEBHOOK

# Same notification triggers as Slack
```

#### Email Notifications:
```yaml
# Requires email service configuration
# Can use services like SendGrid, SES, etc.
```

## Troubleshooting

### Common Issues:

#### SSH Connection Failed:
```bash
# Check SSH key format
cat ~/.ssh/github-actions | head -1
# Should start with -----BEGIN OPENSSH PRIVATE KEY-----

# Test SSH access manually
ssh -i ~/.ssh/github-actions root@your-vps-ip
```

#### Deployment Timeout:
```bash
# Check VPS resources
ssh root@your-vps-ip
free -h
df -h
docker ps
```

#### Service Not Starting:
```bash
# Check service logs
ssh root@your-vps-ip
cd /opt/n8n-v2/services/service-name
docker compose logs
```

#### CloudFlared Connection Issues:
```bash
# Check tunnel logs
docker logs edge-cloudflared-1 --tail 50

# Verify tunnel configuration
cat /opt/n8n-v2/edge/cloudflared/config.yml
```

### Debug Commands:

```bash
# Check workflow execution
# GitHub Actions → Select failed workflow → View logs

# Manual deployment test
ssh root@your-vps-ip
cd /opt/n8n-v2
ls -la
docker ps
docker network ls
```

### Recovery Procedures:

#### Complete System Recovery:
```bash
# SSH to VPS
ssh root@your-vps-ip

# Find latest backup
ls -la /opt/backups/

# Restore from backup
LATEST_BACKUP=/opt/backups/n8n-backup-YYYYMMDD_HHMMSS
cp -r $LATEST_BACKUP /opt/n8n-v2

# Restart services
cd /opt/n8n-v2/edge
docker compose up -d
```

#### Service-specific Recovery:
```bash
# Restore individual service from backup
cd /opt/backups/n8n-backup-YYYYMMDD_HHMMSS/services/
cp -r service-name /opt/n8n-v2/services/

# Restart service
cd /opt/n8n-v2/services/service-name
docker compose up -d
```

## Advanced Features

### Custom Deployment Branches:
- Create `staging` branch for staging deployments
- Use `production` branch for production deployments
- Feature branches don't trigger deployments

### Service Templates:
- Add custom templates in `templates/` directory
- Modify `service-management.yml` to include new templates
- Templates support variable substitution

### Environment-specific Configuration:
- Use different docker-compose files per environment
- Environment-specific secrets and variables
- Separate VPS instances for staging/production

### Integration with External Services:
- Database migration scripts
- External API updates
- Third-party service notifications
- Custom deployment hooks

## Best Practices

### Deployment Strategy:
1. **Always test in staging first**
2. **Use feature branches for development**
3. **Review changes before production deployment**
4. **Monitor system after deployment**
5. **Keep deployment logs for troubleshooting**

### Service Management:
1. **Use descriptive service names**
2. **Document service purposes**
3. **Regular backup verification**
4. **Monitor resource usage**
5. **Clean up unused services**

### Security:
1. **Regular secret rotation**
2. **Monitor access logs**
3. **Keep VPS updated**
4. **Use least privilege access**
5. **Regular security audits**

This CI/CD pipeline transforms your N8N deployment from manual operations to fully automated, production-ready infrastructure management!
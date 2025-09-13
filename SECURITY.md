# Security Guidelines

## Overview

This document outlines security best practices for managing credentials and sensitive information in this N8N deployment project.

## GitHub Secrets Management

### Required Secrets

The following secrets must be configured in your GitHub repository settings:

1. **CLOUDFLARE_TUNNEL_CREDENTIALS** - Complete Cloudflare tunnel credentials JSON
2. **CLOUDFLARE_API_TOKEN** - Cloudflare API token with DNS:Edit permissions
3. **CLOUDFLARE_TUNNEL_ID** - Tunnel ID for the Cloudflare tunnel
4. **VPS_SSH_KEY** - SSH private key for VPS access
5. **PRODUCTION_VPS_HOST** - Production VPS hostname/IP
6. **STAGING_VPS_HOST** - Staging VPS hostname/IP (optional)

### Setting up Secrets

1. Navigate to your GitHub repository
2. Go to Settings → Secrets and variables → Actions
3. Click "New repository secret"
4. Add each required secret with the appropriate value

## Credential Rotation

### When to Rotate

Rotate credentials immediately if:
- Credentials are accidentally exposed in code or logs
- A team member with access leaves the organization
- Suspicious activity is detected
- As part of regular security maintenance (quarterly recommended)

### How to Rotate

#### Cloudflare Credentials

1. Generate new tunnel credentials in Cloudflare dashboard
2. Update GitHub secrets with new values
3. Deploy to ensure new credentials work
4. Revoke old credentials in Cloudflare

#### API Tokens

1. Generate new API token in Cloudflare with minimal required permissions
2. Update `CLOUDFLARE_API_TOKEN` secret
3. Test deployment to ensure functionality
4. Delete old token from Cloudflare

## File Security

### Excluded Files

The following files are excluded from git tracking via `.gitignore`:

- `edge/cloudflared/*.json` - Tunnel credential files
- `.env` and `*.env` - Environment files
- `*.pem`, `*.key`, `*.crt` - Certificate and key files

### Never Commit

**NEVER** commit the following to the repository:
- API tokens or keys
- SSH private keys
- Database passwords
- SSL certificates
- Any file containing sensitive credentials

## Deployment Security

### GitHub Actions

The deployment workflow:
1. Creates credential files from GitHub secrets during deployment
2. Never stores credentials in the repository
3. Uses secure environment variable passing
4. Cleans up temporary credential files after deployment

### Environment Variables

When running scripts locally, use environment variables:

```bash
export CLOUDFLARE_API_TOKEN="your_token_here"
export CLOUDFLARE_TUNNEL_ID="your_tunnel_id_here"
./scripts/cloudflare-dns-api.sh update your-domain.com
```

## Monitoring and Alerts

### Recommended Monitoring

- Enable GitHub security alerts for dependencies
- Monitor Cloudflare audit logs for unauthorized changes
- Set up alerts for failed authentication attempts on VPS
- Regular security scans of the deployed infrastructure

### Incident Response

If credentials are compromised:

1. **Immediate**: Rotate all potentially affected credentials
2. **Assess**: Review logs for unauthorized access
3. **Update**: Change all related passwords and tokens
4. **Document**: Record the incident and lessons learned
5. **Review**: Update security procedures if needed

## Best Practices

### Development

- Use environment variables for all sensitive configuration
- Never hardcode credentials in source code
- Use separate credentials for development and production
- Regularly update dependencies and base images

### Deployment

- Use least-privilege access for all services
- Enable audit logging where possible
- Regularly review and rotate credentials
- Use secure communication channels (HTTPS, SSH)

### Team Access

- Limit access to production credentials to essential personnel only
- Use individual accounts rather than shared credentials
- Implement proper offboarding procedures
- Regular access reviews and cleanups

## Contact

For security concerns or to report vulnerabilities, contact the project maintainers.

---

**Remember**: Security is everyone's responsibility. When in doubt, ask for guidance rather than compromising security.
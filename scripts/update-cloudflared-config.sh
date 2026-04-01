#!/bin/bash
set -euo pipefail

# Update CloudFlared Configuration for Docker-based Architecture
# This script manages CloudFlared configuration for Docker-only deployment

echo "🔧 Checking CloudFlared configuration for Docker-based architecture..."

# Check if we're running in Docker-only mode (no system cloudflared)
if [ ! -d "/etc/cloudflared" ]; then
    echo "✅ Docker-only CloudFlared mode detected - using repository configuration files"
    echo "📝 CloudFlared configuration is managed via Docker volumes from repository files"
    
    # Verify repository config files exist (use absolute paths from deployment root)
    DEPLOYMENT_ROOT="${DEPLOYMENT_ROOT:-$(pwd)}"
    REPO_CONFIG="$DEPLOYMENT_ROOT/edge/cloudflared/config.yml"
    REPO_CREDENTIALS="$DEPLOYMENT_ROOT/edge/cloudflared/${CLOUDFLARE_TUNNEL_ID:?CLOUDFLARE_TUNNEL_ID must be set}.json"
    
    echo "🔍 Debug: Current working directory: $(pwd)"
    echo "🔍 Debug: Deployment root: $DEPLOYMENT_ROOT"
    echo "🔍 Debug: Looking for config at: $REPO_CONFIG"
    echo "🔍 Debug: Looking for credentials at: $REPO_CREDENTIALS"
    
    if [ -f "$REPO_CONFIG" ] && [ -f "$REPO_CREDENTIALS" ]; then
        echo "✅ Repository CloudFlared configuration files found"
        echo "📋 Config: $REPO_CONFIG"
        echo "📋 Credentials: $REPO_CREDENTIALS"
    else
        echo "❌ Missing repository CloudFlared configuration files"
        echo "📂 Contents of edge directory:"
        ls -la "$DEPLOYMENT_ROOT/edge/" 2>/dev/null || echo "edge directory not found"
        echo "📂 Contents of edge/cloudflared directory:"
        ls -la "$DEPLOYMENT_ROOT/edge/cloudflared/" 2>/dev/null || echo "edge/cloudflared directory not found"
        exit 1
    fi
    
    # Skip system config update for Docker-only mode
    echo "⏭️ Skipping system CloudFlared configuration (Docker-only mode)"
else
    # Legacy system CloudFlared update (for backward compatibility)
    CLOUDFLARED_CONFIG="${CLOUDFLARED_CONFIG:-/etc/cloudflared/config.yml}"
    
    echo "🔧 Updating system CloudFlared configuration..."
    
    # Backup existing config
    if [ -f "$CLOUDFLARED_CONFIG" ]; then
        cp "$CLOUDFLARED_CONFIG" "${CLOUDFLARED_CONFIG}.backup-$(date +%Y%m%d_%H%M%S)"
        echo "✅ Backed up existing CloudFlared config"
    fi

    # Create CloudFlared configuration with concrete values
    cat > "$CLOUDFLARED_CONFIG" << 'EOF'
tunnel: ${CLOUDFLARE_TUNNEL_ID}
credentials-file: /etc/cloudflared/${CLOUDFLARE_TUNNEL_ID}.json
origincert: /etc/cloudflared/cert.pem

# Protocol settings - disable QUIC to force HTTP/2
protocol: http2

# Use Docker's DNS for service discovery
dns:
  enabled: true
  upstream:
    - "127.0.0.11"  # Docker's internal DNS

# Configure the tunnel to use the Docker network
warp-routing:
  enabled: true

# Wildcard routing - routes all subdomains to Traefik for intelligent routing
ingress:
  # Route all *.${DOMAIN_NAME} subdomains to Traefik
  - hostname: "*.${DOMAIN_NAME}"
    service: http://traefik:80
    originRequest:
      noTLSVerify: true
      httpHostHeader: "*.${DOMAIN_NAME}"
  
  # Catch-all for unmatched hostnames
  - service: http_status:404
EOF

    echo "✅ CloudFlared configuration updated for Traefik wildcard routing"
fi

# If CloudFlared is running, restart it to pick up the new config
if docker ps | grep -q cloudflared; then
    echo "🔄 Restarting CloudFlared to apply new configuration..."
    docker restart "$(docker ps -q --filter "name=cloudflared")" || true
    echo "✅ CloudFlared restarted"
fi

echo "🎉 CloudFlared configuration update completed!"
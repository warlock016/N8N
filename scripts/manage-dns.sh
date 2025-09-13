#!/bin/bash

# CloudFlared DNS Management Script
# Automatically manages DNS records for tunnel services

set -euo pipefail

# Configuration
DOMAIN_SUFFIX="${DOMAIN_SUFFIX:-automat.it.com}"
TUNNEL_ID="${TUNNEL_ID:-fac1d753-a32c-4778-9a7e-f62f48b4675b}"
TUNNEL_NAME="${TUNNEL_NAME:-n8n-tunnel}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if cloudflared is available
check_cloudflared() {
    if ! command -v cloudflared &> /dev/null; then
        log_error "cloudflared command not found. Please install cloudflared."
        exit 1
    fi
}

# Get current tunnel information
get_tunnel_info() {
    log_info "Getting tunnel information..."
    
    local tunnel_exists
    tunnel_exists=$(cloudflared tunnel list --output json | jq -r --arg tunnel_id "$TUNNEL_ID" '.[] | select(.id == $tunnel_id and .deleted_at == "0001-01-01T00:00:00Z") | .id' || echo "")
    
    if [[ -z "$tunnel_exists" ]]; then
        log_error "Tunnel $TUNNEL_ID not found or is deleted"
        log_info "Available tunnels:"
        cloudflared tunnel list
        exit 1
    fi
    
    log_success "Tunnel $TUNNEL_ID ($TUNNEL_NAME) is active"
}

# Add DNS record for a hostname
add_dns_record() {
    local hostname="$1"
    
    if [[ -z "$hostname" ]]; then
        log_error "Hostname is required"
        return 1
    fi
    
    log_info "Adding DNS record for $hostname"
    
    # Check if record already exists
    if cloudflared tunnel route dns list 2>/dev/null | grep -q "$hostname"; then
        log_warn "DNS record for $hostname already exists"
        log_info "Use --overwrite to replace existing record"
        return 0
    fi
    
    # Add the DNS record
    if cloudflared tunnel route dns "$TUNNEL_ID" "$hostname"; then
        log_success "DNS record added: $hostname -> $TUNNEL_ID.cfargotunnel.com"
    else
        log_error "Failed to add DNS record for $hostname"
        return 1
    fi
}

# Add DNS record with overwrite option
add_dns_record_force() {
    local hostname="$1"
    
    if [[ -z "$hostname" ]]; then
        log_error "Hostname is required"
        return 1
    fi
    
    log_info "Adding/updating DNS record for $hostname (with overwrite)"
    
    if cloudflared tunnel route dns --overwrite-dns "$TUNNEL_ID" "$hostname"; then
        log_success "DNS record added/updated: $hostname -> $TUNNEL_ID.cfargotunnel.com"
    else
        log_error "Failed to add/update DNS record for $hostname"
        return 1
    fi
}

# Remove DNS record
remove_dns_record() {
    local hostname="$1"
    
    if [[ -z "$hostname" ]]; then
        log_error "Hostname is required"
        return 1
    fi
    
    log_info "Removing DNS record for $hostname"
    
    # Note: cloudflared doesn't have a direct remove command for DNS routes
    # We need to use the Cloudflare API or dashboard
    log_warn "DNS record removal requires manual action via Cloudflare dashboard or API"
    log_info "Go to: https://dash.cloudflare.com/ -> DNS -> Records"
    log_info "Delete CNAME record: $hostname"
}

# List current DNS routes
list_dns_routes() {
    log_info "Current tunnel DNS routes:"
    
    # Try to list routes (may not be available in all versions)
    if cloudflared tunnel route dns list 2>/dev/null; then
        log_success "DNS routes listed above"
    else
        log_warn "Unable to list DNS routes via CLI"
        log_info "Check routes at: https://one.dash.cloudflare.com/"
    fi
}

# Deploy standard N8N service routes
deploy_n8n_routes() {
    log_info "Deploying standard N8N DNS routes..."
    
    local routes=(
        "traefik.$DOMAIN_SUFFIX"
        "n8n.$DOMAIN_SUFFIX"
        "app1.$DOMAIN_SUFFIX"
        "app2.$DOMAIN_SUFFIX"
        "test.$DOMAIN_SUFFIX"
        "monitoring.$DOMAIN_SUFFIX"
        "grafana.$DOMAIN_SUFFIX"
        "prometheus.$DOMAIN_SUFFIX"
    )
    
    local force_flag="${1:-}"
    
    for route in "${routes[@]}"; do
        if [[ "$force_flag" == "--force" ]]; then
            add_dns_record_force "$route"
        else
            add_dns_record "$route"
        fi
    done
    
    log_success "Standard N8N routes deployment complete"
}

# Auto-discover services from Docker and create DNS records
auto_discover_services() {
    log_info "Auto-discovering services from Docker labels..."
    
    # Get services with traefik labels
    local services
    services=$(docker ps --format "table {{.Names}}\t{{.Labels}}" | grep "traefik.http.routers" || echo "")
    
    if [[ -z "$services" ]]; then
        log_warn "No services with Traefik labels found"
        return 0
    fi
    
    log_info "Found services with Traefik routing:"
    echo "$services"
    
    # Extract hostnames from traefik labels
    local hostnames
    # Use perl regex with double quotes to satisfy shellcheck
    hostnames=$(docker inspect "$(docker ps -q)" --format "{{range \$label, \$value := .Config.Labels}}{{if eq \$label \"traefik.http.routers.*.rule\"}}{{\$value}}{{end}}{{end}}" 2>/dev/null | grep -oP "Host\(\\\`\\K[^\\\`]+" || echo "")
    
    if [[ -n "$hostnames" ]]; then
        while IFS= read -r hostname; do
            if [[ -n "$hostname" ]]; then
                log_info "Auto-adding DNS for discovered service: $hostname"
                add_dns_record "$hostname"
            fi
        done <<< "$hostnames"
    fi
}

# Show usage information
show_usage() {
    echo "CloudFlared DNS Management Script"
    echo ""
    echo "Usage: $0 [COMMAND] [OPTIONS]"
    echo ""
    echo "Commands:"
    echo "  add <hostname>              Add DNS record for hostname"
    echo "  add-force <hostname>        Add/overwrite DNS record for hostname"
    echo "  remove <hostname>           Remove DNS record (manual steps shown)"
    echo "  list                        List current DNS routes"
    echo "  deploy-n8n [--force]        Deploy standard N8N DNS routes"
    echo "  auto-discover               Auto-discover services and add DNS"
    echo "  tunnel-info                 Show tunnel information"
    echo ""
    echo "Environment Variables:"
    echo "  DOMAIN_SUFFIX              Domain suffix (default: automat.it.com)"
    echo "  TUNNEL_ID                  CloudFlare tunnel ID"
    echo "  TUNNEL_NAME                CloudFlare tunnel name"
    echo ""
    echo "Examples:"
    echo "  $0 add myapp.$DOMAIN_SUFFIX"
    echo "  $0 deploy-n8n --force"
    echo "  $0 auto-discover"
}

# Main function
main() {
    check_cloudflared
    
    case "${1:-help}" in
        add)
            get_tunnel_info
            add_dns_record "${2:-}"
            ;;
        add-force)
            get_tunnel_info
            add_dns_record_force "${2:-}"
            ;;
        remove)
            remove_dns_record "${2:-}"
            ;;
        list)
            get_tunnel_info
            list_dns_routes
            ;;
        deploy-n8n)
            get_tunnel_info
            deploy_n8n_routes "${2:-}"
            ;;
        auto-discover)
            get_tunnel_info
            auto_discover_services
            ;;
        tunnel-info)
            get_tunnel_info
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            log_error "Unknown command: ${1:-}"
            show_usage
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"
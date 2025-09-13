#!/bin/bash

# Cloudflare DNS API Management Script
# Manages DNS records via Cloudflare API for tunnel services

set -euo pipefail

# Configuration
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
DOMAIN_SUFFIX="${DOMAIN_SUFFIX:-automat.it.com}"
TUNNEL_ID="${TUNNEL_ID:-${CLOUDFLARE_TUNNEL_ID:-}}"
ZONE_NAME="${ZONE_NAME:-automat.it.com}"

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

# Check dependencies
check_dependencies() {
    if ! command -v curl &> /dev/null; then
        log_error "curl command not found. Please install curl."
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        log_error "jq command not found. Please install jq."
        exit 1
    fi
    
    if [[ -z "$CLOUDFLARE_API_TOKEN" ]]; then
        log_error "CLOUDFLARE_API_TOKEN is required"
        exit 1
    fi

    if [[ -z "$TUNNEL_ID" ]]; then
        log_error "TUNNEL_ID or CLOUDFLARE_TUNNEL_ID is required"
        exit 1
    fi
}

# Get Zone ID for the domain
get_zone_id() {
    local zone_id
    zone_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$ZONE_NAME" \
        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        -H "Content-Type: application/json" | \
        jq -r '.result[0].id // empty')
    
    if [[ -z "$zone_id" ]]; then
        log_error "Zone ID not found for $ZONE_NAME"
        exit 1
    fi
    
    echo "$zone_id"
}

# List DNS records for the zone
list_dns_records() {
    local zone_id="$1"
    local record_type="${2:-CNAME}"
    
    log_info "Listing $record_type records for $ZONE_NAME..."
    
    local response
    response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=$record_type" \
        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        -H "Content-Type: application/json")
    
    local success
    success=$(echo "$response" | jq -r '.success')
    
    if [[ "$success" != "true" ]]; then
        log_error "Failed to list DNS records"
        echo "$response" | jq -r '.errors[]'
        return 1
    fi
    
    echo "$response" | jq -r '.result[] | "\(.name) -> \(.content) (ID: \(.id))"'
}

# Check if DNS record exists
record_exists() {
    local zone_id="$1"
    local hostname="$2"
    
    local record_id
    record_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?name=$hostname&type=CNAME" \
        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        -H "Content-Type: application/json" | \
        jq -r '.result[0].id // empty')
    
    [[ -n "$record_id" ]]
}

# Get DNS record ID
get_record_id() {
    local zone_id="$1"
    local hostname="$2"
    
    curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?name=$hostname&type=CNAME" \
        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        -H "Content-Type: application/json" | \
        jq -r '.result[0].id // empty'
}

# Add DNS CNAME record
add_dns_record() {
    local zone_id="$1"
    local hostname="$2"
    local tunnel_target="${TUNNEL_ID}.cfargotunnel.com"
    
    log_info "Adding DNS record: $hostname -> $tunnel_target"
    
    local response
    response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{
            \"type\": \"CNAME\",
            \"name\": \"$hostname\",
            \"content\": \"$tunnel_target\",
            \"ttl\": 1,
            \"proxied\": true
        }")
    
    local success
    success=$(echo "$response" | jq -r '.success')
    
    if [[ "$success" == "true" ]]; then
        log_success "DNS record added: $hostname -> $tunnel_target"
        local record_id
        record_id=$(echo "$response" | jq -r '.result.id')
        log_info "Record ID: $record_id"
    else
        log_error "Failed to add DNS record for $hostname"
        echo "$response" | jq -r '.errors[]'
        return 1
    fi
}

# Update existing DNS CNAME record
update_dns_record() {
    local zone_id="$1"
    local hostname="$2"
    local tunnel_target="${TUNNEL_ID}.cfargotunnel.com"
    
    local record_id
    record_id=$(get_record_id "$zone_id" "$hostname")
    
    if [[ -z "$record_id" ]]; then
        log_error "DNS record not found for $hostname"
        return 1
    fi
    
    log_info "Updating DNS record: $hostname -> $tunnel_target"
    
    local response
    response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{
            \"type\": \"CNAME\",
            \"name\": \"$hostname\",
            \"content\": \"$tunnel_target\",
            \"ttl\": 1,
            \"proxied\": true
        }")
    
    local success
    success=$(echo "$response" | jq -r '.success')
    
    if [[ "$success" == "true" ]]; then
        log_success "DNS record updated: $hostname -> $tunnel_target"
    else
        log_error "Failed to update DNS record for $hostname"
        echo "$response" | jq -r '.errors[]'
        return 1
    fi
}

# Add or update DNS record
add_or_update_dns_record() {
    local zone_id="$1"
    local hostname="$2"
    
    if record_exists "$zone_id" "$hostname"; then
        log_warn "DNS record exists for $hostname, updating..."
        update_dns_record "$zone_id" "$hostname"
    else
        add_dns_record "$zone_id" "$hostname"
    fi
}

# Delete DNS record
delete_dns_record() {
    local zone_id="$1"
    local hostname="$2"
    
    local record_id
    record_id=$(get_record_id "$zone_id" "$hostname")
    
    if [[ -z "$record_id" ]]; then
        log_error "DNS record not found for $hostname"
        return 1
    fi
    
    log_info "Deleting DNS record: $hostname"
    
    local response
    response=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        -H "Content-Type: application/json")
    
    local success
    success=$(echo "$response" | jq -r '.success')
    
    if [[ "$success" == "true" ]]; then
        log_success "DNS record deleted: $hostname"
    else
        log_error "Failed to delete DNS record for $hostname"
        echo "$response" | jq -r '.errors[]'
        return 1
    fi
}

# Deploy standard N8N service routes
deploy_standard_routes() {
    local zone_id="$1"
    local force="${2:-false}"
    
    log_info "Deploying standard N8N DNS routes for tunnel $TUNNEL_ID..."
    
    local routes=(
        "traefik.$DOMAIN_SUFFIX"
        "n8n.$DOMAIN_SUFFIX"
        "app1.$DOMAIN_SUFFIX"
        "app2.$DOMAIN_SUFFIX"
        "test.$DOMAIN_SUFFIX"
        "monitoring.$DOMAIN_SUFFIX"
        "grafana.$DOMAIN_SUFFIX"
        "prometheus.$DOMAIN_SUFFIX"
        "ollama.$DOMAIN_SUFFIX"
        "qdrant.$DOMAIN_SUFFIX"
    )
    
    for route in "${routes[@]}"; do
        if [[ "$force" == "true" ]] || ! record_exists "$zone_id" "$route"; then
            add_or_update_dns_record "$zone_id" "$route"
        else
            log_info "DNS record already exists for $route (use --force to update)"
        fi
    done
    
    log_success "Standard N8N routes deployment complete"
}

# Auto-discover services from running Docker containers
auto_discover_services() {
    local zone_id="$1"
    
    log_info "Auto-discovering services from Docker containers..."
    
    # Check if docker is available
    if ! command -v docker &> /dev/null; then
        log_error "Docker command not found"
        return 1
    fi
    
    # Get hostnames from Traefik labels
    local hostnames
    # Use perl regex with double quotes to satisfy shellcheck
    hostnames=$(docker ps --format "{{.Names}}" | xargs -I {} docker inspect {} --format "{{range \$label, \$value := .Config.Labels}}{{if contains \"traefik.http.routers\" \$label}}{{if contains \".rule\" \$label}}{{\$value}}{{end}}{{end}}{{end}}" 2>/dev/null | grep -oP "Host\(\\\`\\K[^\\\`]+" || echo "")
    
    if [[ -n "$hostnames" ]]; then
        log_info "Discovered services:"
        echo "$hostnames" | while IFS= read -r hostname; do
            if [[ -n "$hostname" ]]; then
                log_info "  - $hostname"
                add_or_update_dns_record "$zone_id" "$hostname"
            fi
        done
    else
        log_warn "No services with Traefik Host rules found"
    fi
}

# Show current tunnel target for comparison
show_tunnel_info() {
    log_info "Current tunnel configuration:"
    log_info "  Tunnel ID: $TUNNEL_ID"
    log_info "  Tunnel Target: ${TUNNEL_ID}.cfargotunnel.com"
    log_info "  Domain: $DOMAIN_SUFFIX"
    log_info "  Zone: $ZONE_NAME"
}

# Show usage
show_usage() {
    echo "Cloudflare DNS API Management Script"
    echo ""
    echo "Usage: $0 [COMMAND] [OPTIONS]"
    echo ""
    echo "Commands:"
    echo "  list                        List current CNAME records"
    echo "  add <hostname>              Add DNS CNAME record"
    echo "  update <hostname>           Update existing DNS record"
    echo "  add-or-update <hostname>    Add or update DNS record"
    echo "  delete <hostname>           Delete DNS record"
    echo "  deploy [--force]            Deploy standard N8N routes"
    echo "  auto-discover               Auto-discover and add service routes"
    echo "  tunnel-info                 Show tunnel information"
    echo ""
    echo "Environment Variables:"
    echo "  CLOUDFLARE_API_TOKEN        Cloudflare API token (required)"
    echo "  DOMAIN_SUFFIX               Domain suffix (default: automat.it.com)"
    echo "  TUNNEL_ID                   CloudFlare tunnel ID"
    echo "  ZONE_NAME                   Cloudflare zone name (default: automat.it.com)"
    echo ""
    echo "Examples:"
    echo "  $0 list"
    echo "  $0 add myapp.$DOMAIN_SUFFIX"
    echo "  $0 deploy --force"
    echo "  $0 auto-discover"
}

# Main function
main() {
    check_dependencies
    
    local zone_id
    
    case "${1:-help}" in
        list)
            zone_id=$(get_zone_id)
            list_dns_records "$zone_id"
            ;;
        add)
            zone_id=$(get_zone_id)
            add_dns_record "$zone_id" "${2:-}"
            ;;
        update)
            zone_id=$(get_zone_id)
            update_dns_record "$zone_id" "${2:-}"
            ;;
        add-or-update)
            zone_id=$(get_zone_id)
            add_or_update_dns_record "$zone_id" "${2:-}"
            ;;
        delete)
            zone_id=$(get_zone_id)
            delete_dns_record "$zone_id" "${2:-}"
            ;;
        deploy)
            zone_id=$(get_zone_id)
            local force="false"
            [[ "${2:-}" == "--force" ]] && force="true"
            deploy_standard_routes "$zone_id" "$force"
            ;;
        auto-discover)
            zone_id=$(get_zone_id)
            auto_discover_services "$zone_id"
            ;;
        tunnel-info)
            show_tunnel_info
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
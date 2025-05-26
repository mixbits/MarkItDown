#!/bin/bash

# MarkItDown Web Application - Cloudflare Tunnel Deployment Script
# Interactive configuration for custom domains and tunnel setup

set -euo pipefail

# Function to prompt for user input with validation
prompt_input() {
    local prompt="$1"
    local default="$2"
    local validation_func="$3"
    local value
    
    while true; do
        if [[ -n "$default" ]]; then
            read -p "$prompt [$default]: " value
            value="${value:-$default}"
        else
            read -p "$prompt: " value
        fi
        
        if [[ -n "$validation_func" ]] && ! $validation_func "$value"; then
            echo "Invalid input. Please try again."
            continue
        fi
        
        echo "$value"
        return 0
    done
}

# Validation functions
validate_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]*\.[a-zA-Z]{2,}$ ]]
}

validate_path() {
    local path="$1"
    [[ "$path" =~ ^/[a-zA-Z0-9/_-]+$ ]]
}

validate_tunnel_token() {
    local token="$1"
    [[ ${#token} -gt 50 ]] && [[ "$token" =~ ^eyJ ]]
}

validate_tunnel_id() {
    local id="$1"
    [[ "$id" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]
}

# Interactive configuration
configure_tunnel() {
    echo "=========================================="
    echo "MarkItDown Web Application - Tunnel Setup"
    echo "=========================================="
    echo
    echo "Please provide the following configuration:"
    echo
    
    # Get project directory
    PROJECT_DIR=$(prompt_input "Enter project directory path" "/volume1/web/markitdown" "validate_path")
    
    # Get domain information
    DOMAIN=$(prompt_input "Enter your domain name (e.g., example.com)" "" "validate_domain")
    
    # Get tunnel information
    echo
    echo "Cloudflare Tunnel Configuration:"
    echo "You can find these values in your Cloudflare dashboard under Zero Trust > Access > Tunnels"
    echo
    
    TUNNEL_TOKEN=$(prompt_input "Enter your Cloudflare tunnel token" "" "validate_tunnel_token")
    TUNNEL_ID=$(prompt_input "Enter your tunnel ID (UUID format)" "" "validate_tunnel_id")
    TUNNEL_NAME=$(prompt_input "Enter tunnel name" "markitdown" "")
    
    # Get port
    LOCAL_PORT=$(prompt_input "Enter local port" "8008" "")
    
    echo
    echo "Configuration Summary:"
    echo "====================="
    echo "Project Directory: $PROJECT_DIR"
    echo "Domain: $DOMAIN"
    echo "Tunnel Name: $TUNNEL_NAME"
    echo "Tunnel ID: $TUNNEL_ID"
    echo "Local Port: $LOCAL_PORT"
    echo "Main URL: https://markitdown.$DOMAIN"
    echo "Health URL: https://health.markitdown.$DOMAIN"
    echo "API URL: https://api.markitdown.$DOMAIN"
    echo
    
    read -p "Continue with this configuration? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Tunnel setup cancelled."
        exit 0
    fi
}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_header() {
    echo -e "\n${PURPLE}========================================${NC}"
    echo -e "${PURPLE}$1${NC}"
    echo -e "${PURPLE}========================================${NC}\n"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Install cloudflared
install_cloudflared() {
    log_info "Checking cloudflared installation..."
    
    if command -v cloudflared &> /dev/null; then
        local version=$(cloudflared version 2>/dev/null || cloudflared --version 2>/dev/null || echo "unknown")
        log_success "cloudflared is already installed: $version"
        return 0
    fi
    
    log_info "Installing cloudflared..."
    cd /tmp
    wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O cloudflared
    chmod +x cloudflared
    mv cloudflared /usr/local/bin/
    
    if command -v cloudflared &> /dev/null; then
        log_success "cloudflared installed successfully"
    else
        log_error "Failed to install cloudflared"
        exit 1
    fi
}

# Generate tunnel configuration file
generate_tunnel_config() {
    log_info "Generating tunnel configuration file..."
    
    cat > "${PROJECT_DIR}/cloudflare-tunnel.yml" << EOF
# Cloudflare Tunnel Configuration for MarkItDown Web Application
tunnel: ${TUNNEL_ID}
credentials-file: ${PROJECT_DIR}/tunnel-credentials.json

# Ingress Rules
ingress:
  # Main application route
  - hostname: markitdown.${DOMAIN}
    service: http://localhost:${LOCAL_PORT}
    originRequest:
      connectTimeout: 30s
      tlsTimeout: 30s
      tcpKeepAlive: 30s
      keepAliveConnections: 10
      keepAliveTimeout: 90s
      httpHostHeader: markitdown.${DOMAIN}
      disableChunkedEncoding: false
      noTLSVerify: true
  
  # Health check endpoint
  - hostname: health.markitdown.${DOMAIN}
    service: http://localhost:${LOCAL_PORT}/health
    originRequest:
      connectTimeout: 10s
      tlsTimeout: 10s
  
  # API endpoints
  - hostname: api.markitdown.${DOMAIN}
    service: http://localhost:${LOCAL_PORT}
    originRequest:
      connectTimeout: 30s
      tlsTimeout: 30s
      httpHostHeader: api.markitdown.${DOMAIN}
  
  # Catch-all rule (required)
  - service: http_status:404

# Tunnel Options
warp-routing:
  enabled: false

# Logging Configuration
loglevel: info
logfile: ${PROJECT_DIR}/logs/cloudflared.log

# Metrics (optional)
metrics: localhost:8081

# Auto-update (optional)
autoupdate-freq: 24h

# Performance settings
retries: 3
grace-period: 30s
EOF
    
    log_success "Tunnel configuration generated at ${PROJECT_DIR}/cloudflare-tunnel.yml"
}

# Generate environment file
generate_tunnel_env() {
    log_info "Generating tunnel environment file..."
    
    cat > "${PROJECT_DIR}/tunnel.env" << EOF
# MarkItDown Web Application - Cloudflare Tunnel Environment Configuration

# Cloudflare Tunnel Token
TUNNEL_TOKEN="${TUNNEL_TOKEN}"

# Tunnel Configuration
TUNNEL_ID="${TUNNEL_ID}"
TUNNEL_NAME="${TUNNEL_NAME}"

# Domain Configuration
PRIMARY_DOMAIN="markitdown.${DOMAIN}"
HEALTH_DOMAIN="health.markitdown.${DOMAIN}"
API_DOMAIN="api.markitdown.${DOMAIN}"

# Local Service Configuration
LOCAL_HOST="localhost"
LOCAL_PORT="${LOCAL_PORT}"

# Project Paths
PROJECT_DIR="${PROJECT_DIR}"
TUNNEL_CONFIG_FILE="${PROJECT_DIR}/cloudflare-tunnel.yml"
TUNNEL_CREDENTIALS="${PROJECT_DIR}/tunnel-credentials.json"
TUNNEL_LOG_FILE="${PROJECT_DIR}/logs/cloudflared.log"

# Quick Setup Commands
# Install tunnel: cloudflared service install \$TUNNEL_TOKEN
# Start tunnel: systemctl start cloudflared
# Check status: systemctl status cloudflared
# View logs: journalctl -u cloudflared -f
EOF
    
    log_success "Tunnel environment file generated at ${PROJECT_DIR}/tunnel.env"
}

# Setup tunnel service
setup_tunnel_service() {
    log_info "Setting up Cloudflare tunnel service..."
    
    # Stop existing tunnel if running
    systemctl stop cloudflared 2>/dev/null || true
    
    # Install tunnel service with token
    log_info "Installing tunnel service..."
    cloudflared service install "$TUNNEL_TOKEN"
    
    # Start and enable tunnel service
    log_info "Starting and enabling tunnel service..."
    systemctl daemon-reload
    systemctl enable cloudflared
    systemctl start cloudflared
    
    # Wait a moment for service to start
    sleep 3
    
    # Check service status
    if systemctl is-active cloudflared &>/dev/null; then
        log_success "Cloudflare tunnel service is running"
    else
        log_warning "Tunnel service may not have started properly"
        log_info "Check status with: systemctl status cloudflared"
    fi
}

# Verify tunnel configuration
verify_tunnel() {
    log_info "Verifying tunnel configuration..."
    
    # Check tunnel connectivity
    log_info "Testing tunnel connectivity..."
    if cloudflared tunnel info "$TUNNEL_ID" &>/dev/null; then
        log_success "Tunnel connectivity verified"
    else
        log_warning "Unable to verify tunnel connectivity"
    fi
    
    # Check if MarkItDown service is running
    if systemctl is-active markitdown.service &>/dev/null; then
        log_success "MarkItDown service is running"
    else
        log_warning "MarkItDown service is not running"
        log_info "Start it with: systemctl start markitdown.service"
    fi
}

# Deploy MarkItDown application
deploy_application() {
    log_header "Deploying MarkItDown Web Application"
    
    if [[ -f "./deploy.sh" ]]; then
        log_info "Running main deployment script..."
        chmod +x ./deploy.sh
        export BASE_DIR="$(dirname "$PROJECT_DIR")"
        export DOMAIN="$DOMAIN"
        export PORT="$LOCAL_PORT"
        export APP_NAME="markitdown"
        ./deploy.sh --non-interactive
    else
        log_error "deploy.sh not found. Please ensure you're in the project directory."
        exit 1
    fi
}

# Complete tunnel setup
setup_tunnel() {
    log_header "Setting Up Cloudflare Tunnel"
    
    check_root
    install_cloudflared
    generate_tunnel_config
    generate_tunnel_env
    setup_tunnel_service
    verify_tunnel
}

# Start tunnel service
start_tunnel() {
    log_info "Starting Cloudflare tunnel..."
    systemctl start cloudflared
    sleep 2
    
    if systemctl is-active cloudflared &>/dev/null; then
        log_success "Tunnel started successfully"
        systemctl status cloudflared --no-pager
    else
        log_error "Failed to start tunnel"
        systemctl status cloudflared --no-pager
        exit 1
    fi
}

# Stop tunnel service
stop_tunnel() {
    log_info "Stopping Cloudflare tunnel..."
    systemctl stop cloudflared
    
    if ! systemctl is-active cloudflared &>/dev/null; then
        log_success "Tunnel stopped successfully"
    else
        log_warning "Tunnel may still be running"
    fi
    systemctl status cloudflared --no-pager
}

# Restart tunnel service
restart_tunnel() {
    log_info "Restarting Cloudflare tunnel..."
    systemctl restart cloudflared
    sleep 3
    
    if systemctl is-active cloudflared &>/dev/null; then
        log_success "Tunnel restarted successfully"
        systemctl status cloudflared --no-pager
    else
        log_error "Failed to restart tunnel"
        systemctl status cloudflared --no-pager
        exit 1
    fi
}

# Show comprehensive tunnel status
show_tunnel_status() {
    log_header "Cloudflare Tunnel Status"
    
    echo "Service Status:"
    systemctl status cloudflared --no-pager -l || true
    echo
    
    echo "Recent Logs:"
    journalctl -u cloudflared -n 10 --no-pager || true
    echo
    
    if [[ -f "${PROJECT_DIR:-/volume1/web/markitdown}/tunnel.env" ]]; then
        source "${PROJECT_DIR:-/volume1/web/markitdown}/tunnel.env"
        echo "Tunnel Information:"
        echo "  Tunnel ID: ${TUNNEL_ID:-Not configured}"
        echo "  Tunnel Name: ${TUNNEL_NAME:-Not configured}"
        echo "  Local Port: ${LOCAL_PORT:-Not configured}"
        echo
        
        echo "Access URLs:"
        echo "  🌐 Main App: https://${PRIMARY_DOMAIN:-markitdown.example.com}"
        echo "  🏥 Health Check: https://${HEALTH_DOMAIN:-health.markitdown.example.com}"
        echo "  🔌 API Access: https://${API_DOMAIN:-api.markitdown.example.com}"
        echo "  🏠 Local: http://localhost:${LOCAL_PORT:-8008}"
        echo
    else
        echo "Tunnel configuration not found. Run setup first."
        echo
    fi
    
    # Test connectivity
    echo "Connectivity Tests:"
    local port="${LOCAL_PORT:-8008}"
    if curl -f "http://localhost:$port/health" &>/dev/null; then
        echo "  ✅ Local health check: PASSED"
    else
        echo "  ❌ Local health check: FAILED"
    fi
}

# Show tunnel logs in real-time
show_tunnel_logs() {
    log_info "Showing tunnel logs (Ctrl+C to exit)..."
    journalctl -u cloudflared -f
}

# Verify complete deployment
verify_deployment() {
    log_header "Verifying Complete Deployment"
    
    # Check MarkItDown service
    if systemctl is-active markitdown.service &>/dev/null; then
        log_success "✅ MarkItDown service is running"
    else
        log_error "❌ MarkItDown service is not running"
    fi
    
    # Check tunnel service
    if systemctl is-active cloudflared &>/dev/null; then
        log_success "✅ Cloudflare tunnel is running"
    else
        log_error "❌ Cloudflare tunnel is not running"
    fi
    
    # Test local health endpoint
    local port="${LOCAL_PORT:-8008}"
    if curl -f "http://localhost:$port/health" &>/dev/null; then
        log_success "✅ Local health check passed"
    else
        log_error "❌ Local health check failed"
    fi
}

# Show deployment summary
show_deployment_summary() {
    log_header "Complete Deployment Summary"
    
    if [[ -f "${PROJECT_DIR:-/volume1/web/markitdown}/tunnel.env" ]]; then
        source "${PROJECT_DIR:-/volume1/web/markitdown}/tunnel.env"
    fi
    
    echo "🎉 MarkItDown Web Application deployment complete!"
    echo
    echo "📋 Service Status:"
    echo "   MarkItDown: $(systemctl is-active markitdown.service 2>/dev/null || echo 'stopped')"
    echo "   Cloudflare Tunnel: $(systemctl is-active cloudflared 2>/dev/null || echo 'stopped')"
    echo
    echo "🌐 Access URLs:"
    echo "   Main App: https://${PRIMARY_DOMAIN:-markitdown.example.com}"
    echo "   Health Check: https://${HEALTH_DOMAIN:-health.markitdown.example.com}"
    echo "   API Access: https://${API_DOMAIN:-api.markitdown.example.com}"
    echo "   Local: http://localhost:${LOCAL_PORT:-8008}"
    echo
    echo "🔧 Management Commands:"
    echo "   Application:"
    echo "     sudo systemctl [start|stop|restart|status] markitdown.service"
    echo "   Tunnel:"
    echo "     sudo $0 [start|stop|restart|status|logs]"
    echo "   Complete:"
    echo "     sudo $0 deploy    # Deploy both app and tunnel"
    echo "     sudo $0 verify    # Verify deployment"
    echo
    echo "📁 Project Directory: ${PROJECT_DIR:-/volume1/web/markitdown}"
    echo "🚀 Welcome to MarkItDown Web Application!"
}

# Show usage information
show_usage() {
    cat << EOF

MarkItDown Web Application - Cloudflare Tunnel Deployment Script
================================================================

USAGE: $0 [COMMAND]

TUNNEL COMMANDS:
    setup       Install and configure Cloudflare tunnel (interactive)
    start       Start tunnel service
    stop        Stop tunnel service
    restart     Restart tunnel service
    status      Show tunnel status and connectivity
    logs        Show tunnel logs (real-time)

DEPLOYMENT COMMANDS:
    deploy      Complete deployment (app + tunnel) - interactive setup
    app-only    Deploy MarkItDown application only
    verify      Verify complete deployment status
    summary     Show deployment summary

EXAMPLES:
    # Complete deployment with interactive setup
    sudo $0 deploy

    # Tunnel management
    sudo $0 setup
    sudo $0 start
    sudo $0 status
    $0 logs

    # Verification
    $0 verify
    $0 summary

CONFIGURATION:
    The script will prompt for:
    - Domain name
    - Project directory path
    - Cloudflare tunnel token
    - Tunnel ID
    - Local port

For troubleshooting:
    journalctl -u cloudflared -f
    systemctl status cloudflared

EOF
}

# Main function
main() {
    case "${1:-}" in
        "deploy")
            log_info "Starting complete MarkItDown Web Application deployment..."
            check_root
            configure_tunnel
            deploy_application
            setup_tunnel
            verify_deployment
            show_deployment_summary
            ;;
        "app-only")
            log_info "Deploying MarkItDown application only..."
            check_root
            configure_tunnel
            deploy_application
            ;;
        "setup")
            configure_tunnel
            setup_tunnel
            show_tunnel_status
            ;;
        "start")
            start_tunnel
            ;;
        "stop")
            stop_tunnel
            ;;
        "restart")
            restart_tunnel
            ;;
        "status")
            show_tunnel_status
            ;;
        "logs")
            show_tunnel_logs
            ;;
        "verify")
            verify_deployment
            ;;
        "summary")
            show_deployment_summary
            ;;
        *)
            show_usage
            ;;
    esac
}

# Run main function with all arguments
main "$@" 
#!/bin/bash

# MarkItDown Web Application - Production Deployment Script
# Interactive configuration for custom domains and directories

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

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1024 ]] && [[ "$port" -le 65535 ]]
}

validate_app_name() {
    local name="$1"
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]
}

# Interactive configuration
configure_deployment() {
    echo "=========================================="
    echo "MarkItDown Web Application - Deployment Setup"
    echo "=========================================="
    echo
    echo "Please provide the following configuration:"
    echo
    
    # Get base directory (parent of markitdown folder)
    BASE_DIR=$(prompt_input "Enter base directory path (markitdown folder will be created here)" "/volume1/web" "validate_path")
    PROJECT_DIR="${BASE_DIR}/markitdown"
    
    # Get domain information
    DOMAIN=$(prompt_input "Enter your domain name (e.g., example.com)" "" "validate_domain")
    
    # Get port
    PORT=$(prompt_input "Enter port number" "8008" "validate_port")
    
    # Get app name (for service)
    APP_NAME=$(prompt_input "Enter application name (for systemd service)" "markitdown" "validate_app_name")
    
    echo
    echo "Configuration Summary:"
    echo "====================="
    echo "Base Directory: $BASE_DIR"
    echo "Project Directory: $PROJECT_DIR"
    echo "Domain: $DOMAIN"
    echo "Port: $PORT"
    echo "App Name: $APP_NAME"
    echo "Main URL: https://markitdown.$DOMAIN"
    echo "Health URL: https://health.markitdown.$DOMAIN"
    echo "API URL: https://api.markitdown.$DOMAIN"
    echo
    
    read -p "Continue with this configuration? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Deployment cancelled."
        exit 0
    fi
}

# Run configuration if not in non-interactive mode
if [[ "${1:-}" != "--non-interactive" ]]; then
    configure_deployment
else
    # Default values for non-interactive mode
    BASE_DIR="${BASE_DIR:-/volume1/web}"
    PROJECT_DIR="${BASE_DIR}/markitdown"
    DOMAIN="${DOMAIN:-example.com}"
    PORT="${PORT:-8008}"
    APP_NAME="${APP_NAME:-markitdown}"
fi

# Script Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_VERSION="3.8"
VENV_DIR="${PROJECT_DIR}/venv"
SERVICE_NAME="${APP_NAME}.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
LOG_DIR="${PROJECT_DIR}/logs"
MODELS_DIR="${PROJECT_DIR}/models"
EASYOCR_DIR="${MODELS_DIR}/easyocr"
SESSIONS_DIR="${PROJECT_DIR}/sessions"
TMP_DIR="${PROJECT_DIR}/tmp"
BACKUP_DIR="${PROJECT_DIR}/backups"

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

# Detect system information
detect_system() {
    log_header "System Detection"
    
    # Detect OS
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_NAME="$NAME"
        OS_VERSION="$VERSION"
    else
        OS_NAME="Unknown"
        OS_VERSION="Unknown"
    fi
    
    # Detect architecture
    ARCH=$(uname -m)
    
    # Detect if running on Synology
    if [[ -f /etc/synoinfo.conf ]]; then
        IS_SYNOLOGY=true
        SYNO_MODEL=$(grep "upnpmodelname" /etc/synoinfo.conf | cut -d'"' -f2 2>/dev/null || echo "Unknown")
        log_info "Detected Synology NAS: $SYNO_MODEL"
    else
        IS_SYNOLOGY=false
    fi
    
    # Set web user/group based on system
    if [[ "$IS_SYNOLOGY" == true ]]; then
        WEB_USER="http"
        WEB_GROUP="http"
    elif command -v nginx &> /dev/null; then
        WEB_USER="nginx"
        WEB_GROUP="nginx"
    elif command -v apache2 &> /dev/null; then
        WEB_USER="www-data"
        WEB_GROUP="www-data"
    else
        WEB_USER="http"
        WEB_GROUP="http"
    fi
    
    log_info "Operating System: $OS_NAME $OS_VERSION"
    log_info "Architecture: $ARCH"
    log_info "Web User/Group: $WEB_USER:$WEB_GROUP"
    log_info "Synology NAS: $IS_SYNOLOGY"
}

# Create project directory structure
create_directories() {
    log_header "Creating Directory Structure"
    
    # Create base directory if it doesn't exist
    if [[ ! -d "$BASE_DIR" ]]; then
        log_info "Creating base directory: $BASE_DIR"
        mkdir -p "$BASE_DIR"
    fi
    
    # Create project directory
    log_info "Creating project directory: $PROJECT_DIR"
    mkdir -p "$PROJECT_DIR"
    
    # Create subdirectories
    local dirs=("$LOG_DIR" "$MODELS_DIR" "$EASYOCR_DIR" "$SESSIONS_DIR" "$TMP_DIR" "$BACKUP_DIR")
    for dir in "${dirs[@]}"; do
        log_info "Creating directory: $dir"
        mkdir -p "$dir"
    done
    
    # Copy project files to the new directory
    log_info "Copying project files..."
    cp -r "$SCRIPT_DIR"/* "$PROJECT_DIR/" 2>/dev/null || true
    
    # Set ownership and permissions
    log_info "Setting directory permissions..."
    chown -R "$WEB_USER:$WEB_GROUP" "$PROJECT_DIR"
    chmod -R 755 "$PROJECT_DIR"
    
    # Set special permissions for writable directories
    chmod 777 "$EASYOCR_DIR" "$SESSIONS_DIR" "$TMP_DIR" "$LOG_DIR"
    
    log_success "Directory structure created successfully"
}

# Install system dependencies
install_system_dependencies() {
    log_header "Installing System Dependencies"
    
    # Update package list
    log_info "Updating package list..."
    if command -v apt-get &> /dev/null; then
        apt-get update
    elif command -v yum &> /dev/null; then
        yum update -y
    elif command -v pacman &> /dev/null; then
        pacman -Sy
    fi
    
    # Install required packages
    local packages=("python3" "python3-pip" "python3-venv" "curl" "wget" "unzip")
    
    for package in "${packages[@]}"; do
        log_info "Installing $package..."
        if command -v apt-get &> /dev/null; then
            apt-get install -y "$package" || log_warning "Failed to install $package"
        elif command -v yum &> /dev/null; then
            yum install -y "$package" || log_warning "Failed to install $package"
        elif command -v pacman &> /dev/null; then
            pacman -S --noconfirm "$package" || log_warning "Failed to install $package"
        fi
    done
    
    log_success "System dependencies installed"
}

# Setup Python virtual environment
setup_python_environment() {
    log_header "Setting Up Python Environment"
    
    cd "$PROJECT_DIR"
    
    # Create virtual environment
    log_info "Creating Python virtual environment..."
    python3 -m venv "$VENV_DIR"
    
    # Activate virtual environment
    source "$VENV_DIR/bin/activate"
    
    # Upgrade pip
    log_info "Upgrading pip..."
    pip install --upgrade pip
    
    # Install requirements
    if [[ -f "requirements.txt" ]]; then
        log_info "Installing Python dependencies..."
        pip install -r requirements.txt
    else
        log_error "requirements.txt not found!"
        exit 1
    fi
    
    log_success "Python environment setup complete"
}

# Create systemd service file
create_systemd_service() {
    log_header "Creating Systemd Service"
    
    log_info "Generating systemd service file..."
    
    # Create service file with actual values
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=MarkItDown Web Application - Document Conversion Service
After=network.target
Wants=network.target

[Service]
Type=simple
User=$WEB_USER
Group=$WEB_GROUP
WorkingDirectory=$PROJECT_DIR
Environment="PATH=$PROJECT_DIR/venv/bin:/usr/local/bin:/usr/bin:/bin"
Environment="VIRTUAL_ENV=$PROJECT_DIR/venv"
Environment="PYTHONPATH=$PROJECT_DIR"
Environment="PYTHONUNBUFFERED=1"
Environment="HOME=$PROJECT_DIR"
Environment="OPENCV_IO_ENABLE_OPENEXR=0"
Environment="DISPLAY="
Environment="EASYOCR_MODULE_PATH=$EASYOCR_DIR"
Environment="SESSION_FILE_DIR=$SESSIONS_DIR"
Environment="TMPDIR=$TMP_DIR"
ExecStart=$PROJECT_DIR/venv/bin/python app.py
Restart=always
RestartSec=10
StandardOutput=append:$LOG_DIR/markitdown.log
StandardError=append:$LOG_DIR/markitdown.log

# Security settings
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=$PROJECT_DIR

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload systemd and enable service
    log_info "Reloading systemd daemon..."
    systemctl daemon-reload
    
    log_info "Enabling service..."
    systemctl enable "$SERVICE_NAME"
    
    log_success "Systemd service created and enabled"
}

# Create helper scripts
create_helper_scripts() {
    log_header "Creating Helper Scripts"
    
    # Create health check script
    log_info "Creating health check script..."
    cat > "${PROJECT_DIR}/health_check.sh" << EOF
#!/bin/bash
curl -f http://localhost:$PORT/health || echo "Health check failed"
EOF
    
    # Create start script
    log_info "Creating start script..."
    cat > "${PROJECT_DIR}/start.sh" << EOF
#!/bin/bash
cd $PROJECT_DIR
sudo systemctl start $SERVICE_NAME
sudo systemctl status $SERVICE_NAME
EOF
    
    # Create stop script
    log_info "Creating stop script..."
    cat > "${PROJECT_DIR}/stop.sh" << EOF
#!/bin/bash
sudo systemctl stop $SERVICE_NAME
sudo systemctl status $SERVICE_NAME
EOF
    
    # Create status script
    log_info "Creating status script..."
    cat > "${PROJECT_DIR}/status.sh" << EOF
#!/bin/bash
echo "=== Service Status ==="
sudo systemctl status $SERVICE_NAME

echo -e "\n=== Recent Logs ==="
tail -n 20 $LOG_DIR/markitdown.log

echo -e "\n=== Health Check ==="
curl -f http://localhost:$PORT/health 2>/dev/null || echo "Service not responding"
EOF
    
    # Create deployment info script
    log_info "Creating deployment info script..."
    cat > "${PROJECT_DIR}/info.sh" << EOF
#!/bin/bash
echo "MarkItDown Web Application - Deployment Information"
echo "==========================================="
echo "Project Directory: $PROJECT_DIR"
echo "Service Name: $SERVICE_NAME"
echo "Port: $PORT"
echo "Domain: markitdown.$DOMAIN"
echo "Health Check: health.markitdown.$DOMAIN"
echo "API Access: api.markitdown.$DOMAIN"
echo ""
echo "Management Commands:"
echo "  Start:   sudo systemctl start $SERVICE_NAME"
echo "  Stop:    sudo systemctl stop $SERVICE_NAME" 
echo "  Restart: sudo systemctl restart $SERVICE_NAME"
echo "  Status:  sudo systemctl status $SERVICE_NAME"
echo "  Logs:    tail -f $LOG_DIR/markitdown.log"
EOF
    
    # Make scripts executable
    chmod +x "${PROJECT_DIR}"/*.sh
    chown "$WEB_USER:$WEB_GROUP" "${PROJECT_DIR}"/*.sh
    
    log_success "Helper scripts created successfully"
}

# Start the service
start_service() {
    log_header "Starting MarkItDown Service"
    
    log_info "Starting $SERVICE_NAME..."
    systemctl start "$SERVICE_NAME"
    
    # Wait a moment for service to start
    sleep 3
    
    # Check if service is running
    if systemctl is-active "$SERVICE_NAME" &>/dev/null; then
        log_success "Service started successfully"
        
        # Test health endpoint
        log_info "Testing health endpoint..."
        if curl -f "http://localhost:$PORT/health" &>/dev/null; then
            log_success "Health check passed"
        else
            log_warning "Health check failed - service may still be starting"
        fi
    else
        log_error "Failed to start service"
        log_info "Checking service status..."
        systemctl status "$SERVICE_NAME" --no-pager
        exit 1
    fi
}

# Create environment configuration file
create_environment_config() {
    log_header "Creating Environment Configuration"
    
    cat > "${PROJECT_DIR}/deployment.env" << EOF
# MarkItDown Web Application - Deployment Configuration
# Generated on $(date)

# Project Configuration
PROJECT_DIR="$PROJECT_DIR"
BASE_DIR="$BASE_DIR"
DOMAIN="$DOMAIN"
PORT="$PORT"
APP_NAME="$APP_NAME"
SERVICE_NAME="$SERVICE_NAME"

# System Configuration
WEB_USER="$WEB_USER"
WEB_GROUP="$WEB_GROUP"
IS_SYNOLOGY="$IS_SYNOLOGY"

# Directory Paths
LOG_DIR="$LOG_DIR"
MODELS_DIR="$MODELS_DIR"
EASYOCR_DIR="$EASYOCR_DIR"
SESSIONS_DIR="$SESSIONS_DIR"
TMP_DIR="$TMP_DIR"
BACKUP_DIR="$BACKUP_DIR"
VENV_DIR="$VENV_DIR"

# URLs
LOCAL_URL="http://localhost:$PORT"
MAIN_URL="https://markitdown.$DOMAIN"
HEALTH_URL="https://health.markitdown.$DOMAIN"
API_URL="https://api.markitdown.$DOMAIN"

# Management Commands
START_CMD="sudo systemctl start $SERVICE_NAME"
STOP_CMD="sudo systemctl stop $SERVICE_NAME"
RESTART_CMD="sudo systemctl restart $SERVICE_NAME"
STATUS_CMD="sudo systemctl status $SERVICE_NAME"
LOGS_CMD="tail -f $LOG_DIR/markitdown.log"
HEALTH_CMD="curl -f http://localhost:$PORT/health"
EOF
    
    chown "$WEB_USER:$WEB_GROUP" "${PROJECT_DIR}/deployment.env"
    chmod 644 "${PROJECT_DIR}/deployment.env"
    
    log_success "Environment configuration created"
}

# Create deployment documentation
create_deployment_docs() {
    log_header "Creating Deployment Documentation"
    
    cat > "${PROJECT_DIR}/DEPLOYMENT.md" << EOF
# MarkItDown Web Application - Deployment Documentation

## Configuration Summary

- **Project Directory**: $PROJECT_DIR
- **Domain**: $DOMAIN
- **Port**: $PORT
- **Service Name**: $SERVICE_NAME
- **Web User**: $WEB_USER:$WEB_GROUP

## Quick Start Commands

### Service Management
\`\`\`bash
# Start the service
sudo systemctl start $SERVICE_NAME

# Stop the service
sudo systemctl stop $SERVICE_NAME

# Restart the service
sudo systemctl restart $SERVICE_NAME

# Check service status
sudo systemctl status $SERVICE_NAME

# View logs
tail -f $LOG_DIR/markitdown.log
\`\`\`

### Application URLs
- **Local Access**: http://localhost:$PORT
- **Main Application**: https://markitdown.$DOMAIN
- **Health Check**: https://health.markitdown.$DOMAIN
- **API Access**: https://api.markitdown.$DOMAIN

### Troubleshooting

#### Permission Issues
\`\`\`bash
# Fix file permissions
cd $PROJECT_DIR
sudo chown -R $WEB_USER:$WEB_GROUP .
sudo chmod -R 755 .
sudo chmod 777 models/easyocr sessions tmp logs
\`\`\`

#### Service Issues
\`\`\`bash
# Unmask service if needed
sudo systemctl unmask $SERVICE_NAME
sudo systemctl daemon-reload

# Check service logs
journalctl -u $SERVICE_NAME -f
\`\`\`

#### EasyOCR Issues
\`\`\`bash
# Verify EasyOCR installation
cd $PROJECT_DIR
source venv/bin/activate
python -c "import easyocr; print('EasyOCR available')"
\`\`\`

### Environment Variables
The application uses these key environment variables:
- \`EASYOCR_MODULE_PATH\`: $EASYOCR_DIR
- \`SESSION_FILE_DIR\`: $SESSIONS_DIR
- \`TMPDIR\`: $TMP_DIR
- \`OPENCV_IO_ENABLE_OPENEXR\`: 0
- \`DISPLAY\`: "" (headless mode)

### File Structure
\`\`\`
$PROJECT_DIR/
├── app.py                     # Main application
├── requirements.txt           # Dependencies
├── templates/                 # HTML templates
├── static/                    # CSS, JS, images
├── venv/                      # Python virtual environment
├── logs/                      # Application logs
├── models/                    # EasyOCR models
├── sessions/                  # Session storage
├── tmp/                       # Temporary files
├── deployment.env             # Deployment configuration
├── DEPLOYMENT.md              # This documentation
└── *.sh                       # Helper scripts
\`\`\`

### Cloudflare Tunnel Setup

To set up secure internet access via Cloudflare Tunnel:

1. Run the tunnel deployment script:
   \`\`\`bash
   cd $PROJECT_DIR
   ./deploy_tunnel.sh deploy
   \`\`\`

2. Follow the interactive prompts to configure:
   - Your domain name
   - Cloudflare tunnel token
   - Tunnel ID

### API Usage Examples

\`\`\`bash
# Convert file
curl -X POST -F "file=@document.pdf" https://api.markitdown.$DOMAIN/convert_async

# Convert URL
curl -X POST -d "url=https://example.com" https://api.markitdown.$DOMAIN/

# Health check
curl https://health.markitdown.$DOMAIN/health
\`\`\`

### Backup and Maintenance

\`\`\`bash
# Create backup
tar -czf markitdown-backup-\$(date +%Y%m%d).tar.gz -C $BASE_DIR markitdown

# Update application
cd $PROJECT_DIR
git pull  # if using git
sudo systemctl restart $SERVICE_NAME

# Clean logs
truncate -s 0 $LOG_DIR/markitdown.log
\`\`\`

## Support

For issues and troubleshooting:
1. Check service status: \`sudo systemctl status $SERVICE_NAME\`
2. View logs: \`tail -f $LOG_DIR/markitdown.log\`
3. Test health endpoint: \`curl http://localhost:$PORT/health\`

Generated on: $(date)
EOF
    
    chown "$WEB_USER:$WEB_GROUP" "${PROJECT_DIR}/DEPLOYMENT.md"
    chmod 644 "${PROJECT_DIR}/DEPLOYMENT.md"
    
    log_success "Deployment documentation created"
}

# Show deployment summary
show_deployment_summary() {
    log_header "Deployment Summary"
    
    echo "🎉 MarkItDown Web Application deployment complete!"
    echo
    echo "📋 Configuration:"
    echo "   Project Directory: $PROJECT_DIR"
    echo "   Domain: $DOMAIN"
    echo "   Port: $PORT"
    echo "   Service: $SERVICE_NAME"
    echo "   Status: $(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo 'stopped')"
    echo
    echo "🌐 Access URLs:"
    echo "   Local: http://localhost:$PORT"
    echo "   Domain: https://markitdown.$DOMAIN (configure tunnel)"
    echo "   Health: https://health.markitdown.$DOMAIN"
    echo "   API: https://api.markitdown.$DOMAIN"
    echo
    echo "🔧 Management Commands:"
    echo "   Start:   sudo systemctl start $SERVICE_NAME"
    echo "   Stop:    sudo systemctl stop $SERVICE_NAME"
    echo "   Restart: sudo systemctl restart $SERVICE_NAME"
    echo "   Status:  sudo systemctl status $SERVICE_NAME"
    echo "   Logs:    tail -f $LOG_DIR/markitdown.log"
    echo "   Health:  curl http://localhost:$PORT/health"
    echo
    echo "📁 Helper Scripts:"
    echo "   $PROJECT_DIR/start.sh"
    echo "   $PROJECT_DIR/stop.sh"
    echo "   $PROJECT_DIR/status.sh"
    echo "   $PROJECT_DIR/info.sh"
    echo "   $PROJECT_DIR/health_check.sh"
    echo
    echo "🔒 Next Steps:"
    echo "   1. Test local access: curl http://localhost:$PORT/health"
    echo "   2. Setup Cloudflare Tunnel: ./deploy_tunnel.sh deploy"
    echo "   3. Configure DNS records in Cloudflare dashboard"
    echo "   4. Test public access via your domain"
    echo
    echo "📖 Documentation: $PROJECT_DIR/DEPLOYMENT.md"
    echo "🚀 Welcome to MarkItDown Web Application!"
}

# Main deployment function
deploy_markitdown() {
    log_header "MarkItDown Web Application Deployment"
    
    check_root
    detect_system
    create_directories
    install_system_dependencies
    setup_python_environment
    create_systemd_service
    create_helper_scripts
    create_environment_config
    create_deployment_docs
    start_service
    show_deployment_summary
}

# Show usage information
show_usage() {
    cat << EOF

MarkItDown Web Application - Production Deployment Script
=========================================================

USAGE: $0 [COMMAND]

COMMANDS:
    setup               Complete deployment with interactive configuration
    --non-interactive   Use environment variables for configuration
    start               Start the service
    stop                Stop the service
    restart             Restart the service
    status              Show service status
    logs                Show service logs
    health              Test health endpoint
    info                Show deployment information

ENVIRONMENT VARIABLES (for --non-interactive mode):
    BASE_DIR           Base directory path (default: /volume1/web)
    DOMAIN             Your domain name (required)
    PORT               Port number (default: 8008)
    APP_NAME           Application name (default: markitdown)

EXAMPLES:
    # Interactive deployment
    sudo $0 setup

    # Non-interactive deployment
    export DOMAIN="example.com"
    export BASE_DIR="/opt"
    sudo $0 --non-interactive

    # Service management
    sudo $0 start
    sudo $0 status
    $0 logs

For Cloudflare Tunnel setup, use:
    ./deploy_tunnel.sh deploy

EOF
}

# Main function
main() {
    case "${1:-setup}" in
        "setup"|"--non-interactive")
            deploy_markitdown
            ;;
        "start")
            systemctl start "${APP_NAME:-markitdown}.service"
            ;;
        "stop")
            systemctl stop "${APP_NAME:-markitdown}.service"
            ;;
        "restart")
            systemctl restart "${APP_NAME:-markitdown}.service"
            ;;
        "status")
            systemctl status "${APP_NAME:-markitdown}.service" --no-pager
            ;;
        "logs")
            if [[ -f "${PROJECT_DIR:-/volume1/web/markitdown}/logs/markitdown.log" ]]; then
                tail -f "${PROJECT_DIR:-/volume1/web/markitdown}/logs/markitdown.log"
            else
                journalctl -u "${APP_NAME:-markitdown}.service" -f
            fi
            ;;
        "health")
            curl -f "http://localhost:${PORT:-8008}/health" || echo "Health check failed"
            ;;
        "info")
            if [[ -f "${PROJECT_DIR:-/volume1/web/markitdown}/info.sh" ]]; then
                bash "${PROJECT_DIR:-/volume1/web/markitdown}/info.sh"
            else
                echo "Deployment info not found. Run setup first."
            fi
            ;;
        *)
            show_usage
            ;;
    esac
}

# Run main function with all arguments
main "$@" 
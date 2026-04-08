#!/usr/bin/env bash
# =============================================================================
#  pilog-deploy.sh — Auto-deploy pilog-react on a Raspberry Pi 4
#  Installs: Node.js, nginx, cloudflared
#  Builds & serves: parthhverma/pilog-react
#  Tunnels via:    Cloudflare Tunnel → pilog.thanhhvu.com
# =============================================================================
set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# ── Config (edit if needed) ───────────────────────────────────────────────────
REPO_URL="https://github.com/parthhverma/pilog-react.git"
APP_DIR="/var/www/pilog-react"
BUILD_DIR="${APP_DIR}/build"
NGINX_CONF="/etc/nginx/sites-available/pilog"
NGINX_LINK="/etc/nginx/sites-enabled/pilog"
TUNNEL_SERVICE="cloudflared"
NODE_VERSION="20"                # LTS — change if needed

# ── Suppress apt interactivity warnings ──────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
APT_GET() { apt-get "$@"; }

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"

echo -e "\n${BOLD}━━━  pilog auto-deploy  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "    Target: ${BOLD}pilog.thanhhvu.com${RESET}"
echo -e "    Arch:   $(uname -m)  |  OS: $(. /etc/os-release && echo "$PRETTY_NAME")"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"

# ── 1. System update & base deps ─────────────────────────────────────────────
info "Updating package lists..."
APT_GET update -qq

info "Installing base dependencies..."
APT_GET install -y -qq curl git nginx ca-certificates gnupg lsb-release

# ── 2. Node.js (manual NodeSource repo — no curl|bash, no bare apt) ──────────
if node --version 2>/dev/null | grep -q "^v${NODE_VERSION}"; then
    success "Node.js ${NODE_VERSION} already installed, skipping."
else
    info "Adding NodeSource apt repository for Node.js ${NODE_VERSION}.x..."
    KEYRING_DIR="/usr/share/keyrings"
    NODE_KEYRING="${KEYRING_DIR}/nodesource.gpg"
    NODE_LIST="/etc/apt/sources.list.d/nodesource.list"

    mkdir -p "$KEYRING_DIR"
    curl -fsSL "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" \
        | gpg --dearmor --batch --yes -o "$NODE_KEYRING"

    echo "deb [signed-by=${NODE_KEYRING}] https://deb.nodesource.com/node_${NODE_VERSION}.x nodistro main" \
        > "$NODE_LIST"

    APT_GET update -qq
    APT_GET install -y -qq nodejs
fi
success "Node $(node --version) / npm $(npm --version)"

# ── 3. cloudflared ────────────────────────────────────────────────────────────
if command -v cloudflared &>/dev/null; then
    success "cloudflared already installed ($(cloudflared --version 2>&1 | head -1)), skipping."
else
    info "Installing cloudflared (arm64 / armv7 auto-detected)..."
    # Use uname -m for true CPU arch — dpkg may report i386 on 32-bit userland
    # running on 64-bit ARM hardware (common on Raspberry Pi OS Lite 32-bit)
    CPU=$(uname -m)
    case "$CPU" in
        aarch64 | arm64) CF_ARCH="arm64" ;;
        armv7l  | armv6l) CF_ARCH="arm"  ;;
        x86_64)           CF_ARCH="amd64" ;;
        i386 | i686)      CF_ARCH="386"   ;;
        *)                die "Unsupported CPU architecture: $CPU" ;;
    esac
    CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}.deb"
    TMP_DEB=$(mktemp /tmp/cloudflared-XXXX.deb)
    curl -fsSL "$CF_URL" -o "$TMP_DEB"
    dpkg -i "$TMP_DEB" >/dev/null
    rm -f "$TMP_DEB"
fi
success "cloudflared $(cloudflared --version 2>&1 | head -1)"

# ── 4. Clone / update the repo ───────────────────────────────────────────────
if [[ -d "${APP_DIR}/.git" ]]; then
    info "Repo already exists — pulling latest..."
    git -C "$APP_DIR" fetch --quiet origin
    git -C "$APP_DIR" reset --hard origin/main --quiet
else
    info "Cloning ${REPO_URL} → ${APP_DIR}..."
    git clone --depth 1 "$REPO_URL" "$APP_DIR"
fi
success "Source at ${APP_DIR}"

# ── 5. Install npm deps & build ───────────────────────────────────────────────
info "Installing npm dependencies (this can take a few minutes on Pi)..."
cd "$APP_DIR"
npm ci --silent

info "Building production bundle..."
CI=false npm run build --silent    # CI=false avoids treating warnings as errors
success "Build complete → ${BUILD_DIR}"

# Fix permissions so nginx can read the files
chown -R www-data:www-data "$BUILD_DIR"
chmod -R 755 "$BUILD_DIR"

# ── 6. Configure nginx ────────────────────────────────────────────────────────
info "Writing nginx config..."
cat > "$NGINX_CONF" <<'NGINX'
server {
    listen 80;
    server_name _;

    root /var/www/pilog-react/build;
    index index.html;

    # React Router: fall back to index.html for all routes
    location / {
        try_files $uri $uri/ /index.html;
    }

    # Long-lived cache for hashed static assets
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        try_files $uri =404;
    }

    # Security headers
    add_header X-Frame-Options      "SAMEORIGIN"                    always;
    add_header X-Content-Type-Options "nosniff"                     always;
    add_header Referrer-Policy      "strict-origin-when-cross-origin" always;

    # Compression
    gzip on;
    gzip_types text/plain text/css application/json application/javascript
               text/xml application/xml text/javascript image/svg+xml;
    gzip_min_length 1000;
}
NGINX

# Enable site and remove default
ln -sf "$NGINX_CONF" "$NGINX_LINK"
rm -f /etc/nginx/sites-enabled/default

info "Testing nginx config..."
nginx -t

PORT=80

info "Checking for processes using port $PORT..."

# Ensure lsof is installed (Raspberry Pi OS = apt)
if ! command -v lsof >/dev/null 2>&1; then
    info "Installing lsof..."
    sudo apt update -y && sudo apt install -y lsof
fi

# Get PIDs
PIDS=$(lsof -t -i:$PORT 2>/dev/null)

if [ -z "$PIDS" ]; then
    info "No process is running on port $PORT."
    exit 0
fi

info "Found process(es): $PIDS"

# Try to detect service names (nginx, apache2, etc.)
for PID in $PIDS; do
    SERVICE=$(ps -p $PID -o comm=)

    info "PID $PID is running: $SERVICE"

    # Try stopping as a system service first
    if systemctl list-units --type=service | grep -q "$SERVICE"; then
        info "Attempting to stop service: $SERVICE"
        if sudo systemctl stop $SERVICE; then
            success "Service $SERVICE stopped."
            continue
        fi
    fi

    # Fallback: kill process
    info "Stopping PID $PID..."

    if kill $PID 2>/dev/null || sudo kill $PID 2>/dev/null; then
        success "PID $PID terminated."
    else
        info "Force killing PID $PID..."
        if kill -9 $PID 2>/dev/null || sudo kill -9 $PID 2>/dev/null; then
            success "PID $PID force killed."
        else
            error "Failed to kill PID $PID."
        fi
    fi
done

success "Port $PORT is now free."

info "Reloading nginx..."
systemctl enable nginx --quiet
systemctl reload-or-restart nginx
success "nginx is serving the app on port 80"

# ── 7. Cloudflare Tunnel ──────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━  Cloudflare Tunnel setup  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

# Check if a tunnel is already running as a systemd service
if systemctl is-active --quiet "${TUNNEL_SERVICE}"; then
    warn "A cloudflared service is already running. Skipping tunnel install."
    warn "To reconfigure, run: sudo cloudflared service uninstall"
else
    echo ""
    echo -e "  You need a ${BOLD}Cloudflare Tunnel token${RESET} for pilog.thanhhvu.com."
    echo -e "  ${YELLOW}How to get one (takes ~2 minutes):${RESET}"
    echo -e "  1. Go to https://one.dash.cloudflare.com/"
    echo -e "  2. Networks → Tunnels → Create a tunnel → name it ${BOLD}pilog${RESET}"
    echo -e "  3. Choose ${BOLD}Linux${RESET} → copy ONLY the token value after ${BOLD}--token${RESET}"
    echo -e "  4. Under ${BOLD}Public Hostnames${RESET}, add:"
    echo -e "       Subdomain: pilog  |  Domain: thanhhvu.com  |  Service: http://localhost:80"
    echo -e "  5. Save and come back here.\n"

    while true; do
        read -rp "$(echo -e "${CYAN}Paste your tunnel token:${RESET} ")" CF_TOKEN
        CF_TOKEN="${CF_TOKEN// /}"   # strip accidental spaces
        if [[ -n "$CF_TOKEN" ]]; then
            break
        fi
        warn "Token cannot be empty. Try again."
    done

    info "Installing cloudflared as a system service..."
    cloudflared service install "$CF_TOKEN"

    info "Enabling and starting cloudflared..."
    systemctl enable cloudflared --quiet
    systemctl start  cloudflared

    # Brief wait to let tunnel establish
    sleep 4

    if systemctl is-active --quiet cloudflared; then
        success "cloudflared tunnel is running!"
    else
        warn "cloudflared may not have started cleanly."
        warn "Check logs: journalctl -u cloudflared -n 50"
    fi
fi

# ── 8. Done ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e " ${GREEN}${BOLD}Deployment complete!${RESET}"
echo -e ""
echo -e "  🌐  ${BOLD}https://pilog.thanhhvu.com${RESET}"
echo -e ""
echo -e "  Useful commands:"
echo -e "    Nginx status   : ${CYAN}systemctl status nginx${RESET}"
echo -e "    Tunnel status  : ${CYAN}systemctl status cloudflared${RESET}"
echo -e "    Tunnel logs    : ${CYAN}journalctl -u cloudflared -f${RESET}"
echo -e "    Redeploy app   : ${CYAN}sudo bash $0${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"

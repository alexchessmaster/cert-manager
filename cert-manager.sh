#!/bin/bash

# =============================================================================
# ssl_cert_manager.sh
# Nginx SSL Certificate Manager — auto-installs deps, issues/renews certs,
# updates configs, registers itself in cron, and reloads nginx.
#
# Recommended location: /usr/local/sbin/ssl_cert_manager.sh
# Usage: sudo bash /usr/local/sbin/ssl_cert_manager.sh
# =============================================================================

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
NGINX_CONF_DIR="/etc/nginx/conf.d"
SSL_DIR="/etc/nginx/ssl"
WEBROOT_DIR="/var/www/letsencrypt"
LOG_FILE="/var/log/ssl_cert_manager.log"
SCRIPT_PATH="/usr/local/sbin/ssl_cert_manager.sh"
CRON_SCHEDULE="0 3 1 */3 *"   # 03:00 on the 1st day, every 3 months
EMAIL=""                        # Recommended: set for cert expiry alerts e.g. "admin@example.com"
CERTBOT_EXTRA_FLAGS=""          # e.g. "--staging" for testing
# ──────────────────────────────────────────────────────────────────────────────

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

# ─── Logging ──────────────────────────────────────────────────────────────────
log()  { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]${NC}  $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
err()  { echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR]${NC} $*" | tee -a "$LOG_FILE"; }
info() { echo -e "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')] [....] ${NC} $*" | tee -a "$LOG_FILE"; }

# ─── Root check ───────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root. Try: sudo $0"
    exit 1
fi

# ─── Ensure log file exists ───────────────────────────────────────────────────
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 640 "$LOG_FILE"

log "======================================================"
log " SSL Certificate Manager — starting run"
log "======================================================"

# ─── Detect package manager ───────────────────────────────────────────────────
detect_pkg_manager() {
    if command -v apt-get &>/dev/null; then
        PKG_MANAGER="apt-get"
        PKG_INSTALL="apt-get install -y -qq"
        PKG_UPDATE="apt-get update -qq"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
        PKG_INSTALL="dnf install -y -q"
        PKG_UPDATE="dnf check-update -q || true"
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"
        PKG_INSTALL="yum install -y -q"
        PKG_UPDATE="yum check-update -q || true"
    else
        err "No supported package manager found (apt/dnf/yum). Aborting."
        exit 1
    fi
    log "Package manager detected: $PKG_MANAGER"
}

# ─── Install required packages ────────────────────────────────────────────────
install_dependencies() {
    info "Checking and installing dependencies..."
    detect_pkg_manager

    $PKG_UPDATE 2>>"$LOG_FILE" || true

    local packages=("nginx" "curl" "openssl" "cron")
    if [[ "$PKG_MANAGER" =~ ^(dnf|yum)$ ]]; then
        packages=("nginx" "curl" "openssl" "cronie")
    fi

    for pkg in "${packages[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null 2>&1 && ! rpm -q "$pkg" &>/dev/null 2>&1; then
            log "Installing: $pkg"
            $PKG_INSTALL "$pkg" 2>>"$LOG_FILE" || warn "Could not install $pkg — continuing"
        else
            log "Already installed: $pkg"
        fi
    done

    install_certbot

    for svc in nginx cron crond; do
        if systemctl list-units --type=service 2>/dev/null | grep -q "${svc}.service"; then
            systemctl enable "$svc" --quiet 2>/dev/null || true
            systemctl start  "$svc" 2>/dev/null        || true
        fi
    done
}

# ─── Install certbot (3 strategies, pip first) ────────────────────────────────
install_certbot() {
    info "Setting up certbot + nginx plugin..."

    if certbot_nginx_works; then
        log "certbot nginx plugin: already working"
        return 0
    fi

    log "certbot nginx plugin not working — attempting fix..."

    try_pip_certbot    && return 0
    try_snap_certbot   && return 0
    try_pkg_certbot    && return 0

    err "All certbot install strategies failed. Please install manually:"
    err "  pip3 install certbot certbot-nginx"
    err "  OR: snap install --classic certbot && ln -sf /snap/bin/certbot /usr/bin/certbot"
    exit 1
}

certbot_nginx_works() {
    command -v certbot &>/dev/null || return 1
    certbot plugins 2>/dev/null | grep -q "nginx" || return 1
    return 0
}

try_pip_certbot() {
    info "Trying: pip3 install certbot certbot-nginx..."
    if ! command -v pip3 &>/dev/null; then
        $PKG_INSTALL python3-pip 2>>"$LOG_FILE" || return 1
    fi
    if command -v certbot &>/dev/null; then
        local certbot_path
        certbot_path=$(command -v certbot)
        if [[ "$certbot_path" != /snap/* ]]; then
            apt-get remove -y certbot python3-certbot-nginx &>/dev/null 2>&1 || true
        fi
    fi
    pip3 install --quiet --upgrade certbot certbot-nginx 2>>"$LOG_FILE" || return 1
    export PATH="/usr/local/bin:$PATH"
    if ! command -v certbot &>/dev/null; then
        local certbot_bin
        certbot_bin=$(find /usr/local/bin /usr/local/lib -name "certbot" 2>/dev/null | head -1)
        [[ -n "$certbot_bin" ]] && ln -sf "$certbot_bin" /usr/local/bin/certbot
    fi
    certbot_nginx_works || return 1
    return 0
}

try_snap_certbot() {
    info "Trying: snap install --classic certbot..."
    command -v snap &>/dev/null || $PKG_INSTALL snapd 2>>"$LOG_FILE" || return 1
    snap install --classic certbot 2>>"$LOG_FILE" || return 1
    ln -sf /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true
    certbot_nginx_works || return 1
    return 0
}

try_pkg_certbot() {
    info "Trying: package manager certbot..."
    $PKG_INSTALL certbot python3-certbot-nginx 2>>"$LOG_FILE" || return 1
    certbot_nginx_works || return 1
    return 0
}

# ─── Setup SSL + webroot directories ──────────────────────────────────────────
setup_ssl_dir() {
    mkdir -p "$SSL_DIR"
    chmod 700 "$SSL_DIR"
    mkdir -p "${WEBROOT_DIR}/.well-known/acme-challenge"
    chmod -R 755 "$WEBROOT_DIR"
    log "SSL dir ready: $SSL_DIR"
    log "Webroot dir ready: $WEBROOT_DIR"
}

# ─── Disable conflicting default site ─────────────────────────────────────────
# /etc/nginx/sites-enabled/default causes "protocol options redefined" warnings
# and can prevent nginx from starting. Disable it safely.
disable_default_site() {
    local default_site="/etc/nginx/sites-enabled/default"
    if [[ -L "$default_site" || -f "$default_site" ]]; then
        warn "Disabling conflicting default nginx site: $default_site"
        mv "$default_site" "${default_site}.disabled"
        log "Moved to: ${default_site}.disabled"
    fi
}

# ─── Ensure nginx serves ACME webroot challenge ───────────────────────────────
setup_webroot_snippet() {
    local snippet="/etc/nginx/snippets/letsencrypt-acme-challenge.conf"
    if [[ ! -f "$snippet" ]]; then
        mkdir -p /etc/nginx/snippets
        cat > "$snippet" <<'EOF'
# Let's Encrypt HTTP-01 challenge (certbot webroot)
location ^~ /.well-known/acme-challenge/ {
    default_type "text/plain";
    root /var/www/letsencrypt;
    allow all;
}
EOF
        log "Created ACME challenge snippet: $snippet"
    fi
}

# ─── Ensure nginx is running — kill orphans if needed ─────────────────────────
# This is the key fix: before touching nginx we always ensure a clean state.
ensure_nginx_running() {
    if systemctl is-active --quiet nginx; then
        return 0
    fi

    warn "nginx is not running — checking for orphan processes..."

    # Kill any orphan nginx processes holding ports 80/443
    local orphan_pids
    orphan_pids=$(ss -tlnp 2>/dev/null \
        | grep -E ':80\b|:443\b' \
        | grep -oP 'pid=\K[0-9]+' \
        | sort -u)

    if [[ -n "$orphan_pids" ]]; then
        warn "Killing orphan processes holding ports 80/443: $orphan_pids"
        for pid in $orphan_pids; do
            kill -9 "$pid" 2>/dev/null && log "Killed orphan PID $pid" || true
        done
        sleep 1
    fi

    # Now start nginx cleanly
    if nginx -t 2>>"$LOG_FILE"; then
        systemctl start nginx 2>>"$LOG_FILE"
        sleep 1
        if systemctl is-active --quiet nginx; then
            log "nginx started successfully"
            return 0
        fi
    fi

    err "nginx failed to start — check $LOG_FILE and nginx error logs"
    return 1
}

# ─── Parse a config file ──────────────────────────────────────────────────────
parse_config() {
    local conf_file="$1"

    if ! grep -qE '^\s*listen\s+.*443' "$conf_file"; then
        info "Skipping (no port 443): $(basename "$conf_file")"
        return 1
    fi

    local domain
    domain=$(grep -E '^\s*server_name\s+' "$conf_file" \
             | head -1 \
             | awk '{print $2}' \
             | tr -d ';' \
             | grep -v '^_$')

    if [[ -z "$domain" ]]; then
        warn "No valid server_name in $(basename "$conf_file") — skipping"
        return 1
    fi

    PARSED_DOMAIN="$domain"
    PARSED_CERT="$SSL_DIR/${domain}.crt"
    PARSED_KEY="$SSL_DIR/${domain}.key"
    return 0
}

# ─── Issue / renew certificate ────────────────────────────────────────────────
# IMPORTANT: --standalone is intentionally removed. It stops nginx and is the
# cause of the orphan-process / port-binding failure you experienced.
# We use only --nginx and --webroot, both of which keep nginx running.
issue_certificate() {
    local domain="$1"
    local cert_path="$2"
    local key_path="$3"

    log "Issuing/renewing certificate for: $domain"

    local email_flag="--register-unsafely-without-email"
    [[ -n "$EMAIL" ]] && email_flag="--email ${EMAIL} --no-eff-email"

    # ── Method 1: nginx plugin (nginx stays up, recommended) ─────────────────
    if certbot_nginx_works; then
        info "Method 1: certbot --nginx for $domain"
        if certbot certonly \
            --nginx \
            --non-interactive \
            --agree-tos \
            --force-renewal \
            $email_flag \
            --domain "$domain" \
            $CERTBOT_EXTRA_FLAGS \
            2>>"$LOG_FILE"; then
            link_certbot_files "$domain" "$cert_path" "$key_path" && return 0
        fi
        warn "nginx plugin failed for $domain — trying webroot..."
    fi

    # ── Method 2: webroot (nginx stays up, uses port 80 challenge dir) ────────
    info "Method 2: certbot --webroot for $domain"
    setup_webroot_snippet

    # Reload nginx so the ACME snippet is active — safely
    if nginx -t 2>>"$LOG_FILE"; then
        systemctl reload nginx 2>>"$LOG_FILE" || true
    fi

    if certbot certonly \
        --webroot \
        --webroot-path "$WEBROOT_DIR" \
        --non-interactive \
        --agree-tos \
        --force-renewal \
        $email_flag \
        --domain "$domain" \
        $CERTBOT_EXTRA_FLAGS \
        2>>"$LOG_FILE"; then
        link_certbot_files "$domain" "$cert_path" "$key_path" && return 0
    fi

    # ── No more methods — standalone intentionally omitted ───────────────────
    err "Both certbot methods failed for $domain"
    err "Likely cause: DNS for $domain does not point to this server, or port 80 is firewalled."
    err "Check: dig +short $domain  vs  curl -s ifconfig.me"
    return 1
}

# ─── Symlink certbot live files into /etc/nginx/ssl/ ─────────────────────────
link_certbot_files() {
    local domain="$1"
    local cert_path="$2"
    local key_path="$3"

    local le_dir="/etc/letsencrypt/live/${domain}"
    if [[ ! -d "$le_dir" ]]; then
        err "certbot succeeded but live dir not found: $le_dir"
        return 1
    fi

    ln -sf "${le_dir}/fullchain.pem" "$cert_path"
    ln -sf "${le_dir}/privkey.pem"   "$key_path"
    log "Certificate symlinked → $cert_path"
    log "Key symlinked          → $key_path"
    return 0
}

# ─── Update ssl_certificate directives in nginx config ───────────────────────
update_nginx_config() {
    local conf_file="$1"
    local cert_path="$2"
    local key_path="$3"
    local domain="$4"

    log "Updating nginx config: $(basename "$conf_file")"

    local backup="${conf_file}.bak"
    [[ ! -f "$backup" ]] && cp "$conf_file" "$backup" && log "Backup saved: $backup"

    if grep -qE '^\s*ssl_certificate\s+' "$conf_file"; then
        sed -i "s|^\(\s*\)ssl_certificate\s\+.*;|\1ssl_certificate ${cert_path};|g" "$conf_file"
    else
        sed -i "/listen.*443/a\\    ssl_certificate ${cert_path};" "$conf_file"
    fi

    if grep -qE '^\s*ssl_certificate_key\s+' "$conf_file"; then
        sed -i "s|^\(\s*\)ssl_certificate_key\s\+.*;|\1ssl_certificate_key ${key_path};|g" "$conf_file"
    else
        sed -i "/ssl_certificate ${cert_path}/a\\    ssl_certificate_key ${key_path};" "$conf_file"
    fi

    log "Config updated for $domain"
}

# ─── Validate and reload nginx ────────────────────────────────────────────────
validate_and_reload_nginx() {
    info "Validating nginx configuration..."
    if ! nginx -t 2>>"$LOG_FILE"; then
        err "nginx config test FAILED — check $LOG_FILE"
        return 1
    fi
    log "nginx config test: PASSED"

    info "Reloading nginx (graceful — zero downtime)..."
    if systemctl reload nginx 2>>"$LOG_FILE"; then
        log "nginx reloaded successfully — all workers are live"
    else
        warn "reload failed — ensuring clean state and restarting..."
        ensure_nginx_running
    fi
}

# ─── Register in /etc/cron.d ──────────────────────────────────────────────────
register_cron() {
    if [[ "$(realpath "$0")" != "$SCRIPT_PATH" ]]; then
        cp -f "$0" "$SCRIPT_PATH"
        chmod 700 "$SCRIPT_PATH"
        log "Script installed to $SCRIPT_PATH"
    fi

    if [[ ! -f /etc/cron.d/ssl_cert_manager ]]; then
        cat > /etc/cron.d/ssl_cert_manager <<EOF
# Managed by ssl_cert_manager.sh — do not edit manually
# Runs every 3 months to renew all nginx SSL certificates
${CRON_SCHEDULE} root ${SCRIPT_PATH} >> ${LOG_FILE} 2>&1
EOF
        chmod 644 /etc/cron.d/ssl_cert_manager
        log "Cron job registered: $CRON_SCHEDULE → $SCRIPT_PATH"
    else
        log "Cron job already registered — skipping"
    fi
}

# ─── Summary counters ─────────────────────────────────────────────────────────
TOTAL=0; SUCCESS=0; SKIPPED=0; FAILED=0

# ═══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════════════════════

install_dependencies
setup_ssl_dir
disable_default_site   # Fix "protocol options redefined" warning
register_cron

# Guarantee nginx is healthy before we start touching anything
ensure_nginx_running

log "Scanning configs in: $NGINX_CONF_DIR"

for conf_file in "$NGINX_CONF_DIR"/*.conf; do
    [[ -f "$conf_file" ]] || continue
    TOTAL=$((TOTAL + 1))

    info "─── Processing: $(basename "$conf_file")"

    PARSED_DOMAIN=""; PARSED_CERT=""; PARSED_KEY=""

    if ! parse_config "$conf_file"; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    domain="$PARSED_DOMAIN"
    cert_path="$PARSED_CERT"
    key_path="$PARSED_KEY"

    if issue_certificate "$domain" "$cert_path" "$key_path"; then
        update_nginx_config "$conf_file" "$cert_path" "$key_path" "$domain"
        SUCCESS=$((SUCCESS + 1))
    else
        FAILED=$((FAILED + 1))
    fi

    # After each cert, confirm nginx is still healthy
    ensure_nginx_running
done

log "──────────────────────────────────────────────────────"
log " Run complete │ Total: $TOTAL │ OK: $SUCCESS │ Skipped: $SKIPPED │ Failed: $FAILED"
log "──────────────────────────────────────────────────────"

validate_and_reload_nginx

log "All done. Next scheduled run: $CRON_SCHEDULE"
exit 0

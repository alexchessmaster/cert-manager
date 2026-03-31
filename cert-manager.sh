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

# ─── Update Cloudflare IPs in nginx.conf ──────────────────────────────────────
# Fetches latest IPs from Cloudflare API, then rewrites the set_real_ip_from
# block and real_ip_header / real_ip_recursive directives in nginx.conf.
# If the block doesn't exist yet it is inserted before the closing } of http{}.
update_cloudflare_ips() {
    local nginx_conf="/etc/nginx/nginx.conf"

    if [[ ! -f "$nginx_conf" ]]; then
        warn "nginx.conf not found at $nginx_conf — skipping Cloudflare IP update"
        return 0
    fi

    info "Fetching latest Cloudflare IP ranges..."

    # Install jq if missing (needed to parse the JSON API response)
    if ! command -v jq &>/dev/null; then
        log "Installing jq..."
        $PKG_INSTALL jq 2>>"$LOG_FILE" || warn "jq not available — falling back to plain-text URLs"
    fi

    local ipv4_list="" ipv6_list=""

    # ── Primary source: Cloudflare JSON API ──────────────────────────────────
    if command -v jq &>/dev/null; then
        local api_response
        api_response=$(curl -sf --max-time 10 "https://api.cloudflare.com/client/v4/ips" 2>>"$LOG_FILE" || true)

        if [[ -n "$api_response" ]] && echo "$api_response" | jq -e '.success == true' &>/dev/null; then
            ipv4_list=$(echo "$api_response" | jq -r '.result.ipv4_cidrs[]' 2>/dev/null || true)
            ipv6_list=$(echo "$api_response" | jq -r '.result.ipv6_cidrs[]' 2>/dev/null || true)
            log "Cloudflare IPs fetched from API"
        fi
    fi

    # ── Fallback: plain-text URLs ─────────────────────────────────────────────
    if [[ -z "$ipv4_list" ]]; then
        warn "API fetch failed — falling back to plain-text IP lists"
        ipv4_list=$(curl -sf --max-time 10 "https://www.cloudflare.com/ips-v4" 2>>"$LOG_FILE" || true)
        ipv6_list=$(curl -sf --max-time 10 "https://www.cloudflare.com/ips-v6" 2>>"$LOG_FILE" || true)
    fi

    if [[ -z "$ipv4_list" && -z "$ipv6_list" ]]; then
        err "Could not fetch Cloudflare IPs from any source — skipping update"
        return 1
    fi

    # ── Build the new nginx block ─────────────────────────────────────────────
    local new_block
    new_block="    ## START get client real IP address\n"
    new_block+="    # Cloudflare IPs — auto-updated by ssl_cert_manager.sh on $(date '+%Y-%m-%d')\n"

    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        new_block+="    set_real_ip_from ${ip};\n"
    done <<< "$ipv4_list"

    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        new_block+="    set_real_ip_from ${ip};\n"
    done <<< "$ipv6_list"

    new_block+="    real_ip_header CF-Connecting-IP;\n"
    new_block+="    real_ip_recursive on;\n"
    new_block+="    ## END get client real IP address"

    # ── Back up nginx.conf ────────────────────────────────────────────────────
    local backup="${nginx_conf}.bak.$(date '+%Y%m%d%H%M%S')"
    cp "$nginx_conf" "$backup"
    log "nginx.conf backed up to $backup"

    # ── Replace existing block or insert before closing } of http{} ──────────
    if grep -q "## START get client real IP address" "$nginx_conf"; then
        # Delete everything between the START and END markers (inclusive)
        sed -i '/## START get client real IP address/,/## END get client real IP address/d' "$nginx_conf"
        log "Removed old Cloudflare IP block from nginx.conf"
    fi

    # Insert the new block just before the first occurrence of ## END JSON or
    # before "## Basic Settings" or before the closing } of the http block.
    # We use a reliable anchor: insert before "## Basic Settings"
    if grep -q "## Basic Settings" "$nginx_conf"; then
        sed -i "/## Basic Settings/i\\${new_block}\n" "$nginx_conf"
    elif grep -q "## END JSON log format" "$nginx_conf"; then
        sed -i "/## END JSON log format/a\\\\n${new_block}" "$nginx_conf"
    else
        # Last resort: insert before the last closing brace of http{}
        sed -i "$(grep -n '^}' "$nginx_conf" | tail -2 | head -1 | cut -d: -f1)i\\    ${new_block}" "$nginx_conf"
    fi

    log "Cloudflare IP block updated in nginx.conf"

    # Count IPs for summary
    local ipv4_count ipv6_count
    ipv4_count=$(echo "$ipv4_list" | grep -c '\.' || true)
    ipv6_count=$(echo "$ipv6_list" | grep -c ':' || true)
    log "Updated: $ipv4_count IPv4 ranges + $ipv6_count IPv6 ranges"
}


# --- Ensure nginx.conf has all required settings ------------------------------
# Checks each setting individually. If missing, inserts it.
# Never overwrites settings that already exist.
ensure_nginx_conf_settings() {
    local nginx_conf="/etc/nginx/nginx.conf"

    if [[ ! -f "$nginx_conf" ]]; then
        warn "nginx.conf not found at $nginx_conf — skipping"
        return 0
    fi

    local backup="${nginx_conf}.bak.$(date '+%Y%m%d%H%M%S')"
    local changed=false

    # Backup once before first change
    make_backup() {
        if [[ "$changed" == false ]]; then
            cp "$nginx_conf" "$backup"
            log "nginx.conf backed up: $backup"
            changed=true
        fi
    }

    # Insert a line before an anchor string inside the file
    insert_before() {
        local line="$1"
        local anchor="$2"
        if grep -qF "$anchor" "$nginx_conf"; then
            # Escape for sed
            local escaped_line
            escaped_line=$(printf '%s' "    $line" | sed 's/[&/\\]/\\&/g')
            sed -i "/${anchor}/i\\    ${line}" "$nginx_conf"
        else
            # Fallback: insert before the Virtual Hosts include lines
            sed -i "/include \/etc\/nginx\/conf\.d/i\\    ${line}" "$nginx_conf"
        fi
    }

    log "Checking nginx.conf settings..."

    # ── log_format debug_log ──────────────────────────────────────────────────
    if ! grep -q "log_format debug_log" "$nginx_conf"; then
        make_backup
        sed -i "/^http {/a\\        log_format debug_log \'\$remote_addr \"\$request_uri\" \"\$uri\" \$status \"\$http_referer\"\';\n        ##tmp:" "$nginx_conf"
        log "Added: log_format debug_log"
    else
        log "OK: log_format debug_log"
    fi

    # ── log_format loki_json (Grafana/Loki) ───────────────────────────────────
    if ! grep -q "log_format loki_json" "$nginx_conf"; then
        make_backup
        python3 - "$nginx_conf" << 'LOKIEOF'
import sys
nginx_conf = sys.argv[1]
with open(nginx_conf, 'r') as f:
    c = f.read()
block = """    ## START JSON log format for Grafana + Loki
    log_format loki_json escape=json
    '{'
        '"time":"$time_iso8601",'
        '"remote_addr":"$remote_addr",'
        '"host":"$host",'
        '"method":"$request_method",'
        '"uri":"$request_uri",'
        '"status":$status,'
        '"bytes":$body_bytes_sent,'
        '"request_time":$request_time,'
        '"referer":"$http_referer",'
        '"agent":"$http_user_agent"'
    '}';
    access_log /var/log/nginx/access.log loki_json;
    error_log  /var/log/nginx/error.log warn;
    ## END JSON log format for Grafana + Loki
"""
if '## START get client real IP address' in c:
    c = c.replace('## START get client real IP address', block + '    ## START get client real IP address', 1)
elif '## Basic Settings' in c:
    c = c.replace('## Basic Settings', block + '\n    ## Basic Settings', 1)
else:
    c = c.replace('http {\n', 'http {\n' + block, 1)
with open(nginx_conf, 'w') as f:
    f.write(c)
LOKIEOF
        log "Added: log_format loki_json"
    else
        log "OK: log_format loki_json"
    fi

    # ── access_log using loki_json ────────────────────────────────────────────
    if ! grep -q "access_log.*loki_json" "$nginx_conf"; then
        make_backup
        insert_before "access_log /var/log/nginx/access.log loki_json;" "## END JSON log format"
        log "Added: access_log loki_json"
    else
        log "OK: access_log loki_json"
    fi

    # ── real_ip_header ────────────────────────────────────────────────────────
    if ! grep -q "real_ip_header" "$nginx_conf"; then
        make_backup
        insert_before "real_ip_header CF-Connecting-IP;" "## END get client real IP"
        insert_before "real_ip_recursive on;" "## END get client real IP"
        log "Added: real_ip_header + real_ip_recursive"
    else
        log "OK: real_ip_header"
    fi

    # ── sendfile ──────────────────────────────────────────────────────────────
    if ! grep -q "sendfile on" "$nginx_conf"; then
        make_backup
        insert_before "sendfile on;" "## Basic Settings"
        log "Added: sendfile on"
    else
        log "OK: sendfile on"
    fi

    # ── tcp_nopush ────────────────────────────────────────────────────────────
    if ! grep -q "tcp_nopush on" "$nginx_conf"; then
        make_backup
        insert_before "tcp_nopush on;" "keepalive_timeout"
        log "Added: tcp_nopush on"
    else
        log "OK: tcp_nopush on"
    fi

    # ── keepalive_timeout ─────────────────────────────────────────────────────
    if ! grep -q "keepalive_timeout" "$nginx_conf"; then
        make_backup
        insert_before "keepalive_timeout 65;" "types_hash_max_size"
        log "Added: keepalive_timeout 65"
    else
        log "OK: keepalive_timeout"
    fi

    # ── types_hash_max_size ───────────────────────────────────────────────────
    if ! grep -q "types_hash_max_size" "$nginx_conf"; then
        make_backup
        insert_before "types_hash_max_size 2048;" "include /etc/nginx/mime"
        log "Added: types_hash_max_size 2048"
    else
        log "OK: types_hash_max_size"
    fi

    # ── mime.types include ────────────────────────────────────────────────────
    if ! grep -q "include.*mime.types" "$nginx_conf"; then
        make_backup
        insert_before "include /etc/nginx/mime.types;" "default_type"
        log "Added: include mime.types"
    else
        log "OK: include mime.types"
    fi

    # ── default_type ──────────────────────────────────────────────────────────
    if ! grep -q "default_type" "$nginx_conf"; then
        make_backup
        insert_before "default_type application/octet-stream;" "## SSL"
        log "Added: default_type application/octet-stream"
    else
        log "OK: default_type"
    fi

    # ── ssl_protocols ─────────────────────────────────────────────────────────
    if ! grep -q "ssl_protocols" "$nginx_conf"; then
        make_backup
        insert_before "ssl_protocols TLSv1.2 TLSv1.3;" "ssl_prefer_server_ciphers"
        log "Added: ssl_protocols TLSv1.2 TLSv1.3"
    else
        log "OK: ssl_protocols"
    fi

    # ── ssl_prefer_server_ciphers ─────────────────────────────────────────────
    if ! grep -q "ssl_prefer_server_ciphers" "$nginx_conf"; then
        make_backup
        insert_before "ssl_prefer_server_ciphers on;" "## Gzip"
        log "Added: ssl_prefer_server_ciphers on"
    else
        log "OK: ssl_prefer_server_ciphers"
    fi

    # ── gzip on ───────────────────────────────────────────────────────────────
    if ! grep -q "gzip on" "$nginx_conf"; then
        make_backup
        insert_before "gzip on;" "## Virtual Hosts"
        log "Added: gzip on"
    else
        log "OK: gzip on"
    fi

    # ── include conf.d ────────────────────────────────────────────────────────
    if ! grep -q "include /etc/nginx/conf.d" "$nginx_conf"; then
        make_backup
        insert_before "include /etc/nginx/conf.d/*.conf;" "include /etc/nginx/sites-enabled"
        log "Added: include conf.d"
    else
        log "OK: include conf.d"
    fi

    # ── include sites-enabled ─────────────────────────────────────────────────
    if ! grep -q "include /etc/nginx/sites-enabled" "$nginx_conf"; then
        make_backup
        # Insert before the closing } of the http block (second-to-last })
        local line_no
        line_no=$(grep -n "^}" "$nginx_conf" | tail -2 | head -1 | cut -d: -f1)
        sed -i "${line_no}i\    include /etc/nginx/sites-enabled/*;" "$nginx_conf"
        log "Added: include sites-enabled"
    else
        log "OK: include sites-enabled"
    fi

    if [[ "$changed" == true ]]; then
        log "nginx.conf updated — backup saved at: $backup"
    else
        log "nginx.conf: all settings present — nothing changed"
    fi
}


# --- Create / update common-security.conf snippet ----------------------------
create_security_snippet() {
    local snippet="/etc/nginx/snippets/common-security.conf"
    mkdir -p /etc/nginx/snippets

    # If file already exists, leave it untouched
    if [[ -f "$snippet" ]]; then
        log "Security snippet already exists — skipping: $snippet"
        return 0
    fi

    log "Creating security snippet: $snippet"
    cat > "$snippet" <<'SNIPEOF'
# =============================================================================
# common-security.conf — managed by ssl_cert_manager.sh
# =============================================================================

# Block requests with no User-Agent
if ($http_user_agent = "") {
    return 444;
}
# Block common vulnerability scanners and bots
if ($http_user_agent ~* (nikto|nmap|masscan|nessus|openvas|acunetix|metasploit|sqlmap|havij|zmeu|dirbuster|hydra|ahrefs|semrush|mj12bot|dotbot|blexbot|bytespider|petalbot|yandexbot|ahrefsbot)) {
    return 444;
}
# Block suspicious query strings (SQL injection, XSS, file inclusion)
if ($query_string ~* "(base64_encode|base64_decode|eval\(|concat|union.*select|insert.*into|drop.*table|update.*set|delete.*from|<script|javascript:|onerror=|onload=|\.\.\/|\/etc\/passwd|proc\/self|select.*from|waitfor.*delay|benchmark\(|sleep\(|load_file|outfile|dumpfile)") {
    return 444;
}
# Block suspicious request methods
if ($request_method ~* ^(TRACE|TRACK|DEBUG)$) {
    return 444;
}
# Block requests with suspicious referers
if ($http_referer ~* (baidu|semalt|viagra|cialis|poker|porn|sex|adult|casino|lottery|get-free|buy-cheap)) {
    return 444;
}
# Block requests trying to access system directories
if ($request_uri ~* "^(/etc/|/proc/|/usr/|/var/|c:|\\\\)") {
    return 444;
}
# Block excessively long URLs (potential buffer overflow attempts)
if ($request_uri ~* ".{2048,}") {
    return 444;
}
# Block requests with null bytes
if ($request_uri ~* "\x00") {
    return 444;
}
# Block requests with multiple slashes or suspicious patterns
if ($request_uri ~* "(//|/\./|/\.\./|/\*|@|%00|%0d%0a)") {
    return 444;
}
# Block suspicious POST requests without referer (comment spam protection)
set $suspicious_post 0;
if ($request_method = POST) {
    set $suspicious_post 1;
}
if ($http_referer !~* ^https?://) {
    set $suspicious_post "${suspicious_post}1";
}
if ($suspicious_post = 11) {
    return 444;
}
# Block dangerous file extensions
location ~* \.(php[0-9]|phtml|phps|asp|aspx|jsp|jspx|cgi|pl|exe|dll|bat|cmd|sh|bash)$ {
    access_log /var/log/nginx/unknown_hosts.log combined;
    return 444;
}
# Block archive files
location ~* \.(zip|rar|tar|gz|tgz|bz2|7z|iso)$ {
    access_log /var/log/nginx/unknown_hosts.log combined;
    return 444;
}
# Block SQL and database files
location ~* \.(sql|db|sqlite|sqlite3|mdb)$ {
    access_log /var/log/nginx/unknown_hosts.log combined;
    return 444;
}
# Block backup and temp files
location ~* \.(bak|backup|old|tmp|temp|swp|swo|~|orig|save)$ {
    access_log /var/log/nginx/unknown_hosts.log combined;
    return 444;
}
# Block any path containing .php (prevents /path/.php/exploit)
location ~* /\.php {
    access_log /var/log/nginx/unknown_hosts.log combined;
    return 444;
}
# Block CMS admin paths (WordPress, Joomla, Drupal - not Laravel)
location ~* /(wp-admin|wp-includes|wp-content|wp-login\.php|xmlrpc\.php|administrator|phpmyadmin|pma|myadmin|dbadmin|cpanel|cgi-bin|drupal|joomla|magento|prestashop) {
    access_log /var/log/nginx/unknown_hosts.log combined;
    return 444;
}
# Block version control directories
location ~* /(\.git|\.svn|\.hg|\.bzr) {
    access_log /var/log/nginx/unknown_hosts.log combined;
    return 444;
}
# Block specific sensitive files
location ~* /(\.htaccess|\.htpasswd|\.user\.ini|php\.ini|readme\.html|license\.txt|changelog\.txt) {
    access_log /var/log/nginx/unknown_hosts.log combined;
    return 444;
}
# Block IDE and editor directories
location ~* /\.(idea|vscode|DS_Store)$ {
    access_log /var/log/nginx/unknown_hosts.log combined;
    return 444;
}
# Block common exploit/scanner file patterns
location ~* /(shell|c99|r57|c100|phpshell|backdoor|exploit|root|admin123|test\.php|info\.php|probe\.php)$ {
    access_log /var/log/nginx/unknown_hosts.log combined;
    return 444;
}
# Allow .well-known for SSL certificates
location ~ /\.well-known {
    allow all;
}
# Block other hidden files
location ~ /\.[^w] {
    access_log /var/log/nginx/unknown_hosts.log combined;
    return 444;
}
SNIPEOF

    chmod 644 "$snippet"
    log "Security snippet written: $snippet"
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

# Ensure nginx.conf has all required settings
ensure_nginx_conf_settings

# Update Cloudflare IPs in nginx.conf
update_cloudflare_ips


# Create / update common-security.conf snippet
create_security_snippet

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

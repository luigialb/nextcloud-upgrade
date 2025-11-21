#!/usr/bin/env bash
set -euo pipefail

# ========================================================================
# NEXTCLOUD UPGRADE SCRIPT - PHP 8.2 + NEXTCLOUD 32
# Author: Luigi Albanese (MatrixServers)
# Clean professional upgrade with on-screen descriptions
# Date: 2025-11-21
# ========================================================================

########################
# BASIC CONFIG
########################
NC_PATH="/var/www/nextcloud"
NC_USER="www-data"
PHP_VERSION="8.2"
TODAY="$(date +%Y%m%d-%H%M%S)"

########################
# HELPER FUNCTIONS
########################
info()  { echo -e "\n[\e[32mINFO\e[0m]  $*"; }
warn()  { echo -e "\n[\e[33mWARN\e[0m]  $*"; }
error() { echo -e "\n[\e[31mERROR\e[0m] $*" >&2; }
die()   { error "$*"; exit 1; }

pause() {
  read -r -p "Press ENTER to continue..." _
}

########################
# PRE-CHECKS
########################
clear
echo "============================================================"
echo "  Nextcloud Upgrade: PHP ${PHP_VERSION} + Nextcloud 32"
echo "  Host: $(hostname -f 2>/dev/null || hostname)"
echo "  Time: $(date)"
echo "============================================================"

# Must run as root
if [[ "$(id -u)" -ne 0 ]]; then
    die "This script must be run as root (use sudo)."
fi

# Check Nextcloud path
if [[ ! -f "${NC_PATH}/occ" ]]; then
    die "Nextcloud occ not found at ${NC_PATH}/occ. Adjust NC_PATH in the script."
fi

info "Using Nextcloud path: ${NC_PATH}"
info "PHP target version: ${PHP_VERSION}"

########################
# SHOW CURRENT STATUS
########################
info "Current PHP and Nextcloud status:"

if command -v php >/dev/null 2>&1; then
    php -v | head -n 2 || true
else
    warn "php CLI not found in PATH."
fi

sudo -u "${NC_USER}" php "${NC_PATH}/occ" status || warn "Could not run occ status (will continue)."

pause

########################
# ENABLE MAINTENANCE MODE
########################
info "Enabling Nextcloud maintenance mode..."
sudo -u "${NC_USER}" php "${NC_PATH}/occ" maintenance:mode --on || warn "Failed to enable maintenance mode (check manually)."

########################
# BACKUPS
########################
BACKUP_DIR="/var/backups/nextcloud-upgrade-${TODAY}"
mkdir -p "${BACKUP_DIR}"

info "Backing up config.php and important configs to: ${BACKUP_DIR}"

if [[ -f "${NC_PATH}/config/config.php" ]]; then
    cp -a "${NC_PATH}/config/config.php" "${BACKUP_DIR}/config.php.${TODAY}.bak"
fi

if [[ -d "/etc/php/${PHP_VERSION}/fpm/pool.d" ]]; then
    cp -a "/etc/php/${PHP_VERSION}/fpm/pool.d" "${BACKUP_DIR}/php${PHP_VERSION}-fpm-pool.d.${TODAY}.bak" || true
fi

if [[ -d "/etc/apache2/sites-available" ]]; then
    cp -a "/etc/apache2/sites-available" "${BACKUP_DIR}/apache2-sites-available.${TODAY}.bak" || true
fi

info "Backups done."

########################
# INSTALL / UPGRADE PHP 8.2 + MODULES
########################
info "Ensuring PHP ${PHP_VERSION} and required modules are installed..."

# Optional: add ondrej/php PPA if not present (Ubuntu-based)
if command -v add-apt-repository >/dev/null 2>&1; then
    if ! grep -Rqi "ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
        info "Adding PPA: ondrej/php (if this is Ubuntu)..."
        add-apt-repository -y ppa:ondrej/php || warn "Could not add ondrej/php (maybe not Ubuntu). Continuing."
    fi
fi

apt-get update -y

apt-get install -y \
  "php${PHP_VERSION}-fpm" \
  "php${PHP_VERSION}-cli" \
  "php${PHP_VERSION}-gd" \
  "php${PHP_VERSION}-curl" \
  "php${PHP_VERSION}-xml" \
  "php${PHP_VERSION}-zip" \
  "php${PHP_VERSION}-intl" \
  "php${PHP_VERSION}-mbstring" \
  "php${PHP_VERSION}-pgsql" \
  "php${PHP_VERSION}-bz2" \
  "php${PHP_VERSION}-gmp" || die "Failed to install PHP ${PHP_VERSION} modules."

# imagick package name can vary, so keep optional
apt-get install -y php-imagick || warn "php-imagick not installed (optional)."

info "PHP ${PHP_VERSION} installed/updated."

########################
# CONFIGURE PHP-FPM POOL FOR NEXTCLOUD
########################
NC_POOL_FILE="/etc/php/${PHP_VERSION}/fpm/pool.d/nextcloud.conf"

info "Configuring PHP-FPM pool for Nextcloud: ${NC_POOL_FILE}"

cat > "${NC_POOL_FILE}" <<EOF
[nextcloud]
user = ${NC_USER}
group = ${NC_USER}
listen = /run/php/php${PHP_VERSION}-fpm.nextcloud.sock
listen.owner = ${NC_USER}
listen.group = ${NC_USER}
listen.mode = 0660

pm = dynamic
pm.max_children = 50
pm.start_servers = 5
pm.min_spare_servers = 5
pm.max_spare_servers = 35

env[HOSTNAME] = \$HOSTNAME
env[PATH] = /usr/local/bin:/usr/bin:/bin
env[TMP] = /tmp
env[TMPDIR] = /tmp
env[TEMP] = /tmp
EOF

info "Reloading PHP-FPM ${PHP_VERSION}..."
systemctl enable "php${PHP_VERSION}-fpm" >/dev/null 2>&1 || true
systemctl restart "php${PHP_VERSION}-fpm"

systemctl --no-pager --full status "php${PHP_VERSION}-fpm" | sed -n '1,8p' || true

########################
# APACHE MODULES
########################
info "Enabling required Apache modules..."
a2enmod proxy proxy_fcgi setenvif mime ssl headers rewrite >/dev/null 2>&1 || true

# Disable legacy php8.1-fpm config if present
if [[ -f /etc/apache2/conf-enabled/php8.1-fpm.conf || -L /etc/apache2/conf-enabled/php8.1-fpm.conf ]]; then
    info "Disabling old php8.1-fpm Apache conf..."
    a2disconf php8.1-fpm || true
fi

########################
# VHOST SELECTION (B + C COMBINED)
########################
info "Now we will choose which Apache vhost to update for PHP ${PHP_VERSION}."

echo
echo "Choose how to select the vhost file:"
echo "  1) Auto-detect Nextcloud vhosts and choose from a list   (Option C)"
echo "  2) Manually enter the vhost .conf path                   (Option B)"
echo

read -r -p "Enter 1 or 2: " VHOST_SELECT_MODE

VHOST_FILE=""

if [[ "${VHOST_SELECT_MODE}" == "1" ]]; then
    info "Auto-detecting vhosts referencing Nextcloud..."

    mapfile -t CANDIDATES < <(
        grep -l "DocumentRoot ${NC_PATH}" /etc/apache2/sites-available/*.conf 2>/dev/null || true
    )

    # Also search for 'nextcloud' string as a fallback
    mapfile -t CANDIDATES_EXTRA < <(
        grep -l "nextcloud" /etc/apache2/sites-available/*.conf 2>/dev/null || true
    )

    # Merge and unique
    CANDIDATES=("${CANDIDATES[@]}" "${CANDIDATES_EXTRA[@]}")
    # Remove empties & duplicates
    TMP_LIST=()
    for f in "${CANDIDATES[@]}"; do
        [[ -n "${f}" ]] && [[ -f "${f}" ]] && TMP_LIST+=("${f}")
    done
    # Unique
    CANDIDATES=($(printf "%s\n" "${TMP_LIST[@]}" | sort -u))

    if [[ "${#CANDIDATES[@]}" -eq 0 ]]; then
        warn "No vhosts with 'nextcloud' detected. Falling back to manual input."
        VHOST_SELECT_MODE="2"
    else
        echo
        echo "Detected vhosts:"
        i=1
        for f in "${CANDIDATES[@]}"; do
            echo "  ${i}) ${f}"
            i=$((i+1))
        done
        echo
        read -r -p "Enter the number of the vhost to update: " VHOST_IDX
        if ! [[ "${VHOST_IDX}" =~ ^[0-9]+$ ]] || (( VHOST_IDX < 1 || VHOST_IDX > ${#CANDIDATES[@]} )); then
            die "Invalid vhost selection."
        fi
        VHOST_FILE="${CANDIDATES[$((VHOST_IDX-1))]}"
    fi
fi

if [[ "${VHOST_SELECT_MODE}" == "2" ]]; then
    echo
    read -r -p "Enter full path to the Apache vhost .conf file (e.g. /etc/apache2/sites-available/nchub1.laconstructioninc.com.conf): " VHOST_FILE
fi

[[ -z "${VHOST_FILE}" ]] && die "No vhost file selected."
[[ -f "${VHOST_FILE}" ]] || die "Vhost file ${VHOST_FILE} does not exist."

info "Selected vhost: ${VHOST_FILE}"

# Backup selected vhost
cp -a "${VHOST_FILE}" "${BACKUP_DIR}/$(basename "${VHOST_FILE}").${TODAY}.bak"
info "Vhost backup created at: ${BACKUP_DIR}/$(basename "${VHOST_FILE}").${TODAY}.bak"

########################
# UPDATE VHOST FOR PHP 8.2-FPM
########################
info "Updating vhost to use PHP ${PHP_VERSION}-FPM Nextcloud socket..."

# Replace any php8.1 strings by php8.2 (safe, simple)
sed -i "s/php8\.1/php${PHP_VERSION}/g" "${VHOST_FILE}"

# Remove any bad ProxyPassMatch lines inside vhost (to avoid syntax issues)
if grep -q "ProxyPassMatch" "${VHOST_FILE}"; then
    warn "Found ProxyPassMatch in vhost; commenting it out to avoid syntax errors..."
    sed -i 's/^\(\s*ProxyPassMatch\)/# \1 (disabled by nc upgrade script)/' "${VHOST_FILE}" || true
fi

# Ensure we have a proper FilesMatch block with php8.2-fpm.nextcloud.sock
if ! grep -q "php${PHP_VERSION}-fpm.nextcloud.sock" "${VHOST_FILE}"; then
    info "Inserting FilesMatch block for PHP ${PHP_VERSION}-FPM Nextcloud socket inside <VirtualHost *:443>..."

    PHP_BLOCK=$'\t<FilesMatch ".+\\.php$">\n\t\tSetHandler "proxy:unix:/run/php/php'"${PHP_VERSION}"'-fpm.nextcloud.sock|fcgi://localhost/"\n\t</FilesMatch>\n'

    awk -v block="${PHP_BLOCK}" '
        /<VirtualHost[[:space:]]+\*:443>/ { in_vh=1 }
        in_vh && /ServerName/ && !inserted {
            print
            print block
            inserted=1
            next
        }
        { print }
    ' "${VHOST_FILE}" > "${VHOST_FILE}.tmp" && mv "${VHOST_FILE}.tmp" "${VHOST_FILE}"

    info "FilesMatch block inserted."
else
    info "Vhost already references php${PHP_VERSION}-fpm.nextcloud.sock; keeping existing FilesMatch."
fi

########################
# ENABLE VHOST & RESTART APACHE
########################
VHOST_BASENAME="$(basename "${VHOST_FILE}")"
info "Enabling vhost ${VHOST_BASENAME} (if not already enabled)..."
a2ensite "${VHOST_BASENAME}" >/dev/null 2>&1 || true

info "Testing Apache configuration..."
if ! apachectl configtest; then
    die "Apache config test failed. Check ${VHOST_FILE} and ${BACKUP_DIR} backup."
fi

info "Restarting Apache..."
systemctl restart apache2

systemctl --no-pager --full status apache2 | sed -n '1,8p' || true

########################
# NEXTCLOUD CORE UPGRADE (OPTIONAL PLACEHOLDER)
########################
info "Nextcloud core is already on version 32.x in your environment."
info "For this script version, we only ensure PHP ${PHP_VERSION} + FPM + Apache vhost are correct."

########################
# DISABLE MAINTENANCE MODE
########################
info "Disabling Nextcloud maintenance mode..."
sudo -u "${NC_USER}" php "${NC_PATH}/occ" maintenance:mode --off || warn "Could not disable maintenance mode (check UI)."

info "Final Nextcloud status:"
sudo -u "${NC_USER}" php "${NC_PATH}/occ" status || true

echo
echo "============================================================"
echo "  Upgrade script completed."
echo "  PHP ${PHP_VERSION} + FPM + Apache vhost updated."
echo "  Backups in: ${BACKUP_DIR}"
echo "============================================================"

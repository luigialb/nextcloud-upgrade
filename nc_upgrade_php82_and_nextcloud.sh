#!/usr/bin/env bash
set -euo pipefail

#########################
# CONFIGURE THESE FIRST #
#########################

# Nextcloud install dir (same as current Hansson VM)
NC_DIR="/var/www/nextcloud"

# External data directory (yours is on another disk)
NC_DATA_DIR="/mnt/ncdata"

# Database info (adjust if different on the new instance)
NC_DB_NAME="nextcloud_db"
NC_DB_USER="nextcloud_db_user"

# Nextcloud version you are upgrading TO
# 🔴 IMPORTANT: change this before running when a new version is released
NEXTCLOUD_VERSION="32.0.2"
NEXTCLOUD_TARBALL="nextcloud-${NEXTCLOUD_VERSION}.tar.bz2"
NEXTCLOUD_URL="https://download.nextcloud.com/server/releases/${NEXTCLOUD_TARBALL}"

# Backups
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_ROOT="/var/backups/nextcloud-${TS}"
NC_OLD_DIR="/var/www/nextcloud-${TS}"

# PHP version target
PHP_TARGET="8.2"

echo "========================================="
echo " Nextcloud + PHP ${PHP_TARGET} Upgrade Script"
echo " Timestamp: ${TS}"
echo " NC_DIR: ${NC_DIR}"
echo " NC_DATA_DIR: ${NC_DATA_DIR}"
echo " BACKUP_ROOT: ${BACKUP_ROOT}"
echo " TARGET NC VERSION: ${NEXTCLOUD_VERSION}"
echo "========================================="
echo

#####################################
# 1) Basic checks                   #
#####################################

if [ ! -d "${NC_DIR}" ]; then
  echo "ERROR: Nextcloud directory ${NC_DIR} does not exist."
  exit 1
fi

if [ ! -d "${NC_DATA_DIR}" ]; then
  echo "WARNING: Data directory ${NC_DATA_DIR} not found."
  echo "If your data is elsewhere, adjust NC_DATA_DIR in this script."
fi

if [ ! -f "${NC_DIR}/config/config.php" ]; then
  echo "ERROR: ${NC_DIR}/config/config.php not found."
  exit 1
fi

#####################################
# 2) Install PHP 8.2 + modules      #
#####################################

echo
echo "==> Installing PHP ${PHP_TARGET} and required extensions..."

# Make sure PPA is available (for Ubuntu 22.04 style systems)
if ! grep -qi "ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
  echo "Adding ondrej/php PPA (if not already present)..."
  apt-get update
  apt-get install -y software-properties-common
  add-apt-repository -y ppa:ondrej/php
fi

apt-get update

apt-get install -y \
  php${PHP_TARGET} \
  php${PHP_TARGET}-cli \
  php${PHP_TARGET}-fpm \
  php${PHP_TARGET}-gd \
  php${PHP_TARGET}-curl \
  php${PHP_TARGET}-intl \
  php${PHP_TARGET}-mbstring \
  php${PHP_TARGET}-xml \
  php${PHP_TARGET}-zip \
  php${PHP_TARGET}-bz2 \
  php${PHP_TARGET}-gmp \
  php${PHP_TARGET}-pgsql \
  php-redis \
  php-apcu \
  php-imagick

echo "PHP ${PHP_TARGET} and extensions installed."

#####################################
# 3) Switch Apache to PHP 8.2-FPM   #
#####################################

echo
echo "==> Configuring Apache to use PHP ${PHP_TARGET}-FPM..."

# Disable old mod_php8.1 if present (we keep the package, just stop using it)
a2dismod php8.1 2>/dev/null || true

# Enable FPM proxy modules
a2enmod proxy_fcgi setenvif

# Enable PHP 8.2 FPM config if exists
if [ -f /etc/apache2/conf-available/php${PHP_TARGET}-fpm.conf ]; then
  a2enconf php${PHP_TARGET}-fpm
fi

# Ensure php-fpm service is enabled
systemctl enable php${PHP_TARGET}-fpm
systemctl restart php${PHP_TARGET}-fpm

# Optional: stop 8.1 FPM if you don't need it anymore
if systemctl is-enabled --quiet php8.1-fpm 2>/dev/null; then
  systemctl disable php8.1-fpm || true
fi
systemctl stop php8.1-fpm 2>/dev/null || true

systemctl restart apache2

echo "Apache now configured for PHP ${PHP_TARGET}-FPM."
echo

#####################################
# 4) Put Nextcloud in maintenance   #
#####################################

echo "==> Enabling Nextcloud maintenance mode..."
sudo -u www-data php${PHP_TARGET} "${NC_DIR}/occ" maintenance:mode --on

#####################################
# 5) Create backups                 #
#####################################

echo
echo "==> Creating backups in ${BACKUP_ROOT}..."
mkdir -p "${BACKUP_ROOT}"

# Backup config
echo " - Backing up config.php..."
cp -a "${NC_DIR}/config" "${BACKUP_ROOT}/config"

# Backup Nextcloud code
echo " - Backing up Nextcloud code to ${NC_OLD_DIR}..."
mv "${NC_DIR}" "${NC_OLD_DIR}"

# Recreate empty NC_DIR for new files
mkdir -p "${NC_DIR}"
chown www-data:www-data "${NC_DIR}"

# Backup database (PostgreSQL)
echo " - Backing up PostgreSQL database ${NC_DB_NAME}..."
sudo -u postgres pg_dump -Fc "${NC_DB_NAME}" > "${BACKUP_ROOT}/db-${NC_DB_NAME}.dump"

echo "Backups created."
echo

#####################################
# 6) Download & extract new NC      #
#####################################

echo "==> Downloading Nextcloud ${NEXTCLOUD_VERSION}..."
cd /tmp
rm -f "${NEXTCLOUD_TARBALL}"
wget "${NEXTCLOUD_URL}"

echo "==> Extracting Nextcloud ${NEXTCLOUD_VERSION}..."
rm -rf /tmp/nextcloud
tar -xjf "${NEXTCLOUD_TARBALL}"

# /tmp/nextcloud now contains clean NC code
echo "==> Syncing new Nextcloud code to ${NC_DIR}..."
rsync -Aax /tmp/nextcloud/ "${NC_DIR}/"

#####################################
# 7) Restore config & custom apps   #
#####################################

echo
echo "==> Restoring config.php..."
# Overwrite new config dir with old one (only config, not apps or data)
rm -rf "${NC_DIR}/config"
cp -a "${BACKUP_ROOT}/config" "${NC_DIR}/config"

# If you have custom apps in the old instance, sync them:
if [ -d "${NC_OLD_DIR}/apps" ]; then
  echo "==> Syncing apps from old instance (custom apps)..."
  rsync -Aax "${NC_OLD_DIR}/apps/" "${NC_DIR}/apps/"
fi

# Ensure ownership is correct
chown -R www-data:www-data "${NC_DIR}"

#####################################
# 8) Run upgrade                    #
#####################################

echo
echo "==> Running occ upgrade with PHP ${PHP_TARGET}..."
cd "${NC_DIR}"
sudo -u www-data php${PHP_TARGET} occ upgrade

#####################################
# 9) Run integrity check            #
#####################################

echo
echo "==> Running core integrity check..."
sudo -u www-data php${PHP_TARGET} occ integrity:check-core || true

echo
echo "If there are ONLY 'EXTRA_FILE' warnings from old leftovers, "
echo "they usually come from files outside the official release."
echo "Because we used a clean code directory this should normally be clean."

#####################################
# 10) Disable maintenance mode      #
#####################################

echo
echo "==> Disabling maintenance mode..."
sudo -u www-data php${PHP_TARGET} occ maintenance:mode --off

#####################################
# 11) Final service restart         #
#####################################

echo
echo "==> Restarting services..."
systemctl restart php${PHP_TARGET}-fpm
systemctl restart apache2

echo
echo "========================================="
echo " Upgrade complete."
echo " - Backups stored in: ${BACKUP_ROOT}"
echo " - Old code in:       ${NC_OLD_DIR}"
echo " - Nextcloud dir:     ${NC_DIR}"
echo "========================================="
echo "Now test your instance in the browser:"
echo "  -> https://nchub1.laconstructioninc.com"
echo "If everything is 100%, you can later remove ${NC_OLD_DIR} to free space."

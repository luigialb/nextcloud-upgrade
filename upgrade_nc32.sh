#!/usr/bin/env bash
set -euo pipefail

NC_DIR="/var/www/nextcloud"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="/var/www/nextcloud-backup_${TIMESTAMP}"
NC_OLD_DIR="/var/www/nextcloud-old_${TIMESTAMP}"
SQL_BACKUP="/root/nextcloud-db-backup_${TIMESTAMP}.dump"

step() {
  echo
  echo "============================================================"
  echo "  $1"
  echo "============================================================"
  echo
}

# 0. Safety checks
if [[ "$EUID" -ne 0 ]]; then
  echo "Please run this script as root (use: sudo bash upgrade_nc32.sh)"
  exit 1
fi

if [[ ! -d "$NC_DIR" ]] || [[ ! -f "$NC_DIR/config/config.php" ]]; then
  echo "Nextcloud not found at $NC_DIR or config.php missing. Aborting."
  exit 1
fi

step "Reading Nextcloud config (DB type, DB name/user, data directory)"

DB_TYPE=$(php -r "include '${NC_DIR}/config/config.php'; echo \$CONFIG['dbtype'];")
DB_NAME=$(php -r "include '${NC_DIR}/config/config.php'; echo \$CONFIG['dbname'];")
DB_USER=$(php -r "include '${NC_DIR}/config/config.php'; echo isset(\$CONFIG['dbuser']) ? \$CONFIG['dbuser'] : '';")
DB_PASS=$(php -r "include '${NC_DIR}/config/config.php'; echo isset(\$CONFIG['dbpassword']) ? \$CONFIG['dbpassword'] : '';")
DATA_DIR=$(php -r "include '${NC_DIR}/config/config.php'; echo \$CONFIG['datadirectory'];")

echo "Detected DB type:  ${DB_TYPE}"
echo "Detected DB name:  ${DB_NAME}"
echo "Detected DB user:  ${DB_USER}"
echo "Detected data dir: ${DATA_DIR}"

# Safety: do NOT proceed if data directory is inside NC_DIR
if [[ -n "$DATA_DIR" && "$DATA_DIR" == "${NC_DIR}"* ]]; then
  echo
  echo "WARNING: Your datadirectory is inside ${NC_DIR}."
  echo "This script is written assuming Hansson VM style (external data dir)."
  echo "Refusing to continue to avoid any risk of data loss."
  exit 1
fi

step "Enabling maintenance mode"

sudo -u www-data php "${NC_DIR}/occ" maintenance:mode --on || true

step "Creating file backup at ${BACKUP_DIR}"

rsync -Aavx "${NC_DIR}/" "${BACKUP_DIR}/"

step "Creating database backup at ${SQL_BACKUP}"

case "${DB_TYPE}" in
  pgsql)
    echo "Using pg_dump (PostgreSQL) for backup..."
    # Most Hansson VMs run PostgreSQL locally with 'postgres' superuser
    if id postgres >/dev/null 2>&1; then
      sudo -u postgres pg_dump -Fc "${DB_NAME}" > "${SQL_BACKUP}"
    else
      # Fallback: try DB_USER if postgres user does not exist
      if [[ -n "${DB_PASS}" ]]; then
        PGPASSWORD="${DB_PASS}" pg_dump -Fc -U "${DB_USER}" "${DB_NAME}" > "${SQL_BACKUP}"
      else
        pg_dump -Fc -U "${DB_USER}" "${DB_NAME}" > "${SQL_BACKUP}"
      fi
    fi
    ;;
  mysql|mysqli)
    echo "Using mysqldump (MySQL/MariaDB) for backup..."
    if [[ -n "${DB_NAME}" && -n "${DB_USER}" ]]; then
      if [[ -n "${DB_PASS}" ]]; then
        mysqldump -u "${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" > "${SQL_BACKUP}"
      else
        mysqldump -u "${DB_USER}" "${DB_NAME}" > "${SQL_BACKUP}"
      fi
    else
      echo "Could not detect DB name/user from config.php for MySQL/MariaDB."
      exit 1
    fi
    ;;
  *)
    echo "Unsupported dbtype '${DB_TYPE}' in config.php. Aborting."
    exit 1
    ;;
esac

echo
echo "Backups done:"
echo "  Files: ${BACKUP_DIR}"
echo "  DB:    ${SQL_BACKUP}"
echo

step "Adding PHP 8.2 repository and updating package lists"

apt-get update
apt-get install -y software-properties-common
add-apt-repository -y ppa:ondrej/php
apt-get update

step "Installing PHP 8.2 and required modules"

apt-get install -y \
  php8.2 php8.2-cli php8.2-fpm \
  php8.2-gd php8.2-curl php8.2-mbstring php8.2-intl \
  php8.2-xml php8.2-zip php8.2-sqlite3 php8.2-imap \
  php8.2-apcu php8.2-redis php8.2-bz2 php8.2-gmp \
  php8.2-imagick php8.2-opcache

# Make CLI "php" use 8.2
update-alternatives --set php /usr/bin/php8.2 || true

step "Switching Apache/PHP to PHP 8.2"

if systemctl list-unit-files | grep -q "php8.1-fpm.service"; then
  echo "Detected PHP 8.1-FPM setup (likely Hansson VM style). Switching to PHP 8.2-FPM."

  apt-get install -y libapache2-mod-fcgid

  a2disconf php8.1-fpm || true
  a2enconf php8.2-fpm || true

  systemctl disable php8.1-fpm || true
  systemctl stop php8.1-fpm || true

  systemctl enable php8.2-fpm
  systemctl restart php8.2-fpm
else
  echo "No php8.1-fpm service detected. Assuming mod_php setup."
  apt-get install -y libapache2-mod-php8.2

  a2dismod php8.1 || true
  a2enmod php8.2 || true
fi

systemctl restart apache2

step "Downloading Nextcloud 32"

cd /tmp
rm -rf /tmp/nextcloud /tmp/latest-32.tar.bz2 || true
wget https://download.nextcloud.com/server/releases/latest-32.tar.bz2
tar -xjf latest-32.tar.bz2

step "Replacing Nextcloud code with version 32 (keeping config + apps, external data)"

echo "Moving current Nextcloud to ${NC_OLD_DIR}"
mv "${NC_DIR}" "${NC_OLD_DIR}"
mkdir -p "${NC_DIR}"

echo "Copying new Nextcloud 32 files..."
cp -R /tmp/nextcloud/* "${NC_DIR}/"

echo "Restoring config.php..."
mkdir -p "${NC_DIR}/config"
cp -R "${NC_OLD_DIR}/config/"* "${NC_DIR}/config/"

echo "Restoring apps (including any third-party apps)..."
mkdir -p "${NC_DIR}/apps"
cp -R "${NC_OLD_DIR}/apps/"* "${NC_DIR}/apps/" || true

step "Fixing permissions"

chown -R www-data:www-data "${NC_DIR}"

step "Running Nextcloud upgrade (occ upgrade) with PHP 8.2"

sudo -u www-data php8.2 "${NC_DIR}/occ" upgrade

step "Disabling maintenance mode"

sudo -u www-data php8.2 "${NC_DIR}/occ" maintenance:mode --off

step "Cleaning up temporary files"

rm -rf /tmp/nextcloud /tmp/latest-32.tar.bz2 || true

echo
echo "============================================================"
echo "  NEXTCLOUD 32 UPGRADE COMPLETE"
echo "============================================================"
echo
echo "Backup of old installation: ${NC_OLD_DIR}"
echo "File backup:                ${BACKUP_DIR}"
echo "Database backup:            ${SQL_BACKUP}"
echo
echo "If everything works fine for a few days, you can remove the"
echo "old backup directories to free disk space."
echo
echo "Enjoy Nextcloud 32 with PHP 8.2 🎉"

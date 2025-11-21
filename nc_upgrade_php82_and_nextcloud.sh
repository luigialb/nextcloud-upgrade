#!/bin/bash
# ========================================================================
# NEXTCLOUD UPGRADE SCRIPT - PHP 8.2 + NEXTCLOUD 32
# Author: Luigi Albanese (MatrixServers)
# Clean professional upgrade with on-screen descriptions
# ========================================================================

NC_PATH="/var/www/nextcloud"
BACKUP_PATH="/var/www/backup_$(date +%Y%m%d_%H%M)"
NC_DOWNLOAD="/tmp/nextcloud-latest.zip"
PHP_OLD="8.1"
PHP_NEW="8.2"

GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
NC="\e[0m"

echo -e "${GREEN}"
echo "========================================================="
echo "   NEXTCLOUD + PHP UPGRADE SCRIPT (Auto-Repair Included) "
echo "========================================================="
echo -e "${NC}"

# ------------------------------------------------------------
# 1. CHECK IF RUNNING AS ROOT
# ------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: Please run this script as root.${NC}"
    exit 1
fi

# ------------------------------------------------------------
# 2. INSTALL PHP 8.2 AND MODULES
# ------------------------------------------------------------
echo -e "${YELLOW}Installing PHP $PHP_NEW + required extensions...${NC}"

apt update -y
apt install -y software-properties-common
add-apt-repository ppa:ondrej/php -y
apt update -y

apt install -y php$PHP_NEW php$PHP_NEW-fpm php$PHP_NEW-cli php$PHP_NEW-common \
php$PHP_NEW-zip php$PHP_NEW-xml php$PHP_NEW-gd php$PHP_NEW-curl php$PHP_NEW-mbstring \
php$PHP_NEW-intl php$PHP_NEW-bz2 php$PHP_NEW-imagick php$PHP_NEW-gmp php$PHP_NEW-pgsql \
php$PHP_NEW-readline php$PHP_NEW-apcu php$PHP_NEW-redis php$PHP_NEW-bcmath

echo -e "${GREEN}PHP $PHP_NEW installed successfully.${NC}"

# Disable old PHP
systemctl disable php$PHP_OLD-fpm --now >/dev/null 2>&1 || true

# Enable new PHP
systemctl enable php$PHP_NEW-fpm --now

# ------------------------------------------------------------
# 3. NEXTCLOUD BACKUP
# ------------------------------------------------------------
echo -e "${YELLOW}Creating backup at: $BACKUP_PATH${NC}"

mkdir -p "$BACKUP_PATH"
cp -r "$NC_PATH" "$BACKUP_PATH/"
echo -e "${GREEN}Backup complete.${NC}"

# ------------------------------------------------------------
# 4. DOWNLOAD LATEST NEXTCLOUD 32
# ------------------------------------------------------------
echo -e "${YELLOW}Downloading Nextcloud 32...${NC}"
wget -O "$NC_DOWNLOAD" https://download.nextcloud.com/server/releases/latest.zip

unzip "$NC_DOWNLOAD" -d /tmp/

# ------------------------------------------------------------
# 5. ENABLE MAINTENANCE MODE
# ------------------------------------------------------------
echo -e "${YELLOW}Putting Nextcloud in maintenance mode...${NC}"
sudo -u www-data php$PHP_NEW $NC_PATH/occ maintenance:mode --on

# ------------------------------------------------------------
# 6. REMOVE OLD APP CODE + CORE FILES
# ------------------------------------------------------------
echo -e "${YELLOW}Cleaning old Nextcloud files (preserving config + data)...${NC}"

rm -rf $NC_PATH/3rdparty
rm -rf $NC_PATH/core
rm -rf $NC_PATH/apps/*

# DO NOT DELETE:
# /var/www/nextcloud/config
# /mnt/ncdata

# ------------------------------------------------------------
# 7. COPY NEW NEXTCLOUD FILES
# ------------------------------------------------------------
echo -e "${YELLOW}Copying new Nextcloud files...${NC}"

cp -r /tmp/nextcloud/* $NC_PATH/

echo -e "${GREEN}File copy complete.${NC}"

# ------------------------------------------------------------
# 8. FIX PERMISSIONS
# ------------------------------------------------------------
echo -e "${YELLOW}Fixing permissions...${NC}"

chown -R www-data:www-data $NC_PATH
find $NC_PATH/ -type d -exec chmod 750 {} \;
find $NC_PATH/ -type f -exec chmod 640 {} \;

# ------------------------------------------------------------
# 9. RUN DATABASE UPGRADE
# ------------------------------------------------------------
echo -e "${YELLOW}Running occ upgrade...${NC}"

sudo -u www-data php$PHP_NEW $NC_PATH/occ upgrade

# ------------------------------------------------------------
# 10. DISABLE MAINTENANCE MODE
# ------------------------------------------------------------
echo -e "${YELLOW}Disabling maintenance mode...${NC}"
sudo -u www-data php$PHP_NEW $NC_PATH/occ maintenance:mode --off

# ------------------------------------------------------------
# 11. FINAL CHECK
# ------------------------------------------------------------
echo -e "${GREEN}"
echo "========================================================="
echo "     UPGRADE COMPLETE — NEXTCLOUD IS NOW UPDATED!        "
echo "========================================================="
echo -e "${NC}"

sudo -u www-data php$PHP_NEW $NC_PATH/occ status

#!/usr/bin/env bash
# ==============================================================
# 🌐 LibreNMS Installer Script
# Target: Ubuntu 24.04 Minimal
# 
# Installs and configures LibreNMS end-to-end:
#  • Detects or installs required packages (PHP, MySQL, Nginx, SNMP, etc.)
#  • Creates librenms user, clones repo, sets ACLs
#  • Installs Composer deps, configures MariaDB (DB + user + charset)
#  • Sets up PHP-FPM pool, Nginx vhost (HTTP only, no SSL)
#  • Deploys SNMP agent, cron jobs, logrotate, systemd scheduler
#  • Updates .env with APP_URL
# 
# Non-interactive DevOps variables:
#   LIBRENMS_DOMAIN, DB_PASSWORD, SNMP_COMMUNITY, TZ, PHP_VER,
#   USE_UTF8_LOCALES
# 
# NOTE: SSL/HTTPS is handled via Cloudflare tunnel on separate VM
# ==============================================================

# --- Fail early, strict shell settings ---
set -euo pipefail
IFS=$'\n\t'
trap 'echo "✖ Error at line $LINENO"; exit 1' ERR

# --- Ensure running as root ---
if [[ $EUID -ne 0 ]]; then
  echo "✖ Please run as root or via sudo."
  exit 1
fi

# === 🎨 COLORS ===
RED='\033[1;31m'; GRN='\033[1;32m'
YEL='\033[1;33m'; CYN='\033[1;36m'
RST='\033[0m'

banner() {
  echo -e "\n${CYN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
  echo -e "🛠️  ${1}"
  echo -e "${CYN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
}
success() { echo -e "${GRN}✔ ${1}${RST}"; }
skip()    { echo -e "${YEL}⏭ ${1}${RST}"; }
error()   { echo -e "${RED}✖ ${1}${RST}" >&2; }

# === 🔧 VARIABLES ===
LIBRENMS_DOMAIN="${LIBRENMS_DOMAIN:-}"
DB_PASSWORD="${DB_PASSWORD:-}"
SNMP_COMMUNITY="${SNMP_COMMUNITY:-}"
TZ="${TZ:-}"
PHP_VER="${PHP_VER:-}"
USE_UTF8_LOCALES="${USE_UTF8_LOCALES:-yes}"

# === 📥 PROMPTS IF VARIABLES NOT SET ===
[[ -z "$LIBRENMS_DOMAIN" ]] && read -rp "Enter LibreNMS domain or IP: " LIBRENMS_DOMAIN
[[ -z "$DB_PASSWORD" ]]     && { DB_PASSWORD=$(openssl rand -hex 16); echo -e "${YEL}Generated DB password: $DB_PASSWORD${RST}"; }
[[ -z "$SNMP_COMMUNITY" ]]  && read -rp "Enter SNMP community [public]: " SNMP_COMMUNITY && SNMP_COMMUNITY=${SNMP_COMMUNITY:-public}
if [[ -z "$TZ" ]]; then
  echo -e "${CYN}Refer to timezone list: https://en.wikipedia.org/wiki/List_of_tz_database_time_zones${RST}"
  read -rp "Enter timezone (e.g. America/Phoenix): " TZ
  timedatectl set-timezone "$TZ"
fi

if [[ -z "$PHP_VER" ]]; then
  if [[ -d /etc/php ]]; then
    PHP_VER=$(ls /etc/php | grep -E '^[0-9]+\.[0-9]+' | sort -Vr | head -n1)
  else
    PHP_VER="8.4"
    echo -e "${YEL}⚠ No PHP found; defaulting to PHP $PHP_VER.${RST}"
  fi
fi

# === 🚨 Nuke Existing Installation Prompt ===
if [[ -d /opt/librenms ]] || mysql -uroot -e "USE librenms;" &>/dev/null; then
  echo -e "\n${YEL}Existing LibreNMS detected!${RST}"
  echo "This will remove:"
  echo "  • /opt/librenms"
  echo "  • MariaDB librenms DB & user"
  echo "  • Nginx librenms site"
  echo "  • PHP-FPM pool"
  echo "  • SNMP config & agent script"
  echo "  • Cron & logrotate entries"
  read -rp "Proceed to nuke and start fresh? [y/N]: " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborting—existing installation preserved."
    exit 1
  fi

  echo "⏳ Removing old installation..."
  rm -rf /opt/librenms \
         /etc/nginx/sites-available/librenms.conf \
         /etc/nginx/sites-enabled/librenms.conf \
         /etc/php/${PHP_VER}/fpm/pool.d/librenms.conf \
         /etc/snmp/snmpd.conf /usr/bin/distro \
         /etc/cron.d/librenms /etc/logrotate.d/librenms

  echo "⏳ Dropping database..."
  mysql -uroot <<SQL
DROP DATABASE IF EXISTS librenms;
DROP USER IF EXISTS 'librenms'@'localhost';
FLUSH PRIVILEGES;
SQL

  success "Previous LibreNMS installation nuked."
fi

# === 🧱 INSTALL BASE PACKAGES ===
banner "Installing Required Packages"
export DEBIAN_FRONTEND=noninteractive

apt update -y \
  && apt full-upgrade -y \
  && apt install -y software-properties-common

if [[ "$USE_UTF8_LOCALES" == "yes" ]]; then
  LC_ALL=C.UTF-8 add-apt-repository -y universe
  LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
else
  add-apt-repository -y universe
  add-apt-repository -y ppa:ondrej/php
fi

# clang all-in-one to minimize cache reloads
PACKAGES=(acl composer curl fping git graphviz imagemagick mariadb-client \
  mariadb-server mtr-tiny nginx-full nmap cron \
  php${PHP_VER}-{cli,curl,fpm,gd,gmp,mbstring,mysql,snmp,xml,zip} \
  python3-{pip,pymysql,psutil,setuptools,systemd,venv,dotenv,redis} \
  python3-command-runner rrdtool snmp snmpd whois unzip traceroute)

apt install -y "${PACKAGES[@]}"

#enable cron for ubuntu minimal
systemctl enable cron
systemctl start cron
success "Base packages installed"

# === 👤 Create librenms user ===
banner "Creating LibreNMS User"
if id librenms &>/dev/null; then
  skip "User 'librenms' exists"
else
  useradd librenms -d /opt/librenms -M -r -s "$(which bash)"
  success "User 'librenms' created"
fi

# === 📦 Clone LibreNMS ===
banner "Cloning LibreNMS Code"
repo_dir=/opt/librenms
if [[ -d "$repo_dir" ]]; then
  skip "$repo_dir exists, skipping clone"
else
  git clone https://github.com/librenms/librenms.git "$repo_dir"
  success "Repository cloned"
fi

chown -R librenms:librenms /opt/librenms
chmod 771 /opt/librenms
setfacl -d -m g::rwx /opt/librenms/{rrd,logs,bootstrap/cache,storage} || true
setfacl -R -m g::rwx /opt/librenms/{rrd,logs,bootstrap/cache,storage} || true
success "Permissions set on /opt/librenms"

# verify html directory
if [[ ! -f /opt/librenms/html/index.php ]]; then
  error "Missing html/index.php after clone!"
  exit 1
fi

# === 💾 PHP Composer Dependencies ===
banner "Installing PHP Dependencies"
su -s /bin/bash librenms -c '/opt/librenms/scripts/composer_wrapper.php install --no-dev || true'
success "PHP dependencies installed"

# === 🛢️ MariaDB Setup ===
banner "Configuring MariaDB"
if ! mysql -uroot -e "USE librenms;" &>/dev/null; then
  mysql -uroot <<MYSQL
CREATE DATABASE librenms CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'librenms'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON librenms.* TO 'librenms'@'localhost';
FLUSH PRIVILEGES;
MYSQL
  success "Database & user created"
else
  skip "Database 'librenms' exists, skipping"
fi

# apply innodb settings
sed -i '/\[mysqld\]/a innodb_file_per_table=1' /etc/mysql/mariadb.conf.d/50-server.cnf
sed -i '/\[mysqld\]/a lower_case_table_names=0'   /etc/mysql/mariadb.conf.d/50-server.cnf
systemctl enable mariadb
systemctl daemon-reload
systemctl restart mariadb
success "MariaDB configured"

# === 🐘 PHP-FPM Pool Configuration ===
banner "Configuring PHP-FPM Pool"

# 1) Remove any stale LibreNMS socket
rm -f /run/php-fpm-librenms.sock || true

# 2) Ensure the standard PHP socket dir exists and is owned by librenms
mkdir -p /run/php
chown librenms:librenms /run/php

conf_dir="/etc/php/$PHP_VER/fpm/pool.d"
lib_conf="$conf_dir/librenms.conf"

if [[ ! -f "$lib_conf" ]]; then
  cp "$conf_dir/www.conf" "$lib_conf"
  # 3) Point to a unique socket name under /run/php/
  sed -i \
    -e 's/\[www\]/[librenms]/' \
    -e 's/user = www-data/user = librenms/' \
    -e 's/group = www-data/group = librenms/' \
    -e 's|listen = .*|listen = /run/php/php'"${PHP_VER//./}"'-fpm-librenms.sock|' \
    "$lib_conf"
  success "PHP-FPM pool created"
else
  skip "PHP-FPM pool exists"
fi

# 4) Apply timezone into PHP INI if missing
for ini in fpm/php.ini cli/php.ini; do
  file="/etc/php/$PHP_VER/$ini"
  grep -q "date.timezone = $TZ" "$file" || \
    sed -i "/;date.timezone =/a date.timezone = $TZ" "$file"
done

# 5) Enable & restart the service
systemctl enable php${PHP_VER}-fpm
systemctl daemon-reload
systemctl restart php${PHP_VER}-fpm
success "PHP-FPM restarted and running on socket: /run/php/php${PHP_VER//./}-fpm-librenms.sock"

# define the socket path for Nginx
PHP_SOCKET="/run/php/php${PHP_VER//./}-fpm-librenms.sock"

# === 🌐 NGINX Config (HTTP only - SSL via Cloudflare tunnel) ===
banner "Configuring NGINX"

cat > /etc/nginx/sites-available/librenms.conf <<EOF
server {
    listen 80;
    server_name ${LIBRENMS_DOMAIN};
    root /opt/librenms/html;
    index index.php;
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \.php\$ {
        fastcgi_pass unix:${PHP_SOCKET};
        include fastcgi.conf;
    }
    location ~ /\.ht { deny all; }
}
EOF

ln -sf /etc/nginx/sites-available/librenms.conf /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
systemctl daemon-reload
nginx -t && systemctl enable nginx && systemctl reload nginx
success "NGINX configured (HTTP on port 80)"

# === 📟 SNMP Setup ===
banner "Configuring SNMP"
cp /opt/librenms/snmpd.conf.example /etc/snmp/snmpd.conf
sed -i "s/RANDOMSTRINGGOESHERE/$SNMP_COMMUNITY/" /etc/snmp/snmpd.conf
curl -s -o /usr/bin/distro https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/distro
chmod +x /usr/bin/distro
systemctl enable --now snmpd
success "SNMP ready"

# === 🕓 CRON, LOGROTATE and Scheduler ===
banner "CRON, LOGROTATE and Scheduler"
cp /opt/librenms/dist/librenms.cron     /etc/cron.d/librenms
cp /opt/librenms/misc/librenms.logrotate /etc/logrotate.d/librenms
cp /opt/librenms/dist/librenms-scheduler.service /opt/librenms/dist/librenms-scheduler.timer /etc/systemd/system/
sudo systemctl enable librenms-scheduler.timer
systemctl daemon-reload
sudo systemctl start librenms-scheduler.timer
success "Copied cron and logrotate configs and enabled the scheduler"

# === 📝 Update .env file with DB credentials & APP_URL ===
banner "Updating .env file"
ENV_FILE=/opt/librenms/.env

# Helper function to set/update .env values
set_env() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}

# Set all database configuration
set_env "DB_CONNECTION" "mysql"
set_env "DB_HOST" "localhost"
set_env "DB_PORT" "3306"
set_env "DB_DATABASE" "librenms"
set_env "DB_USERNAME" "librenms"
set_env "DB_PASSWORD" "${DB_PASSWORD}"

# Set APP_URL (HTTP since SSL is via Cloudflare tunnel)
set_env "APP_URL" "http://${LIBRENMS_DOMAIN}"

success ".env file updated with database credentials and APP_URL"

# === 🔁 Enable & Restart Services ===
banner "Enabling & Restarting Services"
systemctl enable mariadb php${PHP_VER}-fpm nginx snmpd
systemctl daemon-reload
systemctl restart mariadb php${PHP_VER}-fpm nginx snmpd
success "All services up"

# Wait for MariaDB to be fully ready and accepting connections
echo "⏳ Waiting for MariaDB to be ready..."
for i in {1..30}; do
  if mysql -uroot -e "SELECT 1" &>/dev/null; then
    success "MariaDB is ready"
    break
  fi
  sleep 1
  if [[ $i -eq 30 ]]; then
    error "MariaDB failed to start after 30 seconds"
    exit 1
  fi
done

# === 🗄️ Run Database Migrations ===
banner "Running Database Migrations"
su -s /bin/bash librenms -c 'cd /opt/librenms && php artisan migrate --force --no-interaction'
success "Database migrations completed"

# === 🔗 Updating binary links ===
banner "🔗 Linking LibreNMS CLI (lnms)"

# Fix lnms symlink only if missing or wrong
if [[ ! -L /usr/local/bin/lnms || "$(readlink -f /usr/local/bin/lnms)" != "/opt/librenms/lnms" ]]; then
  sudo ln -sf /opt/librenms/lnms /usr/local/bin/lnms
  sudo chmod +x /opt/librenms/lnms
  echo "🔗 lnms symlink created/updated."
else
  echo "✅ lnms symlink already correct."
fi

# Always copy bash completion
sudo cp /opt/librenms/misc/lnms-completion.bash /etc/bash_completion.d/
echo "📋 Bash completion script installed."

success "Binary links updated"

# === ✅ COMPLETE ===
banner "LibreNMS Installation Complete"
echo -e "\n${GRN}✔ LibreNMS is running on HTTP at: http://${LIBRENMS_DOMAIN}/install${RST}"
echo -e "🌐 Access via Cloudflare tunnel on your separate VM${RST}"
echo -e "\n🔐 MySQL user: librenms"
echo -e "🔑 MySQL password: ${YEL}${DB_PASSWORD}${RST}"
echo -e "🛰️ SNMP Community: ${YEL}${SNMP_COMMUNITY}${RST}"
echo -e "\n🔧 Cloudflare Tunnel Setup:"
echo -e "  On your separate VM, tunnel port 80 of this host to your domain"
echo -e "  Example cloudflared config: http://${LIBRENMS_DOMAIN}:80"
echo -e "\n🚀 Then finish the web-UI setup at your tunneled URL."

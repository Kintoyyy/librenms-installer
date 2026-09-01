#!/usr/bin/env bash
# ==============================================================
# 🌐 LibreNMS Installer Script (Official Docs)
# Target: Ubuntu 24.04 / Debian 12+
# 
# Follows: https://docs.librenms.org/Installation/Install-LibreNMS/
# 
# Installs and configures LibreNMS end-to-end:
#  • Installs required packages (PHP 8.5+, MySQL, Nginx, SNMP)
#  • Creates librenms user with proper ACLs
#  • Clones official repo, installs Composer deps
#  • Configures MariaDB with proper charset/collation
#  • Sets up PHP-FPM pool with Unix socket
#  • Configures Nginx (HTTP only - SSL via Cloudflare tunnel on separate VM)
#  • Deploys SNMP, cron jobs, logrotate, scheduler
#  • Prompts for trusted proxy IPs (Cloudflare tunnel network)
# 
# Non-interactive variables (set before running):
#   LIBRENMS_DOMAIN, DB_PASSWORD, SNMP_COMMUNITY, TZ, TRUSTED_PROXIES
# ==============================================================

set -euo pipefail
IFS=$'\n\t'
trap 'echo "✖ Error at line $LINENO"; exit 1' ERR

# Ensure running as root
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
TRUSTED_PROXIES="${TRUSTED_PROXIES:-}"

# === 📥 PROMPTS ===
[[ -z "$LIBRENMS_DOMAIN" ]] && read -rp "Enter LibreNMS domain or IP: " LIBRENMS_DOMAIN
[[ -z "$DB_PASSWORD" ]] && { DB_PASSWORD=$(openssl rand -hex 16); echo -e "${YEL}Generated DB password: $DB_PASSWORD${RST}"; }
[[ -z "$SNMP_COMMUNITY" ]] && read -rp "Enter SNMP community [public]: " SNMP_COMMUNITY && SNMP_COMMUNITY=${SNMP_COMMUNITY:-public}

if [[ -z "$TZ" ]]; then
  echo -e "${CYN}Refer to timezone list: https://en.wikipedia.org/wiki/List_of_tz_database_time_zones${RST}"
  read -rp "Enter timezone (e.g. Asia/Manila): " TZ
fi

# Trusted Reverse Proxies Configuration
echo -e "\n${CYN}Trusted Reverse Proxy Configuration${RST}"
echo "This restricts which IPs can set X-Forwarded headers (security critical)"

CURRENT_IP=$(hostname -I | awk '{print $1}')
if [[ -n "$CURRENT_IP" ]]; then
  CURRENT_SUBNET=$(echo "$CURRENT_IP" | sed 's/\.[0-9]*$/.0\/24/')
  echo -e "\n${GRN}Detected this machine's IP: $CURRENT_IP${RST}"
  echo -e "${GRN}Suggested subnet: $CURRENT_SUBNET${RST}"
else
  CURRENT_SUBNET="127.0.0.1"
fi

echo "Options:"
echo "  1. Localhost only (most secure): 127.0.0.1"
echo "  2. Current subnet (Cloudflare tunnel on same network): $CURRENT_SUBNET"
echo "  3. Specific IP (Cloudflare tunnel on different network): 192.168.1.50"
echo "  4. Cloudflare IP range: 172.67.169.0/24"
echo "  WARNING: Do NOT use '*' or '**' in production"
read -rp "Enter trusted proxy IPs/CIDR (leave blank for $CURRENT_SUBNET): " TRUSTED_PROXIES_INPUT
if [[ -n "$TRUSTED_PROXIES_INPUT" ]]; then
  TRUSTED_PROXIES="$TRUSTED_PROXIES_INPUT"
  echo -e "${GRN}Trusted proxies set to: $TRUSTED_PROXIES${RST}"
else
  TRUSTED_PROXIES="$CURRENT_SUBNET"
  echo -e "${GRN}Using current subnet: $TRUSTED_PROXIES${RST}"
fi

# === 🚨 Nuke Existing Installation ===
if [[ -d /opt/librenms ]] || mysql -uroot -e "USE librenms;" &>/dev/null; then
  echo -e "\n${YEL}Existing LibreNMS detected!${RST}"
  read -rp "Proceed to nuke and start fresh? [y/N]: " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborting."
    exit 1
  fi

  echo "⏳ Removing old installation..."
  systemctl stop nginx php-fpm mariadb snmpd 2>/dev/null || true
  rm -rf /opt/librenms /etc/nginx/conf.d/librenms.conf /etc/php-fpm.d/librenms.conf
  mysql -uroot <<SQL
DROP DATABASE IF EXISTS librenms;
DROP USER IF EXISTS 'librenms'@'localhost';
FLUSH PRIVILEGES;
SQL
  success "Previous installation removed."
fi

# === 🧱 INSTALL PACKAGES ===
banner "Installing Required Packages"
export DEBIAN_FRONTEND=noninteractive

apt update -y && apt full-upgrade -y

# Install Debian Sury PHP repo (for PHP 8.5+)
apt install -y lsb-release ca-certificates curl
curl -sSLo /tmp/debsuryorg-archive-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb
dpkg -i /tmp/debsuryorg-archive-keyring.deb
echo "deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list
apt update -y

# Install all required packages
apt install -y acl curl fping git mariadb-client mariadb-server mtr-tiny nginx-full nmap php8.5-cli php8.5-curl php8.5-fpm php8.5-gd php8.5-gmp php8.5-mbstring php8.5-mysql php8.5-snmp php8.5-xml php8.5-zip python3-dotenv python3-pip python3-psutil python3-pymysql python3-redis python3-setuptools python3-systemd rrdtool snmp snmpd traceroute unzip whois

success "Packages installed"

# === 👤 CREATE LIBRENMS USER ===
banner "Creating librenms User"
if id librenms &>/dev/null; then
  skip "User librenms exists"
else
  useradd librenms -d /opt/librenms -M -r -s "$(which bash)"
  success "User librenms created"
fi

# === 📦 CLONE REPO ===
banner "Cloning LibreNMS Repository"
cd /opt
git clone https://github.com/librenms/librenms.git
success "Repository cloned"

# === 🔐 SET PERMISSIONS ===
banner "Setting Permissions"
chown -R librenms:librenms /opt/librenms
chmod 771 /opt/librenms
setfacl -d -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/
setfacl -R -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/
success "Permissions set"

# === 💾 INSTALL COMPOSER DEPS ===
banner "Installing PHP Dependencies"
su - librenms -s /bin/bash -c '/opt/librenms/scripts/composer_wrapper.php install --no-dev'
success "PHP dependencies installed"

# === 🌍 SET TIMEZONE ===
banner "Setting Timezone"
timedatectl set-timezone "$TZ"
sed -i "s|^;date.timezone =|date.timezone = $TZ|" /etc/php/8.5/fpm/php.ini
sed -i "s|^;date.timezone =|date.timezone = $TZ|" /etc/php/8.5/cli/php.ini
success "Timezone set to $TZ"

# === 🛢️ CONFIGURE MARIADB ===
banner "Configuring MariaDB"
sed -i '/\[mysqld\]/a innodb_file_per_table=1\nlower_case_table_names=0' /etc/mysql/mariadb.conf.d/50-server.cnf
systemctl enable mariadb
systemctl restart mariadb
sleep 2

mysql -uroot <<MYSQL
CREATE DATABASE librenms CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'librenms'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON librenms.* TO 'librenms'@'localhost';
FLUSH PRIVILEGES;
MYSQL
success "MariaDB configured"

# === 🐘 CONFIGURE PHP-FPM ===
banner "Configuring PHP-FPM"
cp /etc/php/8.5/fpm/pool.d/www.conf /etc/php/8.5/fpm/pool.d/librenms.conf

sed -i \
  -e 's/\[www\]/[librenms]/' \
  -e 's/user = www-data/user = librenms/' \
  -e 's/group = www-data/group = librenms/' \
  -e 's|listen = .*|listen = /run/php-fpm-librenms.sock|' \
  /etc/php/8.5/fpm/pool.d/librenms.conf

systemctl enable php8.5-fpm
systemctl restart php8.5-fpm
success "PHP-FPM configured"

# === 🌐 CONFIGURE NGINX ===
banner "Configuring NGINX"

cat > /etc/nginx/conf.d/librenms.conf <<'NGINX_EOF'
server {
 listen      80;
 server_name LIBRENMS_DOMAIN;
 root        /opt/librenms/html;
 index       index.php;

 charset utf-8;
 gzip on;
 gzip_types text/css application/javascript text/javascript application/x-javascript image/svg+xml text/plain text/xsd text/xsl text/xml image/x-icon;
 
 # Cloudflare tunnel headers (HTTPS termination on separate VM)
 real_ip_header CF-Connecting-IP;
 set_real_ip_from 0.0.0.0/0;
 
 # Security headers
 add_header Referrer-Policy "same-origin" always;
 add_header X-Content-Type-Options "nosniff" always;
 add_header X-Frame-Options "SAMEORIGIN" always;
 
 location / {
  try_files $uri $uri/ /index.php?$query_string;
 }
 location ~ [^/]\.php(/|$) {
  fastcgi_pass unix:/run/php-fpm-librenms.sock;
  fastcgi_split_path_info ^(.+\.php)(/.+)$;
  include fastcgi.conf;
  
  # Tell PHP it's HTTPS (from Cloudflare tunnel)
  fastcgi_param HTTPS on;
  fastcgi_param SERVER_PORT 443;
  fastcgi_param HTTP_X_FORWARDED_PROTO https;
  fastcgi_param HTTP_X_FORWARDED_FOR $proxy_add_x_forwarded_for;
  fastcgi_param HTTP_X_FORWARDED_HOST $host;
 }
 location ~ /\.(?!well-known).* {
  deny all;
 }
}
NGINX_EOF

sed -i "s|LIBRENMS_DOMAIN|$LIBRENMS_DOMAIN|g" /etc/nginx/conf.d/librenms.conf

rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default
systemctl enable nginx
systemctl restart nginx
success "NGINX configured"

# === 📟 CONFIGURE SNMP ===
banner "Configuring SNMP"
cp /opt/librenms/snmpd.conf.example /etc/snmp/snmpd.conf
sed -i "s/RANDOMSTRINGGOESHERE/$SNMP_COMMUNITY/" /etc/snmp/snmpd.conf
curl -s -o /usr/bin/distro https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/distro
chmod +x /usr/bin/distro
systemctl enable snmpd
systemctl restart snmpd
success "SNMP configured"

# === 🕐 CRON, LOGROTATE, SCHEDULER ===
banner "Configuring Cron, Logrotate & Scheduler"
cp /opt/librenms/dist/librenms.cron /etc/cron.d/librenms
cp /opt/librenms/misc/librenms.logrotate /etc/logrotate.d/librenms
cp /opt/librenms/dist/librenms-scheduler.{service,timer} /etc/systemd/system/
systemctl enable librenms-scheduler.timer
systemctl daemon-reload
systemctl start librenms-scheduler.timer
success "Cron, logrotate & scheduler configured"

# === 🔗 ENABLE LNMS COMMAND ===
banner "Enabling lnms Command"
ln -sf /opt/librenms/lnms /usr/bin/lnms
cp /opt/librenms/misc/lnms-completion.bash /etc/bash_completion.d/
success "lnms command enabled"

# === 📝 CREATE .ENV FILE ===
banner "Creating .env File"
cat > /opt/librenms/.env <<ENV_EOF
APP_KEY=base64:$(openssl rand -base64 32)
APP_URL=https://${LIBRENMS_DOMAIN}
APP_DEBUG=false
APP_TRUSTED_PROXIES=${TRUSTED_PROXIES}
DB_CONNECTION=mysql
DB_HOST=localhost
DB_PORT=3306
DB_DATABASE=librenms
DB_USERNAME=librenms
DB_PASSWORD=${DB_PASSWORD}
ENV_EOF

chown librenms:librenms /opt/librenms/.env
chmod 600 /opt/librenms/.env
success ".env file created"

# === 🗄️ RUN DATABASE MIGRATIONS ===
banner "Running Database Migrations"
echo "⏳ Waiting for MariaDB to be ready..."
for i in {1..30}; do
  if mysql -uroot -e "SELECT 1" &>/dev/null; then
    success "MariaDB is ready"
    break
  fi
  sleep 1
  if [[ $i -eq 30 ]]; then
    error "MariaDB failed to start"
    exit 1
  fi
done

# Clear cache first
rm -rf /opt/librenms/bootstrap/cache/* /opt/librenms/storage/framework/cache/* /opt/librenms/storage/framework/views/*
chown -R librenms:librenms /opt/librenms/bootstrap /opt/librenms/storage

su - librenms -s /bin/bash -c 'cd /opt/librenms && php artisan migrate --force --no-interaction'
success "Database migrations completed"

# === ✅ COMPLETE ===
banner "LibreNMS Installation Complete"
echo -e "\n${GRN}✔ LibreNMS is ready for web installer${RST}"
echo -e "\n📍 Access the web installer at:"
echo -e "   ${GRN}https://${LIBRENMS_DOMAIN}/install${RST}"
echo -e "\n🔐 Database Credentials:"
echo -e "   User: librenms"
echo -e "   Password: ${YEL}${DB_PASSWORD}${RST}"
echo -e "\n🛰️  SNMP Community: ${YEL}${SNMP_COMMUNITY}${RST}"
echo -e "\n🔒 Trusted Proxies: ${YEL}${TRUSTED_PROXIES}${RST}"
echo -e "\n🌐 Cloudflare Tunnel Setup:"
echo -e "   On your separate VM, tunnel to:"
echo -e "   ${CYN}http://${LIBRENMS_DOMAIN}:80${RST}"
echo -e "\n📋 Next Steps:"
echo -e "   1. Access https://${LIBRENMS_DOMAIN}/install"
echo -e "   2. Create admin user and finish setup (DB already migrated)"
echo -e "   3. Add your first device"
echo -e "\n📚 Documentation:"
echo -e "   https://docs.librenms.org/Installation/Install-LibreNMS/"

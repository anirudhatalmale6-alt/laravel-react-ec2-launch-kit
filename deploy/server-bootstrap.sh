#!/usr/bin/env bash
#
# Brings a bare Ubuntu 24.04 EC2 instance up to the point where OctoError can
# be deployed onto it. Run once, as root, on the instance.
#
#   sudo ./server-bootstrap.sh
#
# Installs nginx, PHP 8.3-FPM with pdo_pgsql, Composer, Node 22, PostgreSQL 17
# and certbot; creates the two database roles the project's own init.sql
# defines; and installs the systemd units for the queue worker, the scheduler
# and Reverb.
#
# It does NOT request a certificate and does NOT deploy. Certbot needs the
# domain's DNS to point here first, and the deploy needs the .env filled in.
# Both are separate steps on purpose, so this script can be re-run safely.
#
# Idempotent: every step checks before acting.

set -Eeuo pipefail

PG_VERSION=17
PHP_VERSION=8.3
NODE_MAJOR=22
APP_BASE=/var/www/app
DB_NAME=octo_error
DB_MIGRATOR=octo_migrator
DB_RUNTIME=octo_runtime
CRED_FILE=/root/octoerror-db-credentials.txt

say()  { printf '\n\e[1m==>\e[0m %s\n' "$*"; }
skip() { printf '    already done: %s\n' "$*"; }
die()  { printf '\e[31mFAILED:\e[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run this with sudo"
. /etc/os-release
[[ ${VERSION_ID:-} == "24.04" ]] || say "WARNING: expected Ubuntu 24.04, found ${VERSION_ID:-unknown}; continuing"

export DEBIAN_FRONTEND=noninteractive

say "base packages"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg lsb-release unzip git acl ufw >/dev/null

# ------------------------------------------------------------- PostgreSQL 17
# Ubuntu 24.04 ships PostgreSQL 16. The project's compose file pins 17, and a
# dump taken from 17 will not restore into 16, so take 17 from PGDG rather
# than silently running a different major version in production than in dev.
if [[ ! -f /etc/apt/sources.list.d/pgdg.list ]]; then
  say "adding the PostgreSQL apt repository"
  install -d /usr/share/postgresql-common/pgdg
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list
  apt-get update -qq
else
  skip "pgdg repository"
fi
apt-get install -y -qq "postgresql-$PG_VERSION" "postgresql-client-$PG_VERSION" >/dev/null
systemctl enable --now "postgresql@$PG_VERSION-main" 2>/dev/null || systemctl enable --now postgresql

# ------------------------------------------------------------------- PHP 8.3
# 24.04 ships 8.3 in main, so no PPA is needed. pdo_pgsql is the one people
# forget; without it Laravel boots and then fails on the first query.
say "PHP $PHP_VERSION and extensions"
apt-get install -y -qq \
  "php$PHP_VERSION-fpm" "php$PHP_VERSION-cli" "php$PHP_VERSION-pgsql" \
  "php$PHP_VERSION-mbstring" "php$PHP_VERSION-xml" "php$PHP_VERSION-curl" \
  "php$PHP_VERSION-intl" "php$PHP_VERSION-bcmath" "php$PHP_VERSION-zip" \
  "php$PHP_VERSION-gd" "php$PHP_VERSION-redis" >/dev/null
php -m | grep -q '^pdo_pgsql$' || die "pdo_pgsql did not install; Laravel cannot reach Postgres without it"

# opcache settings that matter on a small box
cat > "/etc/php/$PHP_VERSION/fpm/conf.d/99-octoerror.ini" <<'INI'
; Laravel caches config and routes at deploy time, so a generous opcache is
; free performance. validate_timestamps=0 means a deploy MUST reload php-fpm,
; which deploy.sh does.
opcache.enable=1
opcache.memory_consumption=192
opcache.max_accelerated_files=20000
opcache.validate_timestamps=0
opcache.interned_strings_buffer=16
memory_limit=512M
upload_max_filesize=32M
post_max_size=34M
expose_php=Off
INI

say "Composer"
if ! command -v composer >/dev/null; then
  curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
  php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
  rm -f /tmp/composer-setup.php
else
  skip "composer $(composer --version 2>/dev/null | head -1)"
fi

# -------------------------------------------------------------------- Node
say "Node $NODE_MAJOR"
if ! node -v 2>/dev/null | grep -q "^v$NODE_MAJOR"; then
  curl -fsSL "https://deb.nodesource.com/setup_$NODE_MAJOR.x" | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
else
  skip "node $(node -v)"
fi
# The project requires >=22.12; a bare "22" from nodesource satisfies that,
# but check rather than assume.
node -e 'const [maj,min]=process.versions.node.split(".").map(Number); if(maj<22||(maj===22&&min<12)) { console.error("node >=22.12 required, got "+process.versions.node); process.exit(1) }'

say "nginx and certbot"
apt-get install -y -qq nginx certbot python3-certbot-nginx >/dev/null

# ------------------------------------------------------------------ database
# Mirrors infra/docker/init.sql: octo_migrator owns the schema and is the only
# role that can change it; octo_runtime, which the app uses day to day, gets
# DML only and cannot issue DDL. Worth keeping in production, not just dev.
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_MIGRATOR'" | grep -q 1; then
  skip "database roles"
else
  say "creating database, roles and the app schema"
  MIG_PW=$(openssl rand -base64 30 | tr -d '/+=' | head -c 32)
  RUN_PW=$(openssl rand -base64 30 | tr -d '/+=' | head -c 32)
  sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
CREATE ROLE $DB_MIGRATOR LOGIN PASSWORD '$MIG_PW' NOSUPERUSER NOCREATEDB NOCREATEROLE;
CREATE ROLE $DB_RUNTIME  LOGIN PASSWORD '$RUN_PW' NOSUPERUSER NOCREATEDB NOCREATEROLE;
CREATE DATABASE $DB_NAME OWNER $DB_MIGRATOR;
SQL
  sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$DB_NAME" <<SQL
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
CREATE SCHEMA app AUTHORIZATION $DB_MIGRATOR;
REVOKE ALL ON SCHEMA app FROM PUBLIC;
GRANT USAGE ON SCHEMA app TO $DB_RUNTIME;
GRANT CONNECT ON DATABASE $DB_NAME TO $DB_RUNTIME;
ALTER DEFAULT PRIVILEGES FOR ROLE $DB_MIGRATOR IN SCHEMA app
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO $DB_RUNTIME;
ALTER DEFAULT PRIVILEGES FOR ROLE $DB_MIGRATOR IN SCHEMA app
  GRANT USAGE, SELECT ON SEQUENCES TO $DB_RUNTIME;
SQL
  umask 077
  cat > "$CRED_FILE" <<EOF
# OctoError production database, generated $(date -u +%FT%TZ)
# These are NOT the local_* development passwords. Put them in the app .env.
DB_CONNECTION=pgsql
DB_HOST=127.0.0.1
DB_PORT=5432
DB_DATABASE=$DB_NAME
DB_SCHEMA=app
DB_USERNAME=$DB_RUNTIME
DB_PASSWORD=$RUN_PW
MIGRATION_DB_USERNAME=$DB_MIGRATOR
MIGRATION_DB_PASSWORD=$MIG_PW
EOF
  chmod 600 "$CRED_FILE"
  say "database passwords written to $CRED_FILE (root only)"
fi

# Postgres listens on localhost only. Nothing outside the box should reach it,
# and the security group does not open 5432 either.
PG_CONF="/etc/postgresql/$PG_VERSION/main/postgresql.conf"
if [[ -f $PG_CONF ]]; then
  sed -i "s/^#*listen_addresses.*/listen_addresses = 'localhost'/" "$PG_CONF"
  systemctl reload "postgresql@$PG_VERSION-main" 2>/dev/null || systemctl reload postgresql
fi

# ----------------------------------------------------------------- layout
say "directories"
mkdir -p "$APP_BASE"/{repo,releases,shared/backend/storage,shared/backend/storage/app,shared/backend/storage/framework/{cache,sessions,views},shared/backend/storage/logs}
mkdir -p /var/www/letsencrypt/.well-known/acme-challenge /var/log/app
chown -R www-data:www-data "$APP_BASE" /var/log/app
# 755 not 750: at 750 nginx cannot read the acme challenge and certbot gets a
# 404 from its own probe, which reads like a DNS problem and is not.
chmod -R 755 /var/www/letsencrypt

say "systemd units"
install -m 644 "$(dirname "$0")"/systemd/*.service "$(dirname "$0")"/systemd/*.timer /etc/systemd/system/ 2>/dev/null || true
systemctl daemon-reload

say "firewall"
ufw allow OpenSSH >/dev/null
ufw allow 'Nginx Full' >/dev/null
ufw --force enable >/dev/null
# Reverb (8080) and Postgres (5432) are deliberately absent: both are reached
# over loopback only, Reverb through the nginx wss proxy.

say "unattended security updates"
apt-get install -y -qq unattended-upgrades >/dev/null
dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true

cat <<EOF

  done. versions on this box:
    $(nginx -v 2>&1)
    $(php -v | head -1)
    $(psql --version)
    node $(node -v), npm $(npm -v)
    $(composer --version 2>/dev/null | head -1)

  next, in order:
    1. put the real .env at $APP_BASE/shared/backend/.env
       (database values are in $CRED_FILE)
    2. point the domain's A records at this box and WAIT for propagation
    3. install the nginx vhost, then:
       certbot certonly --webroot -w /var/www/letsencrypt -d DOMAIN -d www.DOMAIN
    4. certbot renew --dry-run    <- do this now, not in 60 days
    5. deploy.sh

  Reverb and the queue worker are installed but NOT started: they need the
  .env and a deployed release first.
EOF

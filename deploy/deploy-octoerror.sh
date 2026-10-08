#!/usr/bin/env bash
#
# Release-based deploy for OctoError: Laravel backend/ + React frontend/ +
# a Reverb websocket server, all on one EC2 instance.
#
#   sudo ./deploy-octoerror.sh                 # deploy origin/main
#   sudo ./deploy-octoerror.sh v1.2.0          # deploy a tag or sha
#   sudo ./deploy-octoerror.sh --rollback      # previous release, one symlink
#
# Builds into a NEW directory and only moves the live symlink once the build
# has been proved to boot, so a failed deploy leaves the running site exactly
# as it was.
#
#   /var/www/app/repo                 fetch-only clone
#   /var/www/app/releases/<ts>/       backend/ and frontend/ for one release
#   /var/www/app/current  ->          releases/<ts>
#   /var/www/app/shared/backend/.env  never in git, symlinked into each release

set -Eeuo pipefail

BASE=/var/www/app
REPO=$BASE/repo
SHARED=$BASE/shared
RELEASES=$BASE/releases
CURRENT=$BASE/current
KEEP=5
PHP_FPM=php8.3-fpm
BRANCH=${DEPLOY_BRANCH:-main}
HEALTH_PATH=/api/v1/ready

log() { printf '\e[1m==>\e[0m %s\n' "$*"; }
die() { printf '\e[31mFAILED:\e[0m %s\n' "$*" >&2; exit 1; }
trap 'die "aborted at line $LINENO"' ERR

restart_services() {
  systemctl reload "$PHP_FPM"
  # Queue workers and Reverb hold the OLD code in memory until restarted, so
  # a deploy that skips this keeps serving the previous release over the
  # websocket while the HTTP side has already moved on.
  php "$CURRENT/backend/artisan" queue:restart >/dev/null 2>&1 || true
  systemctl restart app-queue.service
  systemctl restart app-reverb.service
}

if [[ ${1:-} == --rollback ]]; then
  prev=$(ls -1dt "$RELEASES"/*/ 2>/dev/null | sed -n 2p || true)
  [[ -n $prev ]] || die "there is no previous release to roll back to"
  log "rolling back to $(basename "$prev")"
  ln -sfn "${prev%/}" "$CURRENT.tmp" && mv -Tf "$CURRENT.tmp" "$CURRENT"
  php "$CURRENT/backend/artisan" optimize:clear >/dev/null
  restart_services
  log "rolled back; nginx needs no change"
  exit 0
fi

REF=${1:-origin/$BRANCH}
TS=$(date +%Y%m%d%H%M%S)
NEW=$RELEASES/$TS

[[ -f $SHARED/backend/.env ]] || die "$SHARED/backend/.env is missing"

# A space anywhere around an '=' makes dotenv discard the ENTIRE file, so the
# app boots with no configuration rather than one bad value.
if grep -nE '^[A-Za-z_][A-Za-z0-9_]*[[:space:]]+=|^[A-Za-z_][A-Za-z0-9_]*=[[:space:]]' "$SHARED/backend/.env"; then
  die "the lines above have a space around '='; dotenv will discard the whole .env"
fi

# Refuse to ship a debug build. APP_DEBUG=true prints the environment,
# including the Stripe keys, into the browser on any 500.
if grep -qiE '^APP_DEBUG=(true|1)$' "$SHARED/backend/.env"; then
  die "APP_DEBUG is true in the production .env; a 500 would print your Stripe keys to the browser"
fi
if ! grep -qiE '^APP_ENV=production$' "$SHARED/backend/.env"; then
  die "APP_ENV is not production in $SHARED/backend/.env"
fi
# The provisional no-money path from the roadmap. Harmless locally, but in
# production it lets a bug be contracted without the funds existing.
if grep -qiE '^OCTO_ALLOW_UNFUNDED_DEVELOPMENT=(true|1)$' "$SHARED/backend/.env"; then
  die "OCTO_ALLOW_UNFUNDED_DEVELOPMENT is true; clients could contract work that is not funded"
fi
# Two endpoints, two signing secrets. Identical values mean one of the two
# webhook controllers rejects every event Stripe ever sends it.
w1=$(grep -E '^STRIPE_WEBHOOK_SECRET=' "$SHARED/backend/.env" | cut -d= -f2- || true)
w2=$(grep -E '^STRIPE_CONNECT_WEBHOOK_SECRET=' "$SHARED/backend/.env" | cut -d= -f2- || true)
if [[ -n $w1 && $w1 == "$w2" ]]; then
  die "STRIPE_WEBHOOK_SECRET and STRIPE_CONNECT_WEBHOOK_SECRET are identical; one endpoint will 400 every event"
fi

log "fetching $REF"
git -C "$REPO" fetch --all --tags --prune
git -C "$REPO" rev-parse --verify "$REF" >/dev/null || die "unknown ref: $REF"
SHA=$(git -C "$REPO" rev-parse --short "$REF")

log "release $TS ($SHA)"
mkdir -p "$NEW"
git -C "$REPO" archive "$REF" | tar -x -C "$NEW"

# ------------------------------------------------------------------ backend
log "composer install"
cd "$NEW/backend"
composer install --no-dev --prefer-dist --no-interaction --no-progress --optimize-autoloader

ln -sfn "$SHARED/backend/.env" "$NEW/backend/.env"
rm -rf "$NEW/backend/storage"
ln -sfn "$SHARED/backend/storage" "$NEW/backend/storage"
chown -R www-data:www-data "$NEW" "$SHARED/backend/storage"
chmod -R ug+rwX "$SHARED/backend/storage" "$NEW/backend/bootstrap/cache"

# Boot the whole container BEFORE anything is restarted or the symlink moves.
# A missing extension, a bad .env value or a broken provider surfaces here
# rather than as a 500 on every request after a reload.
log "boot check"
sudo -u www-data php artisan about --only=environment >/dev/null \
  || die "the new release does not boot; the live site has not been touched"

# Migrations run as the migrator role, which is the only one with DDL rights.
log "migrations"
sudo -u www-data php artisan migrate --force --no-interaction --database=pgsql_migrate

log "caching config, routes, views, events"
sudo -u www-data php artisan config:cache
sudo -u www-data php artisan route:cache
sudo -u www-data php artisan view:cache
sudo -u www-data php artisan event:cache

# ----------------------------------------------------------------- frontend
# npm ci installs devDependencies deliberately: vite, tsc and the plugins all
# live there, and pruning before the build yields a broken bundle without
# failing loudly.
log "npm ci"
cd "$NEW/frontend"
npm ci --no-audit --no-fund

log "vite build"
npm run build
[[ -f $NEW/frontend/dist/index.html ]] || die "the react build produced no index.html"
find "$NEW/frontend/dist/assets" -name '*.js' -size +1k | grep -q . \
  || die "the react build emitted no javascript bundle"
rm -rf "$NEW/frontend/node_modules"
chown -R www-data:www-data "$NEW/frontend/dist"

log "switching the symlink"
ln -sfn "$NEW" "$CURRENT.tmp" && mv -Tf "$CURRENT.tmp" "$CURRENT"

log "reloading php-fpm, queue worker and reverb"
restart_services

log "smoke test"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -k "https://localhost$HEALTH_PATH" -H 'Host: '"${DEPLOY_DOMAIN:-localhost}" || echo 0)
if [[ $code != 200 ]]; then
  printf 'health endpoint returned %s; rolling back\n' "$code" >&2
  "$0" --rollback
  die "deploy rolled back automatically"
fi

log "pruning old releases (keeping $KEEP)"
ls -1dt "$RELEASES"/*/ | tail -n +$((KEEP + 1)) | xargs -r rm -rf

log "deployed $SHA as $TS"

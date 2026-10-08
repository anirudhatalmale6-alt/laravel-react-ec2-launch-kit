#!/usr/bin/env bash
#
# Release-based deploy for the Laravel API + React SPA on one EC2 box.
#
#   sudo -u www-data /var/www/app/deploy.sh            # deploy origin/main
#   sudo -u www-data /var/www/app/deploy.sh v1.4.2     # deploy a tag
#   sudo -u www-data /var/www/app/deploy.sh --rollback  # back to the previous release
#
# Builds into a NEW directory and only moves the symlink once the build has
# been proved to boot. Nothing is overwritten in place, so a failed build
# leaves the running site exactly as it was, and a rollback is one symlink.
#
# Layout:
#   /var/www/app/repo            bare-ish working clone (fetch only)
#   /var/www/app/releases/<ts>/  api/ and web/ for one release
#   /var/www/app/current  ->     releases/<ts>        (nginx points here)
#   /var/www/app/shared/api/.env                      (never in git)
#   /var/www/app/shared/api/storage                   (uploads, logs, sessions)

set -Eeuo pipefail

BASE=/var/www/app
REPO=$BASE/repo
SHARED=$BASE/shared
RELEASES=$BASE/releases
CURRENT=$BASE/current
KEEP=5
PHP_FPM_SERVICE=php8.3-fpm
BRANCH=${DEPLOY_BRANCH:-main}

log()  { printf '\e[1m==>\e[0m %s\n' "$*"; }
die()  { printf '\e[31mFAILED:\e[0m %s\n' "$*" >&2; exit 1; }
trap 'die "aborted at line $LINENO"' ERR

# --------------------------------------------------------------- rollback
if [[ ${1:-} == --rollback ]]; then
  prev=$(ls -1dt "$RELEASES"/*/ 2>/dev/null | sed -n 2p || true)
  [[ -n $prev ]] || die "there is no previous release to roll back to"
  log "rolling back to $(basename "$prev")"
  ln -sfn "${prev%/}" "$CURRENT.tmp" && mv -Tf "$CURRENT.tmp" "$CURRENT"
  php "$CURRENT/api/artisan" optimize:clear >/dev/null
  systemctl reload "$PHP_FPM_SERVICE"
  systemctl restart app-queue.service
  log "rolled back. nginx needs no change."
  exit 0
fi

REF=${1:-origin/$BRANCH}
TS=$(date +%Y%m%d%H%M%S)
NEW=$RELEASES/$TS

# ------------------------------------------------------- preconditions
[[ -f $SHARED/api/.env ]] || die "$SHARED/api/.env is missing; nothing to deploy with"
[[ -d $SHARED/api/storage ]] || die "$SHARED/api/storage is missing"

# A space anywhere around an `=` makes dotenv reject the WHOLE file, so the
# app boots with no config at all rather than with one bad value. Cheap to
# catch here; miserable to diagnose at 2am.
if grep -nE '^[A-Za-z_][A-Za-z0-9_]*[[:space:]]+=|^[A-Za-z_][A-Za-z0-9_]*=[[:space:]]' "$SHARED/api/.env"; then
  die "the lines above have a space around '=' — dotenv will discard the entire .env"
fi

log "fetching $REF"
git -C "$REPO" fetch --all --tags --prune
git -C "$REPO" rev-parse --verify "$REF" >/dev/null || die "unknown ref: $REF"
SHA=$(git -C "$REPO" rev-parse --short "$REF")

log "creating release $TS ($SHA)"
mkdir -p "$NEW"
git -C "$REPO" archive "$REF" | tar -x -C "$NEW"

# ----------------------------------------------------------------- api
log "composer install"
cd "$NEW/api"
composer install --no-dev --prefer-dist --no-interaction --no-progress --optimize-autoloader

ln -sfn "$SHARED/api/.env" "$NEW/api/.env"
rm -rf "$NEW/api/storage"
ln -sfn "$SHARED/api/storage" "$NEW/api/storage"
chmod -R ug+rwX "$SHARED/api/storage" "$NEW/api/bootstrap/cache"

# Boot the application BEFORE anything is restarted or the symlink moves.
# `artisan about` loads the whole container, every service provider and the
# config, so a missing extension, a bad .env value or a syntax error in a
# provider shows up here rather than as a 500 on every page after a reload.
log "boot check"
php artisan about --only=environment >/dev/null \
  || die "the new release does not boot; the live site has not been touched"

log "migrations"
php artisan migrate --force --no-interaction

log "caching config, routes, views, events"
php artisan config:cache
php artisan route:cache
php artisan view:cache
php artisan event:cache

# ----------------------------------------------------------------- web
# npm ci installs devDependencies on purpose. Vite, the TS compiler and the
# plugins all live in devDependencies, and pruning them before the build
# leaves a half-populated cache that produces a broken bundle without
# failing loudly. Prune AFTER the build, or not at all.
log "npm ci"
cd "$NEW/web"
npm ci --no-audit --no-fund

log "vite build"
npm run build
[[ -f $NEW/web/dist/index.html ]] || die "the react build produced no index.html"
# Count the hashed entry chunks: a build that silently emitted nothing still
# writes index.html, and the result is a blank white page.
if ! find "$NEW/web/dist/assets" -name '*.js' -size +1k | grep -q .; then
  die "the react build emitted no javascript bundle"
fi
rm -rf "$NEW/web/node_modules"

# -------------------------------------------------------------- go live
log "switching the symlink"
ln -sfn "$NEW" "$CURRENT.tmp" && mv -Tf "$CURRENT.tmp" "$CURRENT"

log "reloading php-fpm and the queue worker"
systemctl reload "$PHP_FPM_SERVICE"
# Queue workers hold the OLD code in memory until they are restarted, so a
# deploy that skips this keeps processing jobs with the previous release.
php "$CURRENT/api/artisan" queue:restart >/dev/null
systemctl restart app-queue.service

log "post-deploy smoke test"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 https://localhost/up -k || echo 0)
[[ $code == 200 ]] || {
  printf 'health endpoint returned %s; rolling back\n' "$code" >&2
  "$0" --rollback
  die "deploy rolled back automatically"
}

log "pruning old releases (keeping $KEEP)"
ls -1dt "$RELEASES"/*/ | tail -n +$((KEEP + 1)) | xargs -r rm -rf

log "deployed $SHA as $TS"

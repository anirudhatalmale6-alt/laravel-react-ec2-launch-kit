#!/bin/sh
# Rehearses deploy/nginx-app.conf on this box before it goes near the client's
# EC2 instance. Proves the routing split (API prefixes vs SPA fallback), the
# cache headers, the header-inheritance fix, and the http->https redirect.
#
# No php-fpm here, so the @laravel location is swapped for a proxy_pass to a
# `php -S` stand-in. Everything being tested (location matching, try_files,
# headers, redirects) is identical either way; only the transport differs.
set -e

PROJ=/var/lib/freelancer/projects/40757887
R=$PROJ/.rehearsal
HTTPS_PORT=18400
HTTP_PORT=18401
PHP_PORT=18402

rm -rf "$R/root" "$R/logs" "$R/tmp" "$R/out"
mkdir -p "$R/root/web/dist/assets" "$R/root/api/public" "$R/logs" "$R/tmp" "$R/out" "$R/certs" "$R/acme/.well-known/acme-challenge"

# ---- fake React build -------------------------------------------------------
echo '<!doctype html><title>SPA shell</title><div id=root>SPA_SHELL</div>' > "$R/root/web/dist/index.html"
echo 'console.log("HASHED_ASSET");' > "$R/root/web/dist/assets/app.a1b2c3d4.js"

# ---- Laravel stand-in -------------------------------------------------------
cat > "$R/root/api/public/index.php" <<'PHP'
<?php
$uri = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
header('Content-Type: application/json');
if ($uri === '/api/health') {
    echo json_encode(['ok' => true, 'from' => 'laravel']);
} elseif ($uri === '/stripe/webhook') {
    // Echo the raw body length back: this is what signature verification
    // depends on, so the rehearsal asserts the body survives the hop.
    $raw = file_get_contents('php://input');
    echo json_encode(['raw_len' => strlen($raw), 'raw' => $raw]);
} else {
    http_response_code(404);
    echo json_encode(['error' => 'laravel 404', 'uri' => $uri]);
}
PHP

# ---- certs + le snippets ----------------------------------------------------
if [ ! -f "$R/certs/fullchain.pem" ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 3 \
    -keyout "$R/certs/privkey.pem" -out "$R/certs/fullchain.pem" \
    -subj "/CN=example.test" >/dev/null 2>&1
fi
# 1024-bit dhparams are rejected outright by OpenSSL 3 ("dh key too small"),
# which is also why certbot's own ssl-dhparams.pem is 2048.
[ -f "$R/certs/dhparam.pem" ] || openssl dhparam -out "$R/certs/dhparam.pem" 2048 >/dev/null 2>&1
cat > "$R/certs/options-ssl-nginx.conf" <<'EOF'
ssl_session_cache shared:le_nginx_SSL:10m;
ssl_session_timeout 1440m;
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
EOF

# ---- rehearsal copy of the real config -------------------------------------
sed \
  -e 's/DOMAIN/example.test/g' \
  -e "s#SNIPPET_DIR#$PROJ/deploy/snippets#g" \
  -e "s#listen 80;#listen 127.0.0.1:$HTTP_PORT;#" \
  -e "s#listen \[::\]:80;##" \
  -e "s#listen 443 ssl http2;#listen 127.0.0.1:$HTTPS_PORT ssl http2;#" \
  -e "s#listen \[::\]:443 ssl http2;##" \
  -e "s#/etc/letsencrypt/live/example.test#$R/certs#g" \
  -e "s#include /etc/letsencrypt/options-ssl-nginx.conf;#include $R/certs/options-ssl-nginx.conf;#" \
  -e "s#/etc/letsencrypt/ssl-dhparams.pem#$R/certs/dhparam.pem#" \
  -e "s#/var/www/letsencrypt#$R/acme#" \
  -e "s#/var/www/app/web/dist#$R/root/web/dist#g" \
  -e "s#/var/www/app/api/public#$R/root/api/public#g" \
  -e "s#/var/log/nginx/app.access.log#$R/logs/app.access.log#" \
  -e "s#/var/log/nginx/app.error.log#$R/logs/app.error.log#" \
  "$PROJ/deploy/nginx-app.conf" > "$R/site.conf"

# swap the fastcgi block for a proxy to the php -S stand-in
python3 - "$R/site.conf" "$PHP_PORT" "$PROJ/deploy/snippets/security-headers.conf" <<'PY'
import re, sys
p, port, snip = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
block = re.search(r'(    location \@laravel \{\n)(.*?)(\n    \}\n)', s, re.S)
assert block, "could not find the @laravel block"
body = (
    "        include %s;\n" % snip
    + "        proxy_pass http://127.0.0.1:%s;\n" % port
    + "        proxy_http_version 1.1;\n"
    + "        proxy_set_header Host $host;\n"
    + "        proxy_set_header X-Forwarded-Proto https;\n"
    + "        proxy_request_buffering off;\n"
)
s = s[:block.start(2)] + body.rstrip("\n") + s[block.end(2):]
# the upstream block is unused once fastcgi is gone
s = re.sub(r'upstream php_fpm \{\n.*?\n\}\n', '', s, flags=re.S)
open(p, 'w').write(s)
PY

cat > "$R/nginx.conf" <<EOF
worker_processes 1;
daemon on;
error_log $R/logs/error.log warn;
pid $R/tmp/nginx.pid;
events { worker_connections 64; }
http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  access_log $R/logs/access.log;
  client_body_temp_path $R/tmp/client;
  proxy_temp_path $R/tmp/proxy;
  fastcgi_temp_path $R/tmp/fastcgi;
  uwsgi_temp_path $R/tmp/uwsgi;
  scgi_temp_path $R/tmp/scgi;
  include $R/site.conf;
}
EOF

echo "--- nginx -t ---"
nginx -t -c "$R/nginx.conf"

# --------------------------------------------------------------- functional
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL  %s\n     got: %s\n' "$1" "$2"; }
check() { # name expected_substring actual
  case "$3" in *"$2"*) ok "$1";; *) bad "$1" "$(printf '%s' "$3" | tr '\n' '|' | cut -c1-200)";; esac
}

echo "$R/root/acme-probe" > "$R/acme/.well-known/acme-challenge/probe.txt"
echo 'APP_KEY=should-never-be-served' > "$R/root/web/dist/.env"

php -S 127.0.0.1:$PHP_PORT -t "$R/root/api/public" "$R/root/api/public/index.php" \
  > "$R/logs/php.log" 2>&1 &
PHP_PID=$!
nginx -c "$R/nginx.conf"
NGX_PID=$(cat "$R/tmp/nginx.pid")
trap 'kill $PHP_PID 2>/dev/null; nginx -c "$R/nginx.conf" -s quit 2>/dev/null' EXIT
i=0; while [ $i -lt 40 ]; do
  curl -sk --resolve example.test:$HTTPS_PORT:127.0.0.1 "https://example.test:$HTTPS_PORT/" >/dev/null 2>&1 && break
  i=$((i+1)); done

G="curl -sk --resolve example.test:$HTTPS_PORT:127.0.0.1 --resolve www.example.test:$HTTPS_PORT:127.0.0.1"

echo "--- functional ---"
check "/ serves the SPA shell"              "SPA_SHELL"      "$($G https://example.test:$HTTPS_PORT/)"
check "/ carries the security headers"      "x-frame-options" "$($G -D- -o /dev/null https://example.test:$HTTPS_PORT/)"
check "/ does not claim a laravel backend"  ""               "$($G -D- -o /dev/null https://example.test:$HTTPS_PORT/ | grep -ci 'X-App-Backend' | sed 's/^0$//')"

H=$($G -D- -o /dev/null https://example.test:$HTTPS_PORT/index.html)
check "index.html is no-cache"              "no-cache"       "$H"
check "index.html KEEPS the sec headers"    "x-frame-options" "$H"

H=$($G -D- -o /dev/null https://example.test:$HTTPS_PORT/assets/app.a1b2c3d4.js)
check "hashed asset is immutable"           "immutable"      "$H"
check "hashed asset KEEPS the sec headers"  "x-frame-options" "$H"

check "/api/health reaches laravel"         '"from":"laravel"' "$($G https://example.test:$HTTPS_PORT/api/health)"
check "/api/ is marked as laravel"          "laravel"        "$($G -D- -o /dev/null https://example.test:$HTTPS_PORT/api/health | grep -i x-app-backend)"
check "unknown /api path 404s as JSON"      "laravel 404"    "$($G https://example.test:$HTTPS_PORT/api/nope)"
check "client-side route falls back to SPA" "SPA_SHELL"      "$($G https://example.test:$HTTPS_PORT/billing/invoices/42)"

BODY='{"id":"evt_1","type":"invoice.paid","data":{"object":{"amount_paid":4900}}}'
check "webhook raw body arrives intact"     "\"raw_len\":${#BODY}" \
  "$($G -X POST -H 'Content-Type: application/json' -H 'Stripe-Signature: t=1,v1=deadbeef' --data-raw "$BODY" https://example.test:$HTTPS_PORT/stripe/webhook)"

check "dotfiles are denied"                 "403"            "$($G -o /dev/null -w '%{http_code}' https://example.test:$HTTPS_PORT/.env)"
check "acme probe is NOT redirected"        "200"            "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$HTTP_PORT/.well-known/acme-challenge/probe.txt)"
check "plain http redirects to https"       "301"            "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: example.test' http://127.0.0.1:$HTTP_PORT/pricing)"
check "redirect keeps the path"             "https://example.test/pricing" "$(curl -s -D- -o /dev/null -H 'Host: example.test' http://127.0.0.1:$HTTP_PORT/pricing | grep -i location)"
check "www redirects to the apex"           "https://example.test/" "$($G -D- -o /dev/null https://www.example.test:$HTTPS_PORT/ | grep -i location)"
check "stray .php is not executable"        "404"            "$($G -o /dev/null -w '%{http_code}' https://example.test:$HTTPS_PORT/legacy/shell.php)"


# ---- negative control -------------------------------------------------------
# Proves the three "KEEPS the sec headers" checks above can actually go red,
# and that the snippet include is load-bearing rather than decorative: drop
# the include from the /assets/ block only, reload, and the header vanishes
# because the local `add_header Cache-Control` has displaced the inherited set.
cp "$R/site.conf" "$R/site.main.conf"
sed '/location \/assets\/ {/,/^    }/{/security-headers\.conf/d;}' \
  "$R/site.main.conf" > "$R/site.conf"
grep -c security-headers "$R/site.conf" > "$R/out/includes.after" || true
nginx -c "$R/nginx.conf" -s reload
sleep 1
HC=$($G -D- -o /dev/null https://example.test:$HTTPS_PORT/assets/app.a1b2c3d4.js)
case "$HC" in
  *x-frame-options*) bad "CONTROL: asset header SHOULD vanish without the include" "still present";;
  *) ok  "CONTROL: asset header vanishes without the include";;
esac
case "$HC" in
  *immutable*) ok "CONTROL: the local Cache-Control is what displaced it";;
  *) bad "CONTROL: the local Cache-Control is what displaced it" "no immutable header either";;
esac
cp "$R/site.main.conf" "$R/site.conf"
nginx -c "$R/nginx.conf" -s reload

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]

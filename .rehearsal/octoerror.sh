#!/bin/sh
# Rehearses deploy/nginx-octoerror.conf before it goes near the client's EC2
# box. Proves the three-way split (Reverb websockets / Laravel API / SPA
# fallback), that the websocket Upgrade header survives the proxy, that a
# plain HTTP call to Reverb's broadcast API does NOT get an upgrade header,
# and that the Stripe webhook body arrives byte-identical.
#
# No php-fpm here, so @laravel is swapped for a proxy_pass to `php -S`.
# Reverb is stood in for by a tiny python server that reports back what
# headers it actually received.
set -e

PROJ=/var/lib/freelancer/projects/40757887
R=$PROJ/.rehearsal/octo
HTTPS_PORT=18420
HTTP_PORT=18421
PHP_PORT=18422
WS_PORT=18423

rm -rf "$R"
mkdir -p "$R/root/frontend/dist/assets" "$R/root/backend/public" "$R/logs" "$R/tmp" "$R/acme/.well-known/acme-challenge" "$R/certs"

echo '<!doctype html><title>Octo</title><div id=root>SPA_SHELL</div>' > "$R/root/frontend/dist/index.html"
echo 'console.log("HASHED");' > "$R/root/frontend/dist/assets/index-abc12345.js"
echo 'APP_KEY=must-never-be-served' > "$R/root/frontend/dist/.env"

cat > "$R/root/backend/public/index.php" <<'PHP'
<?php
$uri = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
header('Content-Type: application/json');
if ($uri === '/api/v1/ready') {
    echo json_encode(['data' => ['ready' => true, 'from' => 'laravel']]);
} elseif ($uri === '/api/v1/webhooks/stripe' || $uri === '/api/v1/webhooks/stripe-connect') {
    $raw = file_get_contents('php://input');
    echo json_encode(['endpoint' => $uri, 'raw_len' => strlen($raw), 'sha' => sha1($raw)]);
} elseif ($uri === '/sanctum/csrf-cookie') {
    http_response_code(204);
} else {
    http_response_code(404);
    echo json_encode(['error' => ['code' => 'NOT_FOUND'], 'uri' => $uri]);
}
PHP

# Reverb stand-in: echoes back the headers nginx forwarded, so the test can
# assert on Upgrade/Connection rather than trusting the config by eye.
cat > "$R/reverb_stub.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def _reply(self):
        body = json.dumps({
            'path': self.path,
            'upgrade': self.headers.get('Upgrade', ''),
            'connection': self.headers.get('Connection', ''),
            'xfproto': self.headers.get('X-Forwarded-Proto', ''),
            'host': self.headers.get('Host', ''),
        }).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        self._reply()
    def do_POST(self):
        self._reply()
    def log_message(self, *a):
        pass

HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PY

openssl req -x509 -newkey rsa:2048 -nodes -days 3 \
  -keyout "$R/certs/privkey.pem" -out "$R/certs/fullchain.pem" \
  -subj "/CN=octo.test" >/dev/null 2>&1
openssl dhparam -out "$R/certs/dhparam.pem" 2048 >/dev/null 2>&1
printf 'ssl_protocols TLSv1.2 TLSv1.3;\nssl_prefer_server_ciphers off;\n' > "$R/certs/options-ssl-nginx.conf"

sed \
  -e 's/DOMAIN/octo.test/g' \
  -e "s#SNIPPET_DIR#$PROJ/deploy/snippets#g" \
  -e "s#listen 80;#listen 127.0.0.1:$HTTP_PORT;#" \
  -e "s#listen \[::\]:80;##" \
  -e "s#listen 443 ssl http2;#listen 127.0.0.1:$HTTPS_PORT ssl http2;#" \
  -e "s#listen \[::\]:443 ssl http2;##" \
  -e "s#/etc/letsencrypt/live/octo.test#$R/certs#g" \
  -e "s#include /etc/letsencrypt/options-ssl-nginx.conf;#include $R/certs/options-ssl-nginx.conf;#" \
  -e "s#/etc/letsencrypt/ssl-dhparams.pem#$R/certs/dhparam.pem#" \
  -e "s#/var/www/letsencrypt#$R/acme#" \
  -e "s#server 127.0.0.1:8080;#server 127.0.0.1:$WS_PORT;#" \
  -e "s#/var/www/app/current/frontend/dist#$R/root/frontend/dist#g" \
  -e "s#/var/www/app/current/backend/public#$R/root/backend/public#g" \
  -e "s#/var/log/nginx/octoerror.access.log#$R/logs/access.log#" \
  -e "s#/var/log/nginx/octoerror.error.log#$R/logs/error.log#" \
  "$PROJ/deploy/nginx-octoerror.conf" > "$R/site.conf"

python3 - "$R/site.conf" "$PHP_PORT" "$PROJ/deploy/snippets/security-headers.conf" <<'PY'
import re, sys
p, port, snip = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
m = re.search(r'(    location \@laravel \{\n)(.*?)(\n    \}\n)', s, re.S)
assert m, 'could not find the @laravel block'
body = (
    "        include %s;\n" % snip
    + "        proxy_pass http://127.0.0.1:%s;\n" % port
    + "        proxy_http_version 1.1;\n"
    + "        proxy_set_header Host $host;\n"
    + "        proxy_set_header X-Forwarded-Proto https;\n"
    + "        proxy_request_buffering off;\n"
)
s = s[:m.start(2)] + body.rstrip('\n') + s[m.end(2):]
s = re.sub(r'upstream php_fpm \{\n.*?\n\}\n', '', s, flags=re.S)
open(p, 'w').write(s)
PY

cat > "$R/nginx.conf" <<EOF
worker_processes 1;
daemon on;
error_log $R/logs/nginx-error.log warn;
pid $R/tmp/nginx.pid;
events { worker_connections 64; }
http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  access_log off;
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

php -S 127.0.0.1:$PHP_PORT -t "$R/root/backend/public" "$R/root/backend/public/index.php" > "$R/logs/php.log" 2>&1 &
PHP_PID=$!
python3 "$R/reverb_stub.py" $WS_PORT > "$R/logs/ws.log" 2>&1 &
WS_PID=$!
nginx -c "$R/nginx.conf"
trap 'kill $PHP_PID $WS_PID 2>/dev/null; nginx -c "$R/nginx.conf" -s quit 2>/dev/null' EXIT

i=0; while [ $i -lt 40 ]; do
  curl -sk --resolve octo.test:$HTTPS_PORT:127.0.0.1 "https://octo.test:$HTTPS_PORT/" >/dev/null 2>&1 && break
  i=$((i+1)); done

G="curl -sk --resolve octo.test:$HTTPS_PORT:127.0.0.1 --resolve www.octo.test:$HTTPS_PORT:127.0.0.1"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n     got: %s\n' "$1" "$(printf '%s' "$2" | tr '\n' '|' | cut -c1-200)"; }
# Responses are compared with spaces stripped, so a JSON encoder that
# writes `"path": "/x"` still matches an expectation of `"path":"/x"`.
squash() { printf '%s' "$1" | tr -d ' \t'; }
chk() { case "$(squash "$3")" in *"$(squash "$2")"*) ok "$1";; *) bad "$1" "$3";; esac; }
no()  { case "$(squash "$3")" in *"$(squash "$2")"*) bad "$1" "$3";; *) ok "$1";; esac; }

echo "--- functional ---"
chk "/ serves the SPA"                     "SPA_SHELL"        "$($G https://octo.test:$HTTPS_PORT/)"
chk "/wallet falls back to the SPA"        "SPA_SHELL"        "$($G https://octo.test:$HTTPS_PORT/wallet)"
chk "/messages/42 falls back to the SPA"   "SPA_SHELL"        "$($G https://octo.test:$HTTPS_PORT/messages/42)"
chk "api/v1/ready reaches laravel"         '"from":"laravel"' "$($G https://octo.test:$HTTPS_PORT/api/v1/ready)"
chk "sanctum csrf-cookie reaches laravel"  "204"              "$($G -o /dev/null -w '%{http_code}' https://octo.test:$HTTPS_PORT/sanctum/csrf-cookie)"
chk "an unknown /api path 404s as JSON"    "NOT_FOUND"        "$($G https://octo.test:$HTTPS_PORT/api/v1/nope)"
no  "an unknown /api path is NOT the SPA"  "SPA_SHELL"        "$($G https://octo.test:$HTTPS_PORT/api/v1/nope)"

B1='{"id":"evt_1","type":"payment_intent.succeeded"}'
SHA=$(printf '%s' "$B1" | sha1sum | cut -d' ' -f1)
chk "stripe webhook body is byte-identical" "\"sha\":\"$SHA\"" \
  "$($G -X POST -H 'Content-Type: application/json' --data-raw "$B1" https://octo.test:$HTTPS_PORT/api/v1/webhooks/stripe)"
chk "the CONNECT webhook is its own endpoint" '"endpoint":"\/api\/v1\/webhooks\/stripe-connect"' \
  "$($G -X POST -H 'Content-Type: application/json' --data-raw "$B1" https://octo.test:$HTTPS_PORT/api/v1/webhooks/stripe-connect)"

# --http1.1 is required: HTTP/2 forbids connection-specific headers, so
# curl drops Upgrade/Connection over h2 and the proxy looks broken when it
# is not. Browsers open websockets over HTTP/1.1 for the same reason.
WS=$($G --http1.1 -H 'Upgrade: websocket' -H 'Connection: Upgrade' "https://octo.test:$HTTPS_PORT/app/ed981024dff")
chk "websocket reaches reverb"              '"path":"/app/ed981024dff"' "$WS"
chk "the Upgrade header survives the proxy" '"upgrade":"websocket"'     "$WS"
chk "Connection is set to upgrade"          '"connection":"upgrade"'    "$WS"

EV=$($G -X POST "https://octo.test:$HTTPS_PORT/apps/octo-local/events")
chk "reverb broadcast API is reachable"     '"path":"/apps/octo-local/events"' "$EV"
# The map must NOT force an upgrade on a plain HTTP call, or the broadcast
# API breaks. This is the half that a hardcoded `Connection upgrade` loses.
chk "a plain call to reverb is NOT upgraded" '"connection":"close"'     "$EV"

chk "dotfiles denied"                       "403" "$($G -o /dev/null -w '%{http_code}' https://octo.test:$HTTPS_PORT/.env)"
chk "hashed asset immutable"                "immutable" "$($G -D- -o /dev/null https://octo.test:$HTTPS_PORT/assets/index-abc12345.js)"
chk "hashed asset keeps sec headers"        "x-frame-options" "$($G -D- -o /dev/null https://octo.test:$HTTPS_PORT/assets/index-abc12345.js)"
chk "acme probe not redirected"             "404" "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$HTTP_PORT/.well-known/acme-challenge/none)"
chk "http redirects to https"               "301" "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: octo.test' http://127.0.0.1:$HTTP_PORT/bugs)"
chk "www redirects to apex"                 "https://octo.test/" "$($G -D- -o /dev/null https://www.octo.test:$HTTPS_PORT/ | grep -i location)"
chk "stray .php is inert"                   "404" "$($G -o /dev/null -w '%{http_code}' https://octo.test:$HTTPS_PORT/legacy/x.php)"

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]

#!/bin/sh
# Proves stripe-preflight.php's section-4 diagnosis actually distinguishes the
# five ways a Laravel webhook route goes wrong, instead of just printing
# something plausible. Each case is a stub route returning one status code;
# the assertion is on the DIAGNOSIS line, not on the status code.
set -e

PROJ=/var/lib/freelancer/projects/40757887
R=$PROJ/.rehearsal
PORT=18410
ENVF=$R/out/stub.env

mkdir -p "$R/out"
cat > "$ENVF" <<'EOF'
STRIPE_KEY=pk_test_stub
STRIPE_SECRET=not-a-real-key
STRIPE_WEBHOOK_SECRET=whsec_stubsecret
EOF

cat > "$R/out/stub.php" <<'PHP'
<?php
// Behaviour is driven by a file so the server does not need restarting.
$mode = trim(@file_get_contents(__DIR__ . '/stub.mode') ?: 'verify');
$uri  = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);

if ($uri === '/') { echo 'home'; exit; }

switch ($mode) {
    case 'accepts_unsigned':         // no verification at all
        http_response_code(200); echo 'ok'; break;
    case 'csrf':                     // route left inside the CSRF middleware
        http_response_code(419); echo 'page expired'; break;
    case 'auth_redirect':            // auth middleware in front of it
        header('Location: /login', true, 302); break;
    case 'missing':                  // not deployed
        http_response_code(404); echo 'not found'; break;
    case 'handler_explodes':         // verification fine, handler throws
        http_response_code(500); echo 'Server Error'; break;
    case 'wrong_secret':             // signature never matches
        http_response_code(400); echo 'invalid signature'; break;
    case 'verify':                   // correct behaviour
    default:
        $sig  = $_SERVER['HTTP_STRIPE_SIGNATURE'] ?? '';
        $raw  = file_get_contents('php://input');
        $sec  = 'whsec_stubsecret';
        if (!preg_match('/t=(\d+),v1=([a-f0-9]+)/', $sig, $m)) {
            http_response_code(400); echo 'no signature'; break;
        }
        $want = hash_hmac('sha256', $m[1] . '.' . $raw, $sec);
        if (!hash_equals($want, $m[2])) {
            http_response_code(400); echo 'bad signature'; break;
        }
        http_response_code(200); echo 'handled';
}
PHP

php -S 127.0.0.1:$PORT -t "$R/out" "$R/out/stub.php" > "$R/out/stub.log" 2>&1 &
STUB=$!
trap 'kill $STUB 2>/dev/null' EXIT
i=0; while [ $i -lt 40 ]; do
  curl -s "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break
  i=$((i+1)); done

PASS=0; FAIL=0
run() { # mode expected_phrase label
  echo "$1" > "$R/out/stub.mode"
  O=$(php "$PROJ/deploy/stripe-preflight.php" --env="$ENVF" \
        --url="http://127.0.0.1:$PORT" --webhook-path=/stripe/webhook 2>&1 || true)
  case "$O" in
    *"$2"*) PASS=$((PASS+1)); printf 'PASS  %s\n' "$3";;
    *)      FAIL=$((FAIL+1)); printf 'FAIL  %s\n     looked for: %s\n' "$3" "$2"
            printf '%s\n' "$O" | sed 's/^/     | /';;
  esac
}

run accepts_unsigned "an UNSIGNED webhook was accepted with 200" "names an unverified route as forgeable"
run csrf           "CSRF protection is still on for this path" "names CSRF on a 419"
run auth_redirect    "auth or a redirect is in front of it"      "names auth middleware on a 302"
run missing          "it is not deployed, or nginx is answering" "names a missing route on a 404"
run handler_explodes "Stripe will retry for days"                "names retry storms on a 500"
run wrong_secret     "does not match the one the"                "names a stale cached secret on a signed 400"
run verify           "signature config matches"                  "passes a correctly configured route"

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]

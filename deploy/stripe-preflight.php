<?php
/**
 * Stripe go-live preflight.
 *
 * Run this BEFORE flipping the switch, and again right after. It is read-only
 * against Stripe: it lists, it never creates, charges or deletes anything.
 *
 *   php stripe-preflight.php --env=/var/www/app/api/.env \
 *                            --frontend-env=/var/www/app/web/.env.production \
 *                            --url=https://DOMAIN
 *
 *   php stripe-preflight.php --self-test     (no network, no keys needed)
 *
 * What it checks, in the order things actually go wrong:
 *
 *  1. Key MODE agreement. A half-flipped switch is the single most common
 *     launch failure: secret key live, publishable key still test, or the
 *     other way round. Stripe's error for that is vague, so check it here.
 *  2. The webhook signing secret. It is a DIFFERENT value in live mode. Keep
 *     the test one and every delivered event fails signature verification,
 *     the app records nothing, and the checkout still looks fine to the buyer.
 *  3. The live-mode webhook endpoint really exists, is enabled, points at
 *     this domain over https, and subscribes to the events the app handles.
 *  4. The deployed webhook route answers an UNSIGNED post with 400, not 200,
 *     not 419 (CSRF is still on), not 302 (auth middleware is still on) and
 *     not 404 (the route is not deployed). A 200 here means the app accepts
 *     forged events.
 *  5. The route is reachable over https from the public internet at all.
 *
 * Nothing here completes a payment. A real charge on a live key is yours to
 * run once, with a real card, and refund.
 */

declare(strict_types=1);

const EXPECTED_EVENTS = [
    // Adjust to whatever the app's webhook handler actually switches on.
    'checkout.session.completed',
    'customer.subscription.created',
    'customer.subscription.updated',
    'customer.subscription.deleted',
    'invoice.paid',
    'invoice.payment_failed',
    'payment_intent.succeeded',
    'payment_intent.payment_failed',
];

/* ------------------------------------------------------------------ helpers */

function out(string $status, string $msg, string $detail = ''): void
{
    $tag = match ($status) {
        'ok'   => '  OK  ',
        'warn' => ' WARN ',
        'fail' => ' FAIL ',
        default => '  --  ',
    };
    fwrite(STDOUT, "[$tag] $msg\n");
    if ($detail !== '') {
        foreach (explode("\n", rtrim($detail)) as $line) {
            fwrite(STDOUT, "         $line\n");
        }
    }
}

/**
 * Reads a .env without booting the framework.
 *
 * Deliberately tolerant of quoting, inline comments and CRLF, because a
 * hand-edited production .env has all three. One thing it does NOT do is
 * tolerate a space around the `=`: dotenv rejects the whole file for that,
 * so it is reported rather than silently parsed.
 */
function read_env(string $path): array
{
    if (!is_readable($path)) {
        throw new RuntimeException("cannot read $path");
    }
    $vars = [];
    $bad  = [];
    foreach (file($path, FILE_IGNORE_NEW_LINES) as $n => $raw) {
        $line = trim($raw, " \t\r");
        if ($line === '' || str_starts_with($line, '#')) {
            continue;
        }
        if (!str_contains($line, '=')) {
            continue;
        }
        [$k, $v] = explode('=', $line, 2);
        if ($k !== rtrim($k) || str_starts_with($v, ' ')) {
            $bad[] = sprintf('line %d: space around "=" in %s', $n + 1, trim($k));
        }
        $k = trim($k);
        $v = trim($v);
        if (strlen($v) > 1 && (
            ($v[0] === '"' && str_ends_with($v, '"')) ||
            ($v[0] === "'" && str_ends_with($v, "'"))
        )) {
            $v = substr($v, 1, -1);
        } elseif (str_contains($v, ' #')) {
            $v = rtrim(substr($v, 0, strpos($v, ' #')));
        }
        $vars[$k] = $v;
    }
    $vars['__parse_warnings'] = $bad;

    return $vars;
}

/** test | live | unknown, from the key prefix itself rather than a guess. */
function key_mode(?string $key): string
{
    if ($key === null || $key === '') {
        return 'missing';
    }
    if (preg_match('/^(sk|pk|rk)_live_/', $key)) {
        return 'live';
    }
    if (preg_match('/^(sk|pk|rk)_test_/', $key)) {
        return 'test';
    }

    return 'unknown';
}

function mask(?string $v): string
{
    if ($v === null || $v === '') {
        return '(empty)';
    }

    return strlen($v) <= 12 ? substr($v, 0, 4) . '...' : substr($v, 0, 11) . '...' . substr($v, -4);
}

/** GET against the Stripe API. Read-only by construction: no method switch. */
function stripe_get(string $secret, string $path, array $query = []): array
{
    $url = 'https://api.stripe.com/v1/' . ltrim($path, '/');
    if ($query !== []) {
        $url .= '?' . http_build_query($query);
    }
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_HTTPHEADER     => ['Authorization: Bearer ' . $secret],
        CURLOPT_TIMEOUT        => 20,
    ]);
    $body = curl_exec($ch);
    $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $err  = curl_error($ch);
    curl_close($ch);
    if ($body === false) {
        throw new RuntimeException("curl: $err");
    }

    return [$code, json_decode($body, true) ?? []];
}

/**
 * Builds a Stripe-Signature header exactly the way Stripe does:
 * HMAC-SHA256 over "<timestamp>.<raw body>" keyed with the whsec, hex.
 * Used to prove the deployed route accepts a correct signature and rejects
 * a wrong one, without asking Stripe to send anything.
 */
function stripe_signature(string $payload, string $secret, int $timestamp): string
{
    $sig = hash_hmac('sha256', $timestamp . '.' . $payload, $secret);

    return "t=$timestamp,v1=$sig";
}

function http_probe(string $url, string $method = 'GET', string $body = '', array $headers = []): array
{
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_CUSTOMREQUEST  => $method,
        CURLOPT_HEADER         => true,
        CURLOPT_FOLLOWLOCATION => false,
        CURLOPT_TIMEOUT        => 20,
        CURLOPT_HTTPHEADER     => $headers,
    ]);
    if ($body !== '') {
        curl_setopt($ch, CURLOPT_POSTFIELDS, $body);
    }
    $resp = curl_exec($ch);
    $code = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $hlen = (int) curl_getinfo($ch, CURLINFO_HEADER_SIZE);
    $err  = curl_error($ch);
    curl_close($ch);
    if ($resp === false) {
        return [0, '', '', $err];
    }

    return [$code, substr($resp, 0, $hlen), substr($resp, $hlen), ''];
}

/* ---------------------------------------------------------------- self test */

function self_test(): int
{
    $fails = 0;
    $assert = function (string $name, $expected, $actual) use (&$fails): void {
        if ($expected === $actual) {
            out('ok', $name);
        } else {
            $fails++;
            out('fail', $name, 'expected: ' . var_export($expected, true)
                . "\nactual:   " . var_export($actual, true));
        }
    };

    // Signature scheme, against a FIXED vector computed outside PHP (python
    // hmac over "1700000000.<payload>" with the secret below). Comparing the
    // function to the same hash_hmac() call it uses internally would pass even
    // if the scheme were wrong, so the expected digest is pinned as a literal.
    $payload = '{"id":"evt_test","type":"invoice.paid"}';
    $secret  = 'whsec_selftestsecret';
    $ts      = 1700000000;
    $assert(
        'signature matches an independently computed vector',
        't=1700000000,v1=4f09372240f011629579dce41a95d80389d794da1344ac284873abaf4e789bae',
        stripe_signature($payload, $secret, $ts)
    );
    $assert(
        'a different body yields a different signature',
        true,
        stripe_signature($payload, $secret, $ts) !== stripe_signature($payload . ' ', $secret, $ts)
    );
    $assert(
        'a different secret yields a different signature',
        true,
        stripe_signature($payload, $secret, $ts) !== stripe_signature($payload, $secret . 'x', $ts)
    );

    // Key mode detection.
    $assert('sk_live_ is live', 'live', key_mode('sk_live_51Habc'));
    $assert('pk_live_ is live', 'live', key_mode('pk_live_51Habc'));
    $assert('rk_live_ is live', 'live', key_mode('rk_live_51Habc'));
    $assert('sk_test_ is test', 'test', key_mode('sk_test_51Habc'));
    $assert('empty is missing',  'missing', key_mode(''));
    $assert('null is missing',   'missing', key_mode(null));
    $assert('a webhook secret is not a key mode', 'unknown', key_mode('whsec_abc'));
    $assert('a pasted placeholder is not live', 'unknown', key_mode('your-stripe-key-here'));

    // Env parsing, including the traps.
    $tmp = tempnam(sys_get_temp_dir(), 'env');
    file_put_contents($tmp, implode("\n", [
        '# comment line',
        'STRIPE_KEY="pk_test_quoted"',
        "STRIPE_SECRET='sk_test_single'",
        'STRIPE_WEBHOOK_SECRET=whsec_plain # trailing comment',
        'APP_URL=https://example.test',
        'BAD_SPACED = value',
        'NO_EQUALS_SIGN',
        '',
    ]) . "\n");
    $env = read_env($tmp);
    unlink($tmp);
    $assert('double quotes stripped', 'pk_test_quoted', $env['STRIPE_KEY'] ?? null);
    $assert('single quotes stripped', 'sk_test_single', $env['STRIPE_SECRET'] ?? null);
    $assert('inline comment stripped', 'whsec_plain', $env['STRIPE_WEBHOOK_SECRET'] ?? null);
    $assert('plain value kept', 'https://example.test', $env['APP_URL'] ?? null);
    $assert('a space around "=" is reported', 1, count($env['__parse_warnings']));
    $assert('a line with no "=" is skipped', false, array_key_exists('NO_EQUALS_SIGN', $env));

    out($fails === 0 ? 'ok' : 'fail', sprintf('self-test: %d failed', $fails));

    return $fails === 0 ? 0 : 1;
}

/* --------------------------------------------------------------------- main */

$opts = getopt('', ['env:', 'frontend-env:', 'url:', 'webhook-path::', 'self-test']);

if (isset($opts['self-test'])) {
    exit(self_test());
}

if (!isset($opts['env'])) {
    fwrite(STDERR, "usage: php stripe-preflight.php --env=PATH [--frontend-env=PATH] [--url=https://DOMAIN] [--webhook-path=/stripe/webhook]\n");
    fwrite(STDERR, "       php stripe-preflight.php --self-test\n");
    exit(2);
}

$webhookPath = $opts['webhook-path'] ?? '/stripe/webhook';
$problems = 0;

echo "\n== 1. keys ==\n";
$env = read_env($opts['env']);
foreach ($env['__parse_warnings'] as $w) {
    $problems++;
    out('fail', 'dotenv will reject this file', $w . "\n(a space around \"=\" voids the WHOLE .env, not just that line)");
}

$secret = $env['STRIPE_SECRET'] ?? $env['STRIPE_API_KEY'] ?? null;
$pub    = $env['STRIPE_KEY'] ?? $env['STRIPE_PUBLISHABLE_KEY'] ?? null;
$whsec  = $env['STRIPE_WEBHOOK_SECRET'] ?? null;

out('info', 'secret key      ' . mask($secret) . '  -> ' . key_mode($secret));
out('info', 'publishable key ' . mask($pub) . '  -> ' . key_mode($pub));
out('info', 'webhook secret  ' . mask($whsec));

if (key_mode($secret) !== key_mode($pub)) {
    $problems++;
    out('fail', 'the secret and publishable keys are in DIFFERENT modes', 'this is the classic half-flipped switch');
} elseif (key_mode($secret) === 'live') {
    out('ok', 'both backend keys are in live mode');
} else {
    out('warn', 'backend keys are still in ' . key_mode($secret) . ' mode');
}

if ($whsec === null || $whsec === '') {
    $problems++;
    out('fail', 'STRIPE_WEBHOOK_SECRET is not set', 'every delivered event will fail signature verification');
} elseif (!str_starts_with($whsec, 'whsec_')) {
    $problems++;
    out('fail', 'STRIPE_WEBHOOK_SECRET does not look like a signing secret');
}

if (isset($opts['frontend-env'])) {
    $fe = read_env($opts['frontend-env']);
    $fePub = null;
    foreach ($fe as $k => $v) {
        if (is_string($k) && preg_match('/STRIPE.*(KEY|PUBLISHABLE)/i', $k)) {
            $fePub = $v;
            break;
        }
    }
    out('info', 'frontend key    ' . mask($fePub) . '  -> ' . key_mode($fePub));
    if ($fePub !== null && $fePub !== $pub) {
        $problems++;
        out('fail', 'the React build uses a different publishable key than the API',
            'the browser will create intents against one account/mode and the server will look for them in another');
    } elseif ($fePub !== null) {
        out('ok', 'the React build and the API agree on the publishable key');
    }
}

// A missing or placeholder key only rules out the two sections that talk to
// Stripe. The route probes below still work, and are the ones worth running
// first anyway: they need no credentials at all.
$canCallStripe = !in_array(key_mode($secret), ['missing', 'unknown'], true);
if (!$canCallStripe) {
    out('warn', 'no usable secret key, skipping the two Stripe API sections');
}

if ($canCallStripe) {
echo "\n== 2. account ==\n";
try {
    [$code, $acct] = stripe_get($secret, 'account');
    if ($code !== 200) {
        $problems++;
        out('fail', "GET /v1/account returned $code", json_encode($acct['error'] ?? $acct));
    } else {
        out('ok', 'key authenticates as ' . ($acct['id'] ?? '?')
            . ' (' . ($acct['business_profile']['name'] ?? $acct['settings']['dashboard']['display_name'] ?? 'unnamed') . ')');
        out('info', 'default currency: ' . strtoupper((string) ($acct['default_currency'] ?? '?')));
        if (($acct['charges_enabled'] ?? false) !== true) {
            $problems++;
            out('fail', 'charges_enabled is false on this account', 'live payments will be declined until onboarding is complete');
        } else {
            out('ok', 'charges_enabled is true');
        }
        if (($acct['payouts_enabled'] ?? false) !== true) {
            out('warn', 'payouts_enabled is false', 'money can be taken but not paid out yet');
        }
    }
} catch (Throwable $e) {
    $problems++;
    out('fail', 'could not reach the Stripe API', $e->getMessage());
}

echo "\n== 3. webhook endpoints registered at Stripe ==\n";
$expectedUrl = isset($opts['url']) ? rtrim($opts['url'], '/') . $webhookPath : null;
try {
    [$code, $list] = stripe_get($secret, 'webhook_endpoints', ['limit' => 100]);
    if ($code !== 200) {
        $problems++;
        out('fail', "GET /v1/webhook_endpoints returned $code", json_encode($list['error'] ?? $list));
    } else {
        $endpoints = $list['data'] ?? [];
        if ($endpoints === []) {
            $problems++;
            out('fail', 'no webhook endpoint is registered in this mode',
                'the app will never hear about a payment that completes on Stripe-hosted pages');
        }
        $matched = null;
        foreach ($endpoints as $ep) {
            $flag = ($ep['status'] ?? '') === 'enabled' ? 'enabled' : strtoupper((string) ($ep['status'] ?? '?'));
            out('info', sprintf('%s  [%s]  %d event(s)', $ep['url'] ?? '?', $flag, count($ep['enabled_events'] ?? [])));
            if ($expectedUrl !== null && ($ep['url'] ?? '') === $expectedUrl) {
                $matched = $ep;
            }
        }
        if ($expectedUrl !== null) {
            if ($matched === null) {
                $problems++;
                out('fail', "no endpoint points at $expectedUrl",
                    'a live-mode endpoint has to be created separately from the test-mode one');
            } else {
                out('ok', "an endpoint points at $expectedUrl");
                if (($matched['status'] ?? '') !== 'enabled') {
                    $problems++;
                    out('fail', 'that endpoint is not enabled');
                }
                if (!str_starts_with((string) ($matched['url'] ?? ''), 'https://')) {
                    $problems++;
                    out('fail', 'that endpoint is not https');
                }
                $enabled = $matched['enabled_events'] ?? [];
                if (in_array('*', $enabled, true)) {
                    out('warn', 'the endpoint subscribes to every event',
                        'works, but the app will be woken for a lot of noise');
                } else {
                    $missing = array_values(array_diff(EXPECTED_EVENTS, $enabled));
                    if ($missing !== []) {
                        $problems++;
                        out('fail', 'the endpoint does not subscribe to events the app handles',
                            implode("\n", $missing));
                    } else {
                        out('ok', 'every expected event is subscribed');
                    }
                }
            }
        }
    }
} catch (Throwable $e) {
    $problems++;
    out('fail', 'could not list webhook endpoints', $e->getMessage());
}
} // end: sections that need a usable secret key

if (!isset($opts['url'])) {
    echo "\n== done: $problems problem(s) (pass --url to also probe the deployed route) ==\n";
    exit($problems === 0 ? 0 : 1);
}

echo "\n== 4. the deployed route ==\n";
$base = rtrim($opts['url'], '/');

[$code, $hdr, , $err] = http_probe($base . '/');
if ($code === 0) {
    $problems++;
    out('fail', "cannot reach $base", $err);
} else {
    out('ok', "$base answers $code over https");
}

// An unsigned POST must be refused. What it refuses WITH is the diagnosis.
$payload = '{"id":"evt_preflight","object":"event","type":"ping"}';
[$code, $hdr, $body, $err] = http_probe(
    $base . $webhookPath,
    'POST',
    $payload,
    ['Content-Type: application/json']
);
switch (true) {
    case $code === 400:
    case $code === 403:
        out('ok', "an unsigned webhook is rejected with $code");
        break;
    case $code === 200:
        $problems++;
        out('fail', 'an UNSIGNED webhook was accepted with 200',
            "the route is not verifying the signature at all; anyone can post a\n"
            . 'paid invoice to this URL and get an account upgraded for free');
        break;
    case $code === 419:
        $problems++;
        out('fail', 'the webhook route returned 419',
            "CSRF protection is still on for this path; Stripe has no token so\n"
            . 'every real event is dropped. Add the path to the CSRF exception list.');
        break;
    case $code === 302 || $code === 301:
        $problems++;
        preg_match('/^location:\s*(.+)$/im', $hdr, $m);
        out('fail', "the webhook route redirects ($code)",
            'auth or a redirect is in front of it: ' . trim($m[1] ?? '?')
            . "\nStripe does not follow redirects; the event is lost.");
        break;
    case $code === 404:
        $problems++;
        out('fail', 'the webhook route is 404',
            "it is not deployed, or nginx is answering instead of Laravel.\n"
            . 'Check for the X-App-Backend header on this path.');
        break;
    case $code >= 500:
        $problems++;
        out('fail', "the webhook route 500s ($code)",
            "Stripe will retry for days and the handler will keep failing.\n"
            . substr(strip_tags($body), 0, 300));
        break;
    default:
        out('warn', "an unsigned webhook returned $code", substr(strip_tags($body), 0, 300));
}

// A correctly signed probe should get past verification. The handler is
// expected to shrug at an unknown event type, which is itself worth proving:
// a handler that 500s on an event it does not know will fail on any event
// Stripe adds later.
if ($whsec !== null && $whsec !== '') {
    $ts  = time();
    [$code, , $body] = http_probe(
        $base . $webhookPath,
        'POST',
        $payload,
        [
            'Content-Type: application/json',
            'Stripe-Signature: ' . stripe_signature($payload, $whsec, $ts),
        ]
    );
    if ($code >= 200 && $code < 300) {
        out('ok', "a correctly signed unknown event is accepted with $code (signature config matches)");
    } elseif ($code === 400) {
        $problems++;
        out('fail', 'a correctly signed event was still rejected with 400',
            "the STRIPE_WEBHOOK_SECRET in the .env does not match the one the\n"
            . "running process has. Usual cause: config was cached before the\n"
            . 'value changed, so `php artisan config:clear` then re-cache.');
    } else {
        out('warn', "a correctly signed unknown event returned $code",
            "a handler should ignore event types it does not know rather than\n"
            . 'error, or every new Stripe event type becomes an outage.'
            . "\n" . substr(strip_tags((string) $body), 0, 300));
    }
}

echo "\n== done: $problems problem(s) ==\n";
echo "\nNot checked here, on purpose: a real end-to-end charge. That needs a\n"
   . "real card on a live key, which means real money moving in your account.\n"
   . "Run exactly one, then refund it from the dashboard.\n";

exit($problems === 0 ? 0 : 1);

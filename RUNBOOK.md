# Production launch runbook

Laravel API + React SPA on one EC2 instance, GoDaddy domain, Stripe live.

Everything in `deploy/` was written and tested on my own box before it goes
near your instance. The nginx config passes `nginx -t` and 20 functional
assertions (`.rehearsal/run.sh`); the Stripe preflight passes 17 self-tests
and 7 end-to-end diagnosis checks against stub routes
(`.rehearsal/probe-test.sh`). Nothing here has been run against your account.

---

## What I need from you

| | why |
|---|---|
| GitHub read access for `anirudhatalmale6-alt` | to read the payment flow and the CI config |
| SSH to the EC2 instance (public key below, or the `.pem`) | to deploy |
| the domain name | to write the vhost and request the certificate |
| one line on what the payment issue looks like to a user | to reproduce it before changing anything |

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICX5vhSIFWTOYkpm9AlrEEXKaOAgP3VoI467V6pF84lp
```

Two things stay with you because I cannot log into dashboards on anyone's
behalf: the clicks inside the **Stripe dashboard** and inside **GoDaddy DNS**.
I give you the exact values to paste and do everything else.

---

## Order of operations

The sequence matters. Doing Stripe before DNS means registering a webhook URL
that does not resolve yet, and Stripe disables an endpoint that keeps failing.

### 1. Server (no downtime risk, nothing is live yet)

1. `nginx`, `php8.3-fpm` + extensions (`mbstring bcmath curl xml zip intl mysql`),
   `composer`, `node 20`, `mysql-server`, `certbot`
2. Directory layout and ownership:
   ```
   /var/www/app/{repo,releases,shared/api/storage}
   /var/www/letsencrypt/.well-known/acme-challenge   (chmod 755 — 750 gives a 404)
   /var/log/app
   ```
3. `deploy/env/api.env.production.example` -> `/var/www/app/shared/api/.env`,
   filled in. **Still on the test Stripe keys at this point.**
4. Clone the repo into `/var/www/app/repo`

### 2. DNS, before any certificate

GoDaddy, in *My Products > DNS*:

| Type | Name | Value | TTL |
|---|---|---|---|
| A | `@` | the instance's **Elastic IP** | 600 |
| A | `www` | the same Elastic IP | 600 |

- Use an **Elastic IP**, not the instance's public IPv4. A plain public IP
  changes every time the instance stops, and the site then points at someone
  else's server.
- If GoDaddy is also handling the email for this domain, do not touch the MX
  records. Only the two A records change.
- Drop the TTL to 600 **before** making the change if the records already
  point somewhere, so a mistake costs ten minutes rather than a day.
- Wait for propagation and check it from somewhere that is not your own
  machine. Your own resolver caches the old answer and makes a finished
  change look stuck:
  ```
  dig +short @1.1.1.1 DOMAIN A
  dig +short @8.8.8.8 DOMAIN A
  ```

### 3. Certificate and HTTPS

1. Install `deploy/nginx-app.conf` with `DOMAIN` and `SNIPPET_DIR` replaced,
   and `deploy/snippets/security-headers.conf` alongside it.
2. First pass with only the port-80 server block enabled, then:
   ```
   certbot certonly --webroot -w /var/www/letsencrypt -d DOMAIN -d www.DOMAIN
   ```
   The `www` vhost in the config exists for exactly this reason: a
   certificate covering both names cannot be **renewed** if nginx has no
   server block answering for `www`, and the failure only surfaces 60 days
   later when the renewal silently stops.
3. Enable the 443 blocks, `nginx -t`, reload.
4. `certbot renew --dry-run` — do this now, not at launch. A renewal that
   cannot work is a site that goes dark in two months.
5. HSTS stays commented out for the first few days. It is a one-way door:
   once a browser has seen it, a broken certificate becomes an
   unbypassable error page for the full `max-age`.

### 4. First deploy (still on Stripe test keys)

```
sudo install -m 750 -o www-data -g www-data deploy/deploy.sh /var/www/app/deploy.sh
sudo -u www-data /var/www/app/deploy.sh
```

The script builds into a new `releases/<timestamp>/` directory and only
moves the `current` symlink after the new code has been **proved to boot**
(`artisan about` loads every service provider and the whole config). A
build that fails leaves the running site untouched, and
`deploy.sh --rollback` is a single symlink move.

Then the queue worker and scheduler:

```
sudo cp deploy/systemd/* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now app-queue.service app-scheduler.timer
```

Verify end to end on test keys: sign up, subscribe with `4242 4242 4242 4242`,
then with `4000 0025 0000 3155` (which forces the 3DS challenge), then with
`4000 0000 0000 9995` (insufficient funds). All three have to behave
correctly before the keys change. Most "it broke in live mode" reports are
really "it never worked with 3DS", and live cards trigger 3DS where
`4242` never does.

### 5. The outstanding payment issue

Before this, I reproduce it on the test keys and show you the failing request
and the log line. I do not want to guess at it from the description, and a
payment bug fixed by assumption tends to come back on a different path.

### 6. Stripe: test to live

1. Dashboard > toggle to live mode > *Developers > API keys*: `pk_live_`, `sk_live_`
2. **Create the live webhook endpoint separately.** Endpoints do not carry
   over from test mode. URL `https://DOMAIN/stripe/webhook`, subscribing to
   the events the handler actually switches on.
3. Copy that endpoint's **signing secret** — a new `whsec_`, different from
   the test one. This is the single most common launch failure: keys swapped,
   signing secret not, so every live event fails verification, the app
   records nothing, and the checkout page still looks fine to the buyer.
4. Any `price_...` / `prod_...` IDs the app has hardcoded or stored have to be
   recreated in live mode and the stored IDs updated. Stripe prices are
   immutable, so a changed amount means a new price, never an edit.
5. Update the API `.env`, then **rebuild the front end** — the publishable key
   is compiled into the bundle, so editing a file on the server does nothing:
   ```
   php artisan config:clear && php artisan config:cache
   sudo -u www-data /var/www/app/deploy.sh
   ```
6. Run the preflight:
   ```
   php deploy/stripe-preflight.php \
       --env=/var/www/app/shared/api/.env \
       --frontend-env=/var/www/app/current/web/.env.production \
       --url=https://DOMAIN
   ```
   It is read-only against Stripe — it lists, it never creates or charges. It
   checks key-mode agreement across backend and bundle, that the live
   endpoint exists and is enabled and subscribes to the right events, and
   that the deployed route rejects an unsigned POST with 400 rather than
   accepting it with 200 (anyone can forge a paid invoice), 419 (CSRF still
   in front of it), 302 (auth still in front of it) or 404 (not deployed).

### 7. The one real transaction

The preflight deliberately stops short of completing a payment. A real charge
on a live key moves real money in your account, so that one is yours: one
real card, one subscription, confirm the webhook arrived, confirm the record
in your database, then refund it from the dashboard. I will watch the logs
while you do it and tell you exactly what arrived.

---

## Checks worth keeping after launch

```
# did the request even reach the box, and what answered it
sudo tail -f /var/log/nginx/app.access.log
curl -sI https://DOMAIN/api/health | grep -i x-app-backend     # "laravel" or nginx answered

# a PHP fatal never reaches the Laravel log; it only exists here
sudo tail -f /var/log/php8.3-fpm.log

sudo tail -f /var/www/app/shared/api/storage/logs/laravel-$(date +%F).log
sudo journalctl -u app-queue -f
php /var/www/app/current/api/artisan queue:failed
```

In the Stripe dashboard, *Developers > Events* shows every delivery attempt
and its response. A column of 400s there is the signing secret; a column of
500s is the handler; nothing at all means the endpoint URL is wrong or
disabled.

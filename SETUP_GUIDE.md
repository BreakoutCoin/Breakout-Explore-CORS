# Breakout Explore CORS Proxy — Setup Guide

This guide documents the service end to end: what each piece does, where it
lives, how to reproduce it behind either Apache or Caddy, and the specific
things that tripped us up along the way so they're easy to avoid next time.

The proxy hardcodes no hostname. Throughout this guide `$DOMAIN` stands for the
public hostname of the instance you are deploying — our production pair is
`explore.brk.zone` (primary) and `api.brk.zone` (live backup), and section 6
covers running both. Most of the commands below can be pasted after a
`DOMAIN=explore.brk.zone`, but the shortcut is `./setup.sh --domain $DOMAIN`,
which fills the templates for you.

---

## 1. What this is, and how a request flows

Wallet software (web, browser plugin, mobile, desktop) needs to query the
Breakout chain and broadcast transactions from a browser context. The raw
`breakoutd` JSON-RPC can't be called from a browser: it sends no CORS headers
and sits behind HTTP Basic auth that must never be exposed in client-side code.

The solution is a small Node proxy that presents a browser-friendly HTTPS API,
keeps the RPC credentials server-side, exposes only a whitelist of methods, and
gates broadcasting behind a proof-of-funds signature. TLS and the public
hostname are handled by a reverse proxy (Apache in our deployment) so the Node
process only ever listens on loopback. Nothing in the Node process knows the
public hostname except the `PUBLIC_HOST`/`SITE_NAME` strings it is told to
advertise, so a second instance on a different domain is the same binary with a
different unit file.

```
  wallet / browser
        │  HTTPS  (https://$DOMAIN, port 443)
        ▼
  Apache (or Caddy)         ← terminates TLS, reverse-proxies, redirects http→https
        │  HTTP   (127.0.0.1:3333)
        ▼
  breakout-cors-proxy.js    ← CORS, method whitelist, proof-of-funds auth
        │  JSON-RPC + Basic auth  (127.0.0.1:50542)
        ▼
  breakoutd  (Explore API)
```

Everything from the Node proxy inward stays on `127.0.0.1`, so the only publicly
reachable surface is Apache on 80/443.

---

## 2. Files at a glance

| File | Location | Purpose |
|---|---|---|
| `breakout-cors-proxy.js` | `/home/jstroud/breakout-proxy/` | The proxy itself. Zero-dependency Node. Adds CORS, whitelists 13 methods, implements the auth handshake, forwards to the RPC. |
| `breakout-proxy.service` | `/etc/systemd/system/` | systemd unit that keeps the proxy running, restarts it on failure, and sets its environment (`RPC_CONF`, `HOST`, `PUBLIC_HOST`, `PEERS`, `SITE_NAME`, `AUTH_SECRET`, etc.). Generated from the template. |
| `breakout.conf` | `/home/jstroud/.breakout/` | The node's own config — source of `rpcuser`/`rpcpassword` (read by the proxy) and where `exploreapi=1` is enabled. Pre-existing; not created here. |
| `$DOMAIN.conf` | `/etc/apache2/sites-available/` | Apache `:80` virtual host — redirects all HTTP to HTTPS. |
| `$DOMAIN-le-ssl.conf` | `/etc/apache2/sites-available/` | Apache `:443` virtual host — TLS + `ProxyPass` to `127.0.0.1:3333`. Generated and maintained by certbot. |
| Let's Encrypt cert | `/etc/letsencrypt/live/$DOMAIN/` | `fullchain.pem` / `privkey.pem`, auto-renewed by the certbot timer. |
| `Caddyfile` | `/etc/caddy/` | Only if you use Caddy instead of Apache. One-block reverse proxy with automatic HTTPS. Not used in the Apache deployment. |
| `demo.html` | your machine / any static host | Browser test client: exercises each read endpoint and the full auth → broadcast flow. |
| `README.md` | repo | Reference for endpoints, the auth handshake, config vars, and security notes. |
| `AGENT-API.md` | repo | Condensed endpoint/error reference written for API clients and agents. |
| `SETUP_GUIDE.md` | repo | This document. |
| `setup.sh` | repo | Fills the templates for one instance and writes `generated/$DOMAIN/`. Generates only — installs nothing. |
| `templates/` | repo | The unit and vhost templates, with `@PLACEHOLDER@` slots. Edit these, not the generated output. |
| `generated/` | repo (gitignored) | setup.sh output. **Contains a live `AUTH_SECRET`** — never commit or publish it. |

---

## 3. The Node proxy + systemd

**Enable the Explore API on the node** (in `breakout.conf`): `exploreapi=1`, then
restart `breakoutd`. Without it every method the proxy exposes — both the
HD-account and the address commands — errors with
`** ERROR: Explore API only **`.

**Generate the deployment files.** From a checkout of this repo:

```bash
./setup.sh --domain "$DOMAIN"
```

This writes `generated/$DOMAIN/` containing the systemd unit (with a freshly
generated `AUTH_SECRET`), the Apache and Caddy configs, a copy of
`breakout-cors-proxy.js`, and an `install.sh`. Nothing is installed and no
service is touched — review the output first. The directory is self-contained,
so you can `scp -r generated/$DOMAIN/ server:` and run `sudo ./install.sh`
there.

`./setup.sh --help` lists every option (`--port`, `--user`, `--install-dir`,
`--rpc-conf`, `--node`, `--tls apache|caddy|both`, and the failover options in
section 6).

**Or install by hand.** The unit `setup.sh` produces is the template in
`templates/breakout-proxy.service.tmpl` with the `@PLACEHOLDER@` slots filled.
To write it yourself, put `breakout-cors-proxy.js` in
`/home/jstroud/breakout-proxy/` and create the unit. The safest way to write it
is a quoted heredoc (plain ASCII, no smart punctuation — see sticking point 2):

```bash
sudo tee /etc/systemd/system/breakout-proxy.service > /dev/null <<'EOF'
[Unit]
Description=Breakout Explore CORS proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=jstroud
Environment=HOST=127.0.0.1
Environment=PORT=3333
Environment=RPC_CONF=/home/jstroud/.breakout/breakout.conf
Environment=PUBLIC_HOST=explore.brk.zone
Environment=PEERS=api.brk.zone
Environment=SITE_NAME=brk.zone
Environment=AUTH_SECRET=REPLACE_WITH_openssl_rand_hex_32
WorkingDirectory=/home/jstroud/breakout-proxy
ExecStart=/usr/bin/node /home/jstroud/breakout-proxy/breakout-cors-proxy.js
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=full
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now breakout-proxy
sudo systemctl status breakout-proxy
```

Confirm it's on loopback: `ss -ltnp | grep 3333` should show `127.0.0.1:3333`.

**Pin `AUTH_SECRET`.** The proxy signs auth tokens with this key. If it's unset,
a new random key is generated on every start, so each restart invalidates all
live tokens. Generate one and put the literal value in the unit:

```bash
openssl rand -hex 32          # copy the 64-char output
sudo EDITOR=vim systemctl edit --full breakout-proxy
#   set: Environment=AUTH_SECRET=<paste the copied value — no backticks, no <>>
sudo systemctl restart breakout-proxy
```

`systemctl edit --full` opens the whole unit for editing and reloads it on save;
`EDITOR=vim` just chooses the editor. systemd stores everything after `=` as a
literal string — it does not run `openssl` or expand backticks, so you must
generate the value yourself and paste the result.

---

## 4. Reverse proxy + TLS

Pick one. We use **Apache** because it was already serving another site
(`explorer.breakoutcoin.com`) on this box; **Caddy** is the simpler choice on a
host with nothing else on ports 80/443.

Either way, do **not** add CORS headers at the reverse-proxy layer — the Node
proxy already sets `Access-Control-Allow-Origin` and answers the `OPTIONS`
preflight itself. A duplicated CORS header makes browsers reject the response.

### Option A — Apache (our deployment)

```bash
sudo a2enmod proxy proxy_http rewrite
```

Create the HTTP virtual host (certbot reads this to build the HTTPS one):

```bash
sudo tee /etc/apache2/sites-available/$DOMAIN.conf > /dev/null <<EOF
<VirtualHost *:80>
    ServerName $DOMAIN
    ProxyPreserveHost On
    ProxyPass        / http://127.0.0.1:3333/
    ProxyPassReverse / http://127.0.0.1:3333/
</VirtualHost>
EOF

sudo a2ensite "$DOMAIN"
sudo apache2ctl configtest && sudo systemctl reload apache2
```

Get the certificate; certbot creates the `:443` vhost (`-le-ssl.conf`) with SSL
plus the proxy directives:

```bash
sudo apt install -y certbot python3-certbot-apache
sudo certbot --apache -d "$DOMAIN"
```

Note these heredocs are now unquoted (`<<EOF`, not `<<'EOF'`) so `$DOMAIN`
expands. The Apache `%{...}` and Caddy braces are not shell syntax and pass
through untouched; the systemd unit heredoc above stays **quoted** because it
must be taken literally.

Newer certbot sometimes skips the redirect prompt (it did for us), so convert
the `:80` vhost to a redirect manually:

```bash
sudo tee /etc/apache2/sites-available/$DOMAIN.conf > /dev/null <<EOF
<VirtualHost *:80>
    ServerName $DOMAIN
    RewriteEngine On
    RewriteCond %{HTTPS} off
    RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [END,NE,R=permanent]
</VirtualHost>
EOF

sudo apache2ctl configtest && sudo systemctl reload apache2
```

The proxy directives now live in the certbot-managed `:443` vhost; the `:80`
vhost only redirects. Auto-renewal keeps working because the Apache authenticator
handles the ACME challenge itself rather than serving a file through `:80`.

### Option B — Caddy (standalone host)

Only if nothing else holds 80/443. Caddy provisions the Let's Encrypt cert
automatically — no certbot needed.

```bash
sudo tee /etc/caddy/Caddyfile > /dev/null <<EOF
$DOMAIN {
	reverse_proxy 127.0.0.1:3333
}
EOF

sudo systemctl restart caddy
sudo journalctl -u caddy -f      # watch it obtain the cert
```

Open 80 and 443 in the firewall (`sudo ufw allow 80/tcp && sudo ufw allow 443/tcp`)
plus your VPS provider's security group; 80 is required for the ACME challenge.

### Certificate renewal (Apache/certbot)

certbot installs a systemd timer that runs twice daily and renews within 30 days
of expiry, reloading Apache automatically. Verify:

```bash
systemctl list-timers | grep certbot     # timer is scheduled
sudo certbot renew --dry-run              # full rehearsal; expect "succeeded"
```

Caddy handles its own renewal internally — nothing to schedule.

---

## 5. What the proxy exposes (README in brief)

**Read endpoints — open, no auth.** Two families, both plain GETs with query
params:

- *By HD account (xpub):* `gethdaccountbalance`, `gethdaccountinoutspg`,
  `gethdaccountutxospg` — e.g.
  `GET /gethdaccountutxospg?xpub=…&page=1&perpage=50&color=1`.
- *By address:* `getaddressbalance`, `getaddressinfo`, `getaddressutxospg`,
  `getaddressinoutspg` — e.g.
  `GET /getaddressutxospg?address=bx…&page=1&perpage=50`. These take **no**
  `color` argument.
- *Chain/explore data:* `getblockcount` (no params), `getcardinfo?ticker=…`,
  `gettransaction?txid=…`.
- *Rich list:* `getrichlist?color=1&start=101&max=100` (offset-based: `start` is
  the nth-richest rank, default 1; `max` caps the count, default 100) and
  `getrichlistpg?color=1&page=2&perpage=20` (the paged form; `ordering` here
  sorts by balance, default `true` = richest first). `color` is required on both.

Types are coerced (page/perpage → int, ordering → bool) and optional positional
gaps are filled so `color` without `ordering` still lines up.

**Broadcast — gated by proof of funds:**
`POST /sendrawtransaction` requires `Authorization: Bearer <token>`. The token
comes from a three-step handshake:

1. `GET /auth/challenge?address=bx…` → a single-use `nonce` and a domain-bound
   `message` (explicitly states it proves control only, not spending authority).
2. The wallet signs that exact message with the address's key (message signing,
   not a transaction — no key leaves the wallet).
3. `POST /auth/verify {nonce, signature}` → the proxy verifies via the node's
   `verifymessage` RPC and confirms the address holds a qualifying balance, then
   returns a ~15-minute bearer token.

On every broadcast the proxy re-checks the address is still funded and applies a
per-address rate limit before forwarding to the RPC.

**Key config vars (environment):** `RPC_CONF` (or `RPC_USER`/`RPC_PASS`),
`HOST`/`PORT`, `PUBLIC_HOST`/`PEERS`/`SITE_NAME` (identity and failover — section 6),
`ALLOW_ORIGIN`, `REQUIRE_AUTH`, `AUTH_SECRET`, `TOKEN_TTL` (900s),
`CHALLENGE_TTL` (300s), `MIN_BALANCE`, `BROADCAST_MAX`/`BROADCAST_WINDOW`.

**`MIN_BALANCE` note:** set to `0.01999999`. Because the check is strictly
greater-than and amounts are 8-decimal, this requires a balance of at least
`0.02000000` — i.e. min fee plus min output, enough to actually fund a spend
under consensus rules, not merely a dusty nonzero balance.

**Security posture:** CORS is not access control (native clients ignore it — the
token is the real gate); the fund gate blocks empty/Sybil addresses but pair it
with the rate limit against funded spammers; tokens are bearer credentials
protected by TLS and short TTL; keep the Node proxy on loopback behind the TLS
reverse proxy.

---

## 6. Running a second instance (live backup)

Wallet users are the reason this exists: if the proxy a wallet is pointed at is
down, the wallet is down. Running a second, interchangeable instance on a
different hostname lets a wallet offer the alternative in a pulldown and keep
working. Our pair is `explore.brk.zone` (primary) and `api.brk.zone` (backup).

They are the same code with different unit files. Generate both from one
secret:

```bash
SECRET=$(openssl rand -hex 32)

./setup.sh --domain explore.brk.zone --site-name brk.zone \
           --peers api.brk.zone --auth-secret "$SECRET"

./setup.sh --domain api.brk.zone --site-name brk.zone \
           --peers explore.brk.zone --auth-secret "$SECRET"
```

Then deploy each `generated/<host>/` to its server as in sections 3 and 4.

**Why the three flags matter.**

- `--auth-secret` shared → a bearer token minted by one instance is accepted by
  the other, so a wallet that fails over mid-session does not have to
  re-authenticate. Omit it and each instance generates its own, which is the
  right choice only if you *want* the instances isolated.
- `--site-name` shared → both instances name the same realm in the message a
  user signs. If they differ, a user failing over is asked to sign a
  visibly different message for what is, to them, the same service — and the
  realm string is the thing that makes the signature meaningful.
- `--peers` → each instance advertises the other at `GET /`, so a client can
  discover its failover options instead of shipping a hardcoded list:

```console
$ curl -s https://explore.brk.zone/ | jq '{version, instance, peers, site_name}'
{
  "version": "0.1.1.0",
  "instance": "explore.brk.zone",
  "peers": ["api.brk.zone"],
  "site_name": "brk.zone"
}
```

**What does not carry across.** Challenge nonces live in one process's memory.
A challenge issued by `explore` cannot be verified by `api`, whatever the
secret is — the nonce is simply unknown there. A client must run
challenge → verify against a single instance, then may use the resulting token
against either. `demo.html` implements exactly this: a server pulldown, a
"Discover peers" button that reads `/`, and per-request use of whichever server
is selected.

**Operationally**, the two instances are independent: separate hosts, separate
`breakoutd` (or one node serving both, if you accept the shared failure
domain), separate certificates. The only coupling is the shared `AUTH_SECRET`,
which means rotating it is a two-server operation — change both, or tokens
minted on the rotated one bounce off the other.

---

## 7. Sticking points (and the lessons)

**1. The proxy was unreachable — "Connection refused."**
A stray `HOST=x2.hey.icu` in the interactive shell was picked up as the bind
address; it resolved to loopback locally, so nothing listened on the public IP
and external connects were refused. *Lesson:* bind explicitly (`HOST=0.0.0.0` for
direct exposure, or `127.0.0.1` behind a reverse proxy). systemd gives the
service a clean environment, so the stray shell var doesn't reach it there —
which is exactly why the service works even though the manual run didn't.

**2. systemd refused the unit — "Assignment outside of section / no ExecStart."**
The comment block pasted into the unit carried smart punctuation (em-dashes) or
an invisible character that broke section parsing, so `[Service]` and everything
under it — including `ExecStart` — was ignored. *Lesson:* write unit files as
plain ASCII with a quoted heredoc (`<<'EOF'`); avoid pasting rich text into
config files.

**3. Caddy wouldn't start — "address already in use" on :80.**
Apache was already serving another domain on 80/443. Two servers can't share the
ports. *Lesson:* on a host that already runs a web server, add a vhost to it
rather than introducing a second one. We switched from Caddy to an Apache vhost.

**4. certbot didn't offer the HTTP→HTTPS redirect.**
Newer certbot versions sometimes skip that interactive prompt. *Lesson:* add the
redirect to the `:80` vhost yourself (the `RewriteRule` above); renewals still
work because the Apache authenticator handles the challenge.

**5. "The redirect isn't working" — but it was.**
`curl` without `-L` doesn't follow a 301; it just prints the redirect page. The
`301` + `Location:` header meant it was working perfectly. *Lesson:* use
`curl -L` to follow redirects, `curl -I` to inspect the headers. Browsers follow
automatically.

**6. The demo page wouldn't call the `http://` endpoint.**
A page loaded over HTTPS is forbidden from making plaintext-HTTP requests (mixed
content), so the request was blocked before the redirect could fire. *Lesson:*
this is expected and desirable — always configure clients with the `https://`
URL.

**7. The `AUTH_SECRET` edit — where does that line go?**
The `Environment=AUTH_SECRET=…` line belongs inside the `[Service]` section of
the unit, edited via `sudo systemctl edit --full breakout-proxy` (with
`EDITOR=vim` to choose the editor). The `<…>` and backticks in the earlier note
were placeholders, not literal text: generate the value with `openssl rand -hex 32`
and paste the actual output — systemd does not run commands in `Environment=`.

---

## 8. Operations cheat sheet

```bash
# proxy
sudo systemctl restart breakout-proxy
sudo systemctl status  breakout-proxy
sudo journalctl -u breakout-proxy -f
ss -ltnp | grep 3333                     # expect 127.0.0.1:3333

# apache
sudo apache2ctl configtest
sudo systemctl reload apache2
sudo journalctl -u apache2 -f

# tls
systemctl list-timers | grep certbot
sudo certbot renew --dry-run

# smoke tests
BASE=https://explore.brk.zone          # or https://api.brk.zone
curl "$BASE/"                                          # index: methods, instance, peers
curl "$BASE/gethdaccountbalance?xpub=XPUB"             # open read (by xpub)
curl "$BASE/getaddressbalance?address=bx…"             # open read (by address)
curl "$BASE/getcardinfo?ticker=DAS"                    # open read (card/deck)
curl "$BASE/getrichlistpg?color=1&page=1&perpage=20"   # open read (rich list)
curl "$BASE/gettransaction?txid=…"                     # open read (tx)
curl "$BASE/auth/challenge?address=bx…"                # start auth
curl -L "http://explore.brk.zone/…"                    # verify redirect

# both instances agree on realm and version, and each knows the other
for h in explore.brk.zone api.brk.zone; do
  curl -s "https://$h/" | jq -c '{version, instance, peers, site_name}'
done
```

A version mismatch between the two means a redeploy reached only one host.

`VERSION` at the top of `breakout-cors-proxy.js` is the release string the
index reports. Bump it with each release and move the git tag to match, so
`curl $BASE/ | jq -r .version` is a reliable answer to "what is actually
running there".

After changing `breakout-cors-proxy.js`, redeploy it to **every** instance —
`scp` it to each `/home/jstroud/breakout-proxy/` and
`sudo systemctl restart breakout-proxy` on each. A `setup.sh --force` re-run
regenerates a host's files, but note it mints a **new** `AUTH_SECRET` unless
you pass `--auth-secret`, which would desynchronize a failover pair.

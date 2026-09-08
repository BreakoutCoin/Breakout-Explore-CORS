# Breakout Explore — CORS proxy

A tiny, zero-dependency Node.js proxy that lets browsers (and any other client)
call your Breakout `breakoutd` node. It adds CORS, keeps the RPC credentials
server-side, exposes only an explicit whitelist of methods, and gates
**broadcasting** behind a proof-of-funds signature.

- **[AGENT-API.md](AGENT-API.md)** — condensed endpoint and error reference for
  API clients and agents.
- **[SETUP_GUIDE.md](SETUP_GUIDE.md)** — end-to-end deployment: systemd, Apache
  or Caddy, TLS, troubleshooting.
- **[demo.html](demo.html)** — browser test client for every endpoint and the
  full auth → broadcast flow.
- **[setup.sh](setup.sh)** + **[templates/](templates/)** — generate the systemd
  unit and reverse-proxy configs for a given hostname.

## Endpoints

Read endpoints are open. `sendrawtransaction` requires a bearer token (see
**Auth** below). All responses are JSON: `{ "ok": true, "result": ... }` or
`{ "ok": false, "error": { "code", "message" } }`.

| Endpoint | Params | Auth |
|---|---|---|
| `GET /gethdaccountbalance` | `xpub` (req), `color` (opt) | open |
| `GET /gethdaccountinoutspg` | `xpub`, `page`, `perpage` (req), `ordering`, `color` (opt) | open |
| `GET /gethdaccountutxospg` | `xpub`, `page`, `perpage` (req), `ordering`, `color` (opt) | open |
| `GET /getaddressbalance` | `address` (req) | open |
| `GET /getaddressinfo` | `address` (req) | open |
| `GET /getaddressutxospg` | `address`, `page`, `perpage` (req), `ordering` (opt) | open |
| `GET /getaddressinoutspg` | `address`, `page`, `perpage` (req), `ordering` (opt) | open |
| `GET /getblockcount` | — | open |
| `GET /getcardinfo` | `ticker` (req) | open |
| `GET /getrichlist` | `color` (req), `start`, `max` (opt) | open |
| `GET /getrichlistpg` | `color`, `page`, `perpage` (req), `ordering` (opt) | open |
| `GET /gettransaction` | `txid` (req) | open |
| `GET /auth/challenge` | `address` (req) | open |
| `POST /auth/verify` | `{nonce, signature}` (JSON body) | open |
| `POST /sendrawtransaction` | `hex` (body or `?hex=`) + `Authorization: Bearer <token>` | **token** |
| `GET /` | — (self-describing index) | open |

## Auth — proof of funds for broadcasting

Broadcasting is gated so that only a client controlling an address with a
nonzero balance can push transactions. This is Sybil-resistant (an attacker
needs real funded addresses) and low-friction for legitimate users (anyone
spending already controls funded inputs). The handshake:

1. **Challenge.** `GET /auth/challenge?address=bx…` → returns a `nonce` and a
   canonical `message` to sign. Nonces are single-use and expire in
   `CHALLENGE_TTL` seconds (default 300).
2. **Sign.** The wallet signs that exact `message` with the address's private
   key — standard message signing, **not** a transaction signature. No key
   ever leaves the wallet and the signature cannot move funds.
3. **Verify.** `POST /auth/verify` with `{"nonce":"…","signature":"…"}`. The
   proxy verifies the signature via the node's `verifymessage` RPC and confirms
   the address holds a balance, then returns a short-lived bearer `token`
   (default 15 min).
4. **Broadcast.** `POST /sendrawtransaction` with header
   `Authorization: Bearer <token>` and the raw hex as the body. The proxy
   **re-checks that the address is still funded on every broadcast** and applies
   a per-address rate limit before forwarding.

### Example (curl)

```bash
BASE=https://explore.brk.zone     # or any instance you run
ADDR=bx...

# 1. challenge
curl -s "$BASE/auth/challenge?address=$ADDR"
#    -> copy the "message" and sign it in your wallet; note the "nonce"

# 3. verify (POST JSON — base64 signatures are not query-safe)
curl -s -X POST "$BASE/auth/verify" \
     -H 'Content-Type: application/json' \
     -d '{"nonce":"NONCE_HERE","signature":"BASE64_SIG_HERE"}'
#    -> { "ok": true, "result": { "token": "…", "address": "…", "expires": … } }

# 4. broadcast
curl -s -X POST "$BASE/sendrawtransaction" \
     -H "Authorization: Bearer TOKEN_HERE" \
     --data-binary '0100000001...'
```

Reads need no token:

```bash
# by HD account (xpub)
curl "$BASE/gethdaccountbalance?xpub=xpub6C..."
curl "$BASE/gethdaccountutxospg?xpub=xpub6C...&page=1&perpage=50&color=1"

# by address
curl "$BASE/getaddressbalance?address=bx..."
curl "$BASE/getaddressinfo?address=bx..."
curl "$BASE/getaddressutxospg?address=bx...&page=1&perpage=50"
curl "$BASE/getaddressinoutspg?address=bx...&page=1&perpage=50"

# chain / explore data
curl "$BASE/getblockcount"
curl "$BASE/getcardinfo?ticker=DAS"
curl "$BASE/getrichlist?color=1&start=101&max=100"
curl "$BASE/getrichlistpg?color=1&page=2&perpage=20"
curl "$BASE/gettransaction?txid=..."
```

The `*pg` endpoints are paginated: a request returns up to `perpage` results
starting at `1 + perpage * (page - 1)`. `ordering` selects blockchain position
order and defaults to `true` (forward) — except on `getrichlistpg`, where it
orders by balance and `true` means descending (richest first). Note the address
endpoints take no `color` argument — only the HD-account and rich-list ones do,
and on the rich-list endpoints it is required.

`getrichlist` is the offset-based form of the same data: `start` is the
nth-richest rank (1-based, default 1) and `max` caps how many addresses come
back (default 100), so `start=101&max=100` is the second hundred richest.

## Run it

```bash
RPC_CONF=/home/you/.breakout/breakout.conf node breakout-cors-proxy.js
# or: RPC_USER=you RPC_PASS=secret node breakout-cors-proxy.js
```

Behind Apache/Caddy terminating TLS, keep it bound to loopback (`HOST=127.0.0.1`,
the default).

## Deploy it

The proxy hardcodes no hostname — the domain lives only in the systemd unit and
the reverse-proxy vhost, both of which `setup.sh` generates from
[`templates/`](templates/):

```bash
./setup.sh --domain explore.brk.zone
```

That writes `generated/install-explore.brk.zone/` containing the unit, the
Apache and Caddy configs, a copy of the proxy, and an `install.sh` to run as
root on the server. It generates only — nothing is installed and no service is
touched. `install.sh` detects whether the target runs Apache or Caddy and
configures whichever it finds, so the same output works on either.
`./setup.sh --help` lists every option; [SETUP_GUIDE.md](SETUP_GUIDE.md) walks
through a full deployment.

## Running more than one instance

Wallets can be pointed at a second, interchangeable instance when the first is
unreachable. Generate each with the **same** `--auth-secret` and `--site-name`,
and tell each about the other:

```bash
SECRET=$(openssl rand -hex 32)
./setup.sh --domain explore.brk.zone --site-name brk.zone \
           --peers api.brk.zone --auth-secret "$SECRET"
./setup.sh --domain api.brk.zone --site-name brk.zone \
           --peers explore.brk.zone --auth-secret "$SECRET"
```

Each instance then advertises its version, itself and its peers at `GET /`:

```json
{"ok":true,"version":"0.1.1.0","instance":"explore.brk.zone",
 "peers":["api.brk.zone"],"site_name":"brk.zone"}
```

`version` is the proxy's own release string, so a partial redeploy is visible
without shelling into either box:

```bash
for h in explore.brk.zone api.brk.zone; do
  printf '%-20s %s\n' "$h" "$(curl -s "https://$h/" | jq -r .version)"
done
```

so a client can build its server list from the server instead of shipping one.
What does and does not survive a failover:

| | Carries across instances? |
|---|---|
| Read endpoints | Yes — stateless and identical |
| A minted token | Only if the instances share `AUTH_SECRET` |
| An outstanding challenge/nonce | **No** — nonces are per-process and in memory |

So a client that fails over mid-session can keep using its token where the
secret is shared, but must always restart the challenge → verify handshake
against whichever instance it is now talking to.

## Configuration (environment variables)

| Var | Default | Meaning |
|---|---|---|
| `PORT` | `3333` | Listen port |
| `HOST` | `127.0.0.1` | Bind interface |
| `RPC_URL` | `http://127.0.0.1:50542` | Upstream RPC base URL |
| `RPC_USER` / `RPC_PASS` | — | RPC credentials (or use `RPC_CONF`) |
| `RPC_CONF` | — | Path to `breakout.conf` to read creds from |
| `PUBLIC_HOST` | — | This instance's public FQDN, advertised as `instance` by `GET /` |
| `PEERS` | — | Comma-separated hostnames of equivalent instances, advertised as `peers` |
| `SITE_NAME` | `PUBLIC_HOST` | Realm named in the message users sign. Instances sharing `AUTH_SECRET` must share this too |
| `ALLOW_ORIGIN` | `*` | `Access-Control-Allow-Origin` value |
| `REQUIRE_AUTH` | `true` | Gate `sendrawtransaction`; set `false` to leave it open |
| `AUTH_SECRET` | random per start | HMAC key for tokens. **Set this** to keep tokens valid across restarts / multiple instances |
| `TOKEN_TTL` | `900` | Token lifetime, seconds |
| `CHALLENGE_TTL` | `300` | Challenge/nonce lifetime, seconds |
| `MIN_BALANCE` | `0` | Balance must be strictly greater than this (0 → any nonzero) |
| `BROADCAST_MAX` | `30` | Max broadcasts per window per address |
| `BROADCAST_WINDOW` | `60` | Rate-limit window, seconds |

### Setting `AUTH_SECRET`

By default the token-signing key is random and regenerated on each start, so a
restart invalidates all live tokens (fine for 15-min tokens, but it also means
you can't run two instances that accept each other's tokens). To pin it, add to
the systemd unit:

```
Environment=AUTH_SECRET=<a long random string, e.g. `openssl rand -hex 32`>
```

`setup.sh` generates one for you and reminds you to reuse it across a failover
pair.

## Security notes

- **CORS is not access control.** `ALLOW_ORIGIN` only constrains browsers;
  native/mobile clients ignore it. The bearer token is the real gate on
  broadcasting.
- Requires the node's `verifymessage` RPC. If it's missing, `/auth/verify`
  returns a 501 and the proxy logs a warning at startup.
- Signature verification proves *control* of an address, not identity, and the
  signed message names a realm (`SITE_NAME`) and explicitly states it does not
  authorize spending — so wallets aren't training users to blind-sign dangerous
  text. `SITE_NAME` is deliberately **not** taken from the `Host` header: that is
  attacker-controlled, and a signer must be shown a realm the operator chose.
- `peers` is operator-declared configuration, not a health check or a trust
  statement. A client should treat a peer as a candidate to try, and re-verify
  anything security-relevant against whichever instance actually answers.
- The fund gate blocks spam from empty/Sybil addresses but not from a
  determined *funded* attacker; that's what `BROADCAST_MAX` / `BROADCAST_WINDOW`
  are for.
- Tokens are bearer credentials — protected in transit by TLS and limited by
  `TOKEN_TTL`. Keep the proxy on loopback behind your TLS reverse proxy.

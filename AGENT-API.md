# Breakout Explore CORS Proxy — Agent API

Base: any instance of the proxy, e.g. `https://explore.brk.zone`. The service is
not tied to one hostname; an operator may run several interchangeable instances.
Discover them at runtime rather than hardcoding a list — see **Instances and
failover** below.

HTTP proxy over a Breakout `breakoutd` node. Reads are open. Broadcasting requires a bearer token proving control of a funded address.

## Response envelope

Success: `{"ok": true, "result": <any>}`
Failure: `{"ok": false, "error": {"code": <int>, "message": <string>}}`

**Check `ok`, not HTTP status.** Upstream RPC errors (bad xpub, invalid address, rejected tx) return **HTTP 200** with `ok:false`. HTTP status is non-200 only for proxy-level failures (auth, params, unreachable node).

## Read endpoints (no auth)

| Method | Path | Required | Optional |
|---|---|---|---|
| GET | `/gethdaccountbalance` | `xpub` | `color` |
| GET | `/gethdaccountinoutspg` | `xpub`, `page`, `perpage` | `ordering`, `color` |
| GET | `/gethdaccountutxospg` | `xpub`, `page`, `perpage` | `ordering`, `color` |
| GET | `/getaddressbalance` | `address` | — |
| GET | `/getaddressinfo` | `address` | — |
| GET | `/getaddressutxospg` | `address`, `page`, `perpage` | `ordering` |
| GET | `/getaddressinoutspg` | `address`, `page`, `perpage` | `ordering` |
| GET | `/getblockcount` | — | — |
| GET | `/getcardinfo` | `ticker` | — |
| GET | `/getrichlist` | `color` | `start`, `max` |
| GET | `/getrichlistpg` | `color`, `page`, `perpage` | `ordering` |
| GET | `/gettransaction` | `txid` | — |
| GET | `/` or `/help` | — | — (returns method index) |

Params are query-string. Types: `xpub`/`address`/`ticker`/`txid` string; `page`/`perpage`/`color`/`start`/`max` integer; `ordering` boolean.

- `page` is 1-based. Returns up to `perpage` results starting at index `1 + perpage * (page - 1)`.
- `ordering` = blockchain position order. Accepts `true|1|yes|false|0|no`. Defaults to `true` (forward).
  On `getrichlistpg` it instead orders by balance, `true` = descending (richest first).
- `color` selects currency; HD-account and rich-list endpoints only. Address endpoints reject it.
  It is **required** on both rich-list endpoints.
- `getrichlist` is offset-based, not paged: `start` is the nth-richest rank (1-based, default 1)
  and `max` is the cap on addresses returned (default 100). `start=101&max=100` is the second
  hundred richest. `getrichlistpg` is the paged equivalent.
- Empty string == omitted.

```bash
curl "$BASE/getaddressbalance?address=bx..."
curl "$BASE/getaddressinoutspg?address=bx...&page=1&perpage=50"
curl "$BASE/gethdaccountutxospg?xpub=xpub6C...&page=1&perpage=50&color=1"
curl "$BASE/getblockcount"
curl "$BASE/getcardinfo?ticker=DAS"
curl "$BASE/getrichlist?color=1&start=101&max=100"
curl "$BASE/getrichlistpg?color=1&page=2&perpage=20"
curl "$BASE/gettransaction?txid=..."
```

`gettransaction` includes the confirming block's `height` and `blocktime`
alongside the creator-set `time`, and omits zero-value entries from `amounts`.

## Broadcast (auth required)

`POST /sendrawtransaction` + header `Authorization: Bearer <token>`

Hex accepted three ways: `?hex=...`, raw body, or JSON body `{"hex":"..."}`.

Per broadcast the proxy re-verifies the token address is still funded, then applies a per-address rate limit (default 30 per 60s). Rejected transactions still consume rate-limit budget.

## Auth flow

**1. Challenge** — `GET /auth/challenge?address=bx...`

```json
{"ok":true,"result":{"nonce":"…","address":"bx…","message":"…","expires":<unix>}}
```

**2. Sign** — wallet signs `message` verbatim with that address's private key. Standard message signing, not a transaction signature.

**3. Verify** — `POST /auth/verify`, JSON body `{"nonce":"…","signature":"…"}`

```json
{"ok":true,"result":{"token":"…","address":"bx…","expires":<unix>}}
```

**4. Broadcast** — use `token` as bearer.

Constraints:
- Nonce is **single-use and consumed on any verify attempt, including failures**. A failed verify requires a new challenge.
- Nonce expires in `CHALLENGE_TTL` (default 300s). Token expires in `TOKEN_TTL` (default 900s).
- Address must hold balance strictly greater than `MIN_BALANCE` (default 0, i.e. any nonzero) at verify **and** at every broadcast.
- POST JSON for verify; base64 signatures are not query-safe.
- Server restart invalidates live tokens unless `AUTH_SECRET` is pinned.

```bash
BASE=https://explore.brk.zone     # or any instance the index advertises

curl -s "$BASE/auth/challenge?address=bx..."

curl -s -X POST "$BASE/auth/verify" \
     -H 'Content-Type: application/json' \
     -d '{"nonce":"NONCE","signature":"BASE64_SIG"}'

curl -s -X POST "$BASE/sendrawtransaction" \
     -H "Authorization: Bearer TOKEN" \
     --data-binary '0100000001...'
```

## Instances and failover

`GET /` identifies the instance you reached and lists equivalent ones:

```json
{"ok":true,"service":"breakout-cors-proxy",
 "instance":"explore.brk.zone","peers":["api.brk.zone"],
 "site_name":"brk.zone", "...":"..."}
```

- `instance` — this server's own public hostname, or `null` if the operator did
  not set one.
- `peers` — other hostnames serving the same chain and method set. Treat as
  failover candidates, in no particular order.
- `site_name` — the realm named in the message users sign during auth.

**Client guidance.** Fetch `/` once at startup from any known instance, union
`instance` with `peers`, and keep that list. On a transport failure or 5xx,
retry the same request against another entry — read endpoints are stateless and
identical across instances, so failover needs no extra state.

Auth does not carry across quite so freely:

- **Nonces are per-instance and in memory.** A challenge from one host can only
  be verified by that same host. After failing over, start a new challenge.
- **Tokens carry only if the operator shares `AUTH_SECRET`** across instances.
  Where it is shared, a token minted anywhere is accepted everywhere until it
  expires. Where it is not, expect `401` after failover and re-authenticate.
- `peers` reflects operator configuration, not a health check. A listed peer may
  still be down; treat the list as candidates, not guarantees.

## Errors

| HTTP | code | Meaning | Action |
|---|---|---|---|
| 200 | (upstream) | RPC-level error in `error.message` | Fix the request; do not retry as-is |
| 400 | -32602 | Missing/malformed param | Fix params |
| 400 | -32000 | Unknown, used, or expired nonce | New challenge |
| 401 | -32001 | Missing/invalid/expired token, or signature mismatch | Re-auth |
| 403 | -32002 | Address holds no balance | Fund address |
| 404 | -32601 | Method not exposed | — |
| 429 | -32005 | Broadcast rate limit exceeded | Back off, retry after window |
| 501 | -32601 | Node lacks `verifymessage` | Auth unusable server-side |
| 502 | -32603 | Node unreachable / balance re-check failed | Retry with backoff |
| 502 | -32700 | Non-JSON from node | Retry with backoff |

## CORS

`OPTIONS` → 204. Allows `GET, POST, OPTIONS`; headers `Content-Type, Authorization`. Origin per server `ALLOW_ORIGIN` (default `*`).

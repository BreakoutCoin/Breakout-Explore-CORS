#!/usr/bin/env node
/*
 * breakout-cors-proxy.js
 * -------------------------------------------------------------------------
 * A tiny, zero-dependency CORS proxy in front of a Breakout `breakoutd` node,
 * with an optional proof-of-funds gate on broadcasting.
 *
 * Read endpoints are open (public chain data). Broadcasting
 * (sendrawtransaction) requires a bearer token that the client obtains by
 * proving control of an address that currently holds a balance:
 *
 *   1. GET  /auth/challenge?address=bx...   -> { nonce, message, expires }
 *   2. wallet signs `message` with that address's private key (message
 *      signing only -- no keys leave the wallet, this cannot move funds)
 *   3. POST /auth/verify  {nonce, signature} -> { token, address, expires }
 *      (server verifies the signature via the node's `verifymessage` RPC and
 *       confirms the address holds a nonzero balance)
 *   4. POST /sendrawtransaction  with header `Authorization: Bearer <token>`
 *      (server re-checks the address is still funded on EVERY broadcast, and
 *       applies a per-address rate limit)
 *
 * Public (browser-reachable) methods:
 *   - gethdaccountbalance   <xpub> [color]                      (open)
 *   - gethdaccountinoutspg  <xpub> <page> <perpage> [ord][col]  (open)
 *   - gethdaccountutxospg   <xpub> <page> <perpage> [ord][col]  (open)
 *   - getaddressbalance     <address>                           (open)
 *   - getaddressinfo        <address>                           (open)
 *   - getaddressutxospg     <address> <page> <perpage> [ord]    (open)
 *   - getaddressinoutspg    <address> <page> <perpage> [ord]    (open)
 *   - getblockcount         --                                  (open)
 *   - getcardinfo           <ticker>                            (open)
 *   - getrichlist           <color> [start] [max]               (open)
 *   - getrichlistpg         <color> <page> <perpage> [ord]      (open)
 *   - gettransaction        <txid>                               (open)
 *   - sendrawtransaction    <hex>                               (auth-gated)
 *   - auth/challenge, auth/verify                               (open)
 *
 * Every response is JSON:
 *   success -> { "ok": true,  "result": <...> }
 *   failure -> { "ok": false, "error": { "code": <int>, "message": "..." } }
 *
 * Run:
 *   RPC_CONF=/home/jstroud/.breakout/breakout.conf node breakout-cors-proxy.js
 *
 * Configuration (environment variables):
 *   PORT              listen port                       (default 3333)
 *   HOST              bind interface                    (default 127.0.0.1)
 *   RPC_URL           upstream RPC base URL             (default http://127.0.0.1:50542)
 *   RPC_USER/RPC_PASS RPC credentials                   (or use RPC_CONF)
 *   RPC_CONF          path to breakout.conf for creds
 *   ALLOW_ORIGIN      Access-Control-Allow-Origin       (default *)
 *   REQUIRE_AUTH      gate sendrawtransaction           (default true)
 *   AUTH_SECRET       HMAC key for tokens               (default: random per start)
 *   TOKEN_TTL         token lifetime, seconds           (default 900 = 15 min)
 *   CHALLENGE_TTL     challenge/nonce lifetime, seconds (default 300 = 5 min)
 *   MIN_BALANCE       balance strictly required above   (default 0 -> any nonzero)
 *   BROADCAST_MAX     broadcasts per window per address (default 30)
 *   BROADCAST_WINDOW  rate-limit window, seconds        (default 60)
 * -------------------------------------------------------------------------
 */
'use strict';
 
const http = require('http');
const url = require('url');
const fs = require('fs');
const crypto = require('crypto');
 
// ---- configuration -------------------------------------------------------
 
const PORT = parseInt(process.env.PORT || '3333', 10);
const HOST = process.env.HOST || '127.0.0.1';
const RPC_URL = process.env.RPC_URL || 'http://127.0.0.1:50542';
const ALLOW_ORIGIN = process.env.ALLOW_ORIGIN || '*';
 
const REQUIRE_AUTH = (process.env.REQUIRE_AUTH || 'true').toLowerCase() !== 'false';
const AUTH_SECRET = process.env.AUTH_SECRET || crypto.randomBytes(32).toString('hex');
const TOKEN_TTL = parseInt(process.env.TOKEN_TTL || '900', 10);
const CHALLENGE_TTL = parseInt(process.env.CHALLENGE_TTL || '300', 10);
const MIN_BALANCE = Number(process.env.MIN_BALANCE || '0');
const BROADCAST_MAX = parseInt(process.env.BROADCAST_MAX || '30', 10);
const BROADCAST_WINDOW = parseInt(process.env.BROADCAST_WINDOW || '60', 10) * 1000;
 
// Credentials: prefer explicit env vars, else parse a breakout.conf if given.
let RPC_USER = process.env.RPC_USER || '';
let RPC_PASS = process.env.RPC_PASS || '';
 
if ((!RPC_USER || !RPC_PASS) && process.env.RPC_CONF) {
  try {
    const conf = fs.readFileSync(process.env.RPC_CONF, 'utf8');
    for (const line of conf.split(/\r?\n/)) {
      const m = line.match(/^\s*(rpcuser|rpcpassword)\s*=\s*(.+?)\s*$/);
      if (!m) continue;
      if (m[1] === 'rpcuser' && !RPC_USER) RPC_USER = m[2];
      if (m[1] === 'rpcpassword' && !RPC_PASS) RPC_PASS = m[2];
    }
  } catch (e) {
    console.error(`Could not read RPC_CONF (${process.env.RPC_CONF}): ${e.message}`);
  }
}
 
if (!RPC_USER || !RPC_PASS) {
  console.error(
    'ERROR: RPC credentials not set.\n' +
    '  Provide RPC_USER and RPC_PASS, or point RPC_CONF at your breakout.conf.'
  );
  process.exit(1);
}
 
const RPC = url.parse(RPC_URL);
const RPC_AUTH = 'Basic ' + Buffer.from(`${RPC_USER}:${RPC_PASS}`).toString('base64');
 
// ---- public method whitelist & parameter specs --------------------------
 
const T = {
  str: (v) => String(v),
  int: (v) => {
    const n = Number(v);
    if (!Number.isFinite(n) || !Number.isInteger(n)) throw new Error(`expected integer, got "${v}"`);
    return n;
  },
  bool: (v) => {
    const s = String(v).toLowerCase();
    if (s === 'true' || s === '1' || s === 'yes') return true;
    if (s === 'false' || s === '0' || s === 'no') return false;
    throw new Error(`expected boolean, got "${v}"`);
  },
};
 
const METHODS = {
  gethdaccountbalance: [
    { name: 'xpub', required: true, cast: T.str },
    { name: 'color', required: false, cast: T.int },
  ],
  gethdaccountinoutspg: [
    { name: 'xpub', required: true, cast: T.str },
    { name: 'page', required: true, cast: T.int },
    { name: 'perpage', required: true, cast: T.int },
    { name: 'ordering', required: false, cast: T.bool, default: true },
    { name: 'color', required: false, cast: T.int },
  ],
  gethdaccountutxospg: [
    { name: 'xpub', required: true, cast: T.str },
    { name: 'page', required: true, cast: T.int },
    { name: 'perpage', required: true, cast: T.int },
    { name: 'ordering', required: false, cast: T.bool, default: true },
    { name: 'color', required: false, cast: T.int },
  ],
  getaddressbalance: [
    { name: 'address', required: true, cast: T.str },
  ],
  getaddressinfo: [
    { name: 'address', required: true, cast: T.str },
  ],
  getaddressutxospg: [
    { name: 'address', required: true, cast: T.str },
    { name: 'page', required: true, cast: T.int },
    { name: 'perpage', required: true, cast: T.int },
    { name: 'ordering', required: false, cast: T.bool, default: true },
  ],
  getaddressinoutspg: [
    { name: 'address', required: true, cast: T.str },
    { name: 'page', required: true, cast: T.int },
    { name: 'perpage', required: true, cast: T.int },
    { name: 'ordering', required: false, cast: T.bool, default: true },
  ],
  getblockcount: [],
  getcardinfo: [
    { name: 'ticker', required: true, cast: T.str },
  ],
  getrichlist: [
    { name: 'color', required: true, cast: T.int },
    { name: 'start', required: false, cast: T.int, default: 1 },
    { name: 'max', required: false, cast: T.int, default: 100 },
  ],
  getrichlistpg: [
    { name: 'color', required: true, cast: T.int },
    { name: 'page', required: true, cast: T.int },
    { name: 'perpage', required: true, cast: T.int },
    { name: 'ordering', required: false, cast: T.bool, default: true },
  ],
  gettransaction: [
    { name: 'txid', required: true, cast: T.str },
  ],
  sendrawtransaction: [
    { name: 'hex', required: true, cast: T.str },
  ],
};
 
// Methods gated behind a proof-of-funds bearer token.
const AUTH_REQUIRED_METHODS = new Set(['sendrawtransaction']);
 
// Build the positional params array, filling defaults for optional gaps.
function buildParams(method, values) {
  const spec = METHODS[method];
  let lastProvided = -1;
  spec.forEach((p, i) => {
    if (values[p.name] !== undefined && values[p.name] !== '') lastProvided = i;
  });
  const params = [];
  for (let i = 0; i <= lastProvided; i++) {
    const p = spec[i];
    const raw = values[p.name];
    const provided = raw !== undefined && raw !== '';
    if (provided) params.push(p.cast(raw));
    else if (p.required) throw new Error(`missing required parameter "${p.name}"`);
    else if ('default' in p) params.push(p.default);
    else throw new Error(`parameter "${p.name}" must be supplied when later parameters are given`);
  }
  spec.forEach((p) => {
    if (p.required && (values[p.name] === undefined || values[p.name] === '')) {
      throw new Error(`missing required parameter "${p.name}"`);
    }
  });
  return params;
}
 
// ---- upstream RPC call ---------------------------------------------------
// NOTE: this can call ANY RPC method. The public METHODS whitelist only
// governs what browsers can reach; the auth path also calls verifymessage,
// which is never public. Rejects with { httpStatus, code, message }.
 
function callRpc(method, params) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ jsonrpc: '1.0', id: 'cors-proxy', method, params });
    const options = {
      protocol: RPC.protocol,
      hostname: RPC.hostname,
      port: RPC.port || 80,
      path: RPC.path || '/',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
        'Authorization': RPC_AUTH,
      },
    };
    const req = http.request(options, (res) => {
      let data = '';
      res.on('data', (c) => (data += c));
      res.on('end', () => {
        let parsed;
        try { parsed = JSON.parse(data); }
        catch (e) {
          return reject({ httpStatus: res.statusCode || 502, code: -32700,
            message: `Non-JSON response from RPC (status ${res.statusCode}): ${data.slice(0, 200)}` });
        }
        if (parsed.error) return reject({ httpStatus: 200, code: parsed.error.code, message: parsed.error.message });
        resolve(parsed.result);
      });
    });
    req.on('error', (e) =>
      reject({ httpStatus: 502, code: -32603, message: `Cannot reach RPC at ${RPC_URL}: ${e.message}` }));
    req.write(body);
    req.end();
  });
}
 
// Returns true if the address currently holds > MIN_BALANCE in its color.
// App-level RPC errors (e.g. address never seen) -> treated as unfunded.
// Transport errors (RPC down) -> re-thrown so the caller can surface a 502.
async function addressIsFunded(address) {
  let info;
  try {
    info = await callRpc('getaddressinfo', [address]);
  } catch (e) {
    if (e.httpStatus && e.httpStatus >= 500) throw e;
    return false;
  }
  const bal = Number(info && info.balance);
  return Number.isFinite(bal) && bal > MIN_BALANCE;
}
 
// ---- auth: challenges, tokens, rate limiting -----------------------------
 
const challenges = new Map();      // nonce -> { address, message, exp(seconds) }
const broadcastHits = new Map();   // address -> [timestamps ms]
 
function nowSec() { return Math.floor(Date.now() / 1000); }
 
function gcChallenges() {
  const now = nowSec();
  for (const [k, v] of challenges) if (v.exp < now) challenges.delete(k);
}
 
function issueChallenge(address) {
  const nonce = crypto.randomBytes(16).toString('hex');
  const issued = nowSec();
  const exp = issued + CHALLENGE_TTL;
  const message = [
    `explore.brk.zone: prove control of ${address}`,
    `nonce: ${nonce}`,
    `issued: ${issued}`,
    `valid until: ${exp}`,
    `This proves control of the address only. It does NOT authorize spending.`,
  ].join('\n');
  challenges.set(nonce, { address, message, exp });
  return { nonce, address, message, expires: exp };
}
 
function b64url(buf) {
  return Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function b64urlDecode(s) {
  return Buffer.from(s.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString();
}
function signToken(payload) {
  const body = b64url(JSON.stringify(payload));
  const mac = b64url(crypto.createHmac('sha256', AUTH_SECRET).update(body).digest());
  return `${body}.${mac}`;
}
function verifyToken(token) {
  if (!token || token.indexOf('.') < 0) return null;
  const [body, mac] = token.split('.');
  const expected = b64url(crypto.createHmac('sha256', AUTH_SECRET).update(body).digest());
  if (!mac || mac.length !== expected.length) return null;
  if (!crypto.timingSafeEqual(Buffer.from(mac), Buffer.from(expected))) return null;
  let payload;
  try { payload = JSON.parse(b64urlDecode(body)); } catch (e) { return null; }
  if (!payload.exp || nowSec() > payload.exp) return null;
  return payload;
}
 
function allowBroadcast(address) {
  const now = Date.now();
  const arr = (broadcastHits.get(address) || []).filter((t) => now - t < BROADCAST_WINDOW);
  if (arr.length >= BROADCAST_MAX) { broadcastHits.set(address, arr); return false; }
  arr.push(now);
  broadcastHits.set(address, arr);
  return true;
}
 
// POST /auth/verify handler. Throws { status, code, message } on failure.
async function handleVerify(values) {
  const { nonce, signature } = values;
  if (!nonce || !signature) throw { status: 400, code: -32602, message: 'nonce and signature are required' };
  const ch = challenges.get(nonce);
  if (!ch) throw { status: 400, code: -32000, message: 'unknown or already-used nonce' };
  challenges.delete(nonce); // single use, regardless of outcome
  if (ch.exp < nowSec()) throw { status: 400, code: -32000, message: 'challenge expired' };
 
  let ok;
  try { ok = await callRpc('verifymessage', [ch.address, signature, ch.message]); }
  catch (e) {
    if (e.code === -32601) throw { status: 501, code: -32601, message: 'node has no verifymessage RPC; cannot verify signatures' };
    throw { status: 502, code: e.code, message: `verifymessage failed: ${e.message}` };
  }
  if (ok !== true) throw { status: 401, code: -32001, message: 'signature does not match address' };
 
  if (!(await addressIsFunded(ch.address))) {
    throw { status: 403, code: -32002, message: 'address holds no balance' };
  }
  const exp = nowSec() + TOKEN_TTL;
  return { ok: true, result: { token: signToken({ address: ch.address, exp }), address: ch.address, expires: exp } };
}
 
// ---- HTTP helpers --------------------------------------------------------
 
function corsHeaders() {
  return {
    'Access-Control-Allow-Origin': ALLOW_ORIGIN,
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    'Access-Control-Max-Age': '86400',
  };
}
function sendJson(res, httpStatus, obj) {
  res.writeHead(httpStatus, Object.assign({ 'Content-Type': 'application/json' }, corsHeaders()));
  res.end(JSON.stringify(obj));
}
function readBody(req) {
  return new Promise((resolve) => {
    let data = '';
    req.on('data', (c) => (data += c));
    req.on('end', () => resolve(data));
  });
}
 
// ---- request router ------------------------------------------------------
 
const server = http.createServer(async (req, res) => {
  if (req.method === 'OPTIONS') { res.writeHead(204, corsHeaders()); return res.end(); }
 
  const parsed = url.parse(req.url, true);
  const method = (parsed.pathname || '/').replace(/^\/+/, '').replace(/\/+$/, '');
  const query = parsed.query || {};
 
  // ---- index ----
  if (method === '' || method === 'help') {
    return sendJson(res, 200, {
      ok: true,
      service: 'breakout-cors-proxy',
      upstream: RPC_URL,
      auth: { required_for: [...AUTH_REQUIRED_METHODS], enabled: REQUIRE_AUTH, token_ttl: TOKEN_TTL },
      methods: Object.keys(METHODS).map((m) => ({
        method: m,
        params: METHODS[m].map((p) => (p.required ? p.name : `[${p.name}]`)),
        auth: AUTH_REQUIRED_METHODS.has(m) && REQUIRE_AUTH,
      })).concat([
        { method: 'auth/challenge', params: ['address'], auth: false },
        { method: 'auth/verify', params: ['nonce', 'signature'], auth: false },
      ]),
    });
  }
 
  // ---- auth: request a challenge ----
  if (method === 'auth/challenge') {
    const address = query.address;
    if (!address) return sendJson(res, 400, { ok: false, error: { code: -32602, message: 'address query parameter is required' } });
    gcChallenges();
    return sendJson(res, 200, { ok: true, result: issueChallenge(String(address)) });
  }
 
  // ---- auth: verify signature, mint token ----
  if (method === 'auth/verify') {
    const values = {};
    if (query.nonce) values.nonce = String(query.nonce);
    if (query.signature) values.signature = String(query.signature);
    if (req.method === 'POST') {
      const raw = (await readBody(req)).trim();
      if (raw && raw[0] === '{') {
        try { const j = JSON.parse(raw); if (j.nonce) values.nonce = String(j.nonce); if (j.signature) values.signature = String(j.signature); }
        catch (_) { /* ignore malformed body */ }
      }
    }
    try { return sendJson(res, 200, await handleVerify(values)); }
    catch (e) { return sendJson(res, e.status || 400, { ok: false, error: { code: e.code || -32000, message: e.message } }); }
  }
 
  // ---- public RPC methods ----
  if (!Object.prototype.hasOwnProperty.call(METHODS, method)) {
    return sendJson(res, 404, { ok: false, error: { code: -32601, message: `Method "${method}" is not exposed by this proxy.` } });
  }
 
  // Auth gate (currently: sendrawtransaction).
  if (REQUIRE_AUTH && AUTH_REQUIRED_METHODS.has(method)) {
    const authHeader = req.headers['authorization'] || '';
    const m = authHeader.match(/^Bearer\s+(.+)$/i);
    const payload = m ? verifyToken(m[1].trim()) : null;
    if (!payload) {
      return sendJson(res, 401, { ok: false, error: { code: -32001,
        message: 'valid Bearer token required; authenticate via /auth/challenge then /auth/verify' } });
    }
    // Re-check the authenticated address is STILL funded, on every broadcast.
    let funded;
    try { funded = await addressIsFunded(payload.address); }
    catch (e) { return sendJson(res, 502, { ok: false, error: { code: -32603, message: `balance re-check failed: ${e.message}` } }); }
    if (!funded) {
      return sendJson(res, 403, { ok: false, error: { code: -32002, message: 'authenticated address no longer holds a balance' } });
    }
    if (!allowBroadcast(payload.address)) {
      return sendJson(res, 429, { ok: false, error: { code: -32005, message: 'broadcast rate limit exceeded, slow down' } });
    }
  }
 
  // Collect params from the query string.
  const values = {};
  for (const p of METHODS[method]) if (query[p.name] !== undefined) values[p.name] = query[p.name];
 
  // sendrawtransaction: also accept the raw hex in a POST body.
  if (method === 'sendrawtransaction' && req.method === 'POST' && values.hex === undefined) {
    const raw = (await readBody(req)).trim();
    if (raw) {
      let hex = raw;
      if (raw[0] === '{') { try { hex = (JSON.parse(raw).hex || '').trim(); } catch (_) {} }
      if (hex) values.hex = hex;
    }
  }
 
  let params;
  try { params = buildParams(method, values); }
  catch (e) { return sendJson(res, 400, { ok: false, error: { code: -32602, message: e.message } }); }
 
  try {
    const result = await callRpc(method, params);
    return sendJson(res, 200, { ok: true, result });
  } catch (err) {
    return sendJson(res, err.httpStatus || 502, { ok: false, error: { code: err.code, message: err.message } });
  }
});
 
// Warn at startup if the node can't verify messages (auth would be unusable).
function probeVerifyMessage() {
  if (!REQUIRE_AUTH) return;
  callRpc('verifymessage', ['probe', 'probe', 'probe']).catch((e) => {
    if (e.code === -32601) {
      console.warn('WARNING: upstream node has no `verifymessage` RPC — /auth/verify will fail.');
      console.warn('         Enable it on the node, or set REQUIRE_AUTH=false to leave broadcasting open.');
    }
    // any other error (e.g. "invalid address") means the method exists — good.
  });
}
 
server.listen(PORT, HOST, () => {
  console.log(`breakout-cors-proxy listening on http://${HOST}:${PORT}`);
  console.log(`  -> forwarding to ${RPC_URL} (CORS: ${ALLOW_ORIGIN})`);
  console.log(`  -> public: ${Object.keys(METHODS).join(', ')}`);
  console.log(`  -> auth: ${REQUIRE_AUTH ? `ON — ${[...AUTH_REQUIRED_METHODS].join(', ')} gated (token ${TOKEN_TTL}s)` : 'OFF'}`);
  if (REQUIRE_AUTH && !process.env.AUTH_SECRET) {
    console.log('  -> note: AUTH_SECRET not set; using a random per-start key (restart invalidates live tokens)');
  }
  probeVerifyMessage();
});

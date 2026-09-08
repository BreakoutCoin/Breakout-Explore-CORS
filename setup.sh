#!/bin/sh
# setup.sh — generate the deployment files for one CORS proxy instance.
#
# The proxy itself is domain-agnostic: the hostname lives entirely in the
# systemd unit and the reverse-proxy vhost. This script fills the templates in
# templates/ for a given domain and writes the result to an output directory.
#
# It generates only. Nothing is installed, no service is touched, no sudo is
# used. Review the output, then run the generated install.sh.
#
# Two instances (e.g. a primary and a live backup a wallet can fail over to)
# are two runs of this script with different --domain values against the SAME
# --site-config, which is what keeps their signing realm and AUTH_SECRET in
# step so a token minted by one is accepted by the other.
# See SETUP_GUIDE.md section 6.

set -eu

die()  { printf 'setup.sh: %s\n' "$*" >&2; exit 1; }
warn() { printf 'setup.sh: warning: %s\n' "$*" >&2; }

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TEMPLATES="$SELF_DIR/templates"

# ---- defaults ------------------------------------------------------------
#
# Three tiers, highest wins: command line, then the site config, then the
# defaults set here. Site-wide identity (site, auth-secret, peers) has no
# command-line form at all — see read_site_config below for why.

DOMAIN=""
SITE_CONFIG=""
FORCE=0

# Values from the command line. Empty means "not given", so the config can
# still supply it.
CLI_PORT=""; CLI_USER=""; CLI_INSTALL_DIR=""; CLI_RPC_CONF=""; CLI_RPC_URL=""
CLI_NODE=""; CLI_TLS=""; CLI_SERVICE_NAME=""; CLI_OUT=""

# Values from the site config.
CFG_SITE=""; CFG_AUTH_SECRET=""; CFG_PEERS=""
CFG_PORT=""; CFG_USER=""; CFG_INSTALL_DIR=""; CFG_RPC_CONF=""; CFG_RPC_URL=""
CFG_NODE=""; CFG_TLS=""; CFG_SERVICE_NAME=""

usage() {
	cat <<'EOF'
Usage: ./setup.sh --domain <fqdn> --site-config <file> [options]

Required:
  --domain <fqdn>        Public hostname for THIS instance (e.g. explore.brk.zone)
  --site-config <file>   The site's shared config. Not public — it holds the
                         AUTH_SECRET. See "Site config" below.

Placement (each may also be set in the site config; the command line wins):
  --user <name>          System user the service runs as. Default: current user.
  --install-dir <path>   Where breakout-cors-proxy.js lives on the server.
                         Default: /home/<user>/breakout-proxy
  --rpc-conf <path>      breakout.conf to read RPC credentials from.
                         Default: /home/<user>/.breakout/breakout.conf
  --rpc-url <url>        Upstream RPC. Default: http://127.0.0.1:50542
  --node <path>          node binary ON THE TARGET. Default: whatever this
                         machine has, which install.sh re-resolves on the
                         server if it is not executable there.
  --port <n>             Loopback port for this instance. Default: 3333
  --service-name <name>  systemd unit name, no .service suffix.
                         Default: breakout-proxy
  --tls apache|caddy|both   Which reverse-proxy configs to emit. Default: both

Output:
  --out <dir>            Output directory. Default: ./generated/install-<domain>
  --force                Overwrite an existing output directory
  -h, --help             This message

Site config
-----------
Every instance of one site must present the SAME signing realm and the SAME
AUTH_SECRET, or a token minted on one is rejected by the others and a wallet
failing over has to re-authenticate. Those values are therefore not command-
line flags — passing them per-invocation is exactly how a pair drifts apart.
They live in one file, shared by every domain of the site:

    site        = brk.zone                          (required)
    auth-secret = <openssl rand -hex 32>            (required)
    peers       = explore.brk.zone,api.brk.zone     (optional)

    # optional placement defaults, overridden by the command line
    tls          = both
    user         = jstroud
    install-dir  = /home/jstroud/breakout-proxy
    rpc-conf     = /home/jstroud/.breakout/breakout.conf
    rpc-url      = http://127.0.0.1:50542
    node         = /usr/bin/node
    port         = 3333
    service-name = breakout-proxy

"peers" lists every domain of the site, including this one; --domain is pruned
from it automatically, so one file serves every instance unchanged. "domain"
is NOT accepted in the config — it is what distinguishes one instance from
another. Keep the file out of any repository and chmod 600 it.

Example — a site of two hosts, from one config:

  ./setup.sh --domain explore.brk.zone --site-config ../site-configs/brk.zone-site.conf --tls apache
  ./setup.sh --domain api.brk.zone     --site-config ../site-configs/brk.zone-site.conf --tls caddy
EOF
}

# ---- argument parsing ----------------------------------------------------

while [ $# -gt 0 ]; do
	case "$1" in
		--domain)       [ $# -ge 2 ] || die "--domain needs a value";       DOMAIN=$2; shift 2 ;;
		--site-config)  [ $# -ge 2 ] || die "--site-config needs a value";  SITE_CONFIG=$2; shift 2 ;;
		--port)         [ $# -ge 2 ] || die "--port needs a value";         CLI_PORT=$2; shift 2 ;;
		--user)         [ $# -ge 2 ] || die "--user needs a value";         CLI_USER=$2; shift 2 ;;
		--install-dir)  [ $# -ge 2 ] || die "--install-dir needs a value";  CLI_INSTALL_DIR=$2; shift 2 ;;
		--rpc-conf)     [ $# -ge 2 ] || die "--rpc-conf needs a value";     CLI_RPC_CONF=$2; shift 2 ;;
		--rpc-url)      [ $# -ge 2 ] || die "--rpc-url needs a value";      CLI_RPC_URL=$2; shift 2 ;;
		--node)         [ $# -ge 2 ] || die "--node needs a value";         CLI_NODE=$2; shift 2 ;;
		--out)          [ $# -ge 2 ] || die "--out needs a value";          CLI_OUT=$2; shift 2 ;;
		--tls)          [ $# -ge 2 ] || die "--tls needs a value";          CLI_TLS=$2; shift 2 ;;
		--service-name) [ $# -ge 2 ] || die "--service-name needs a value"; CLI_SERVICE_NAME=$2; shift 2 ;;
		--force)        FORCE=1; shift ;;
		-h|--help)      usage; exit 0 ;;
		--site-name|--auth-secret|--peers)
			case "$1" in
				--site-name) _k=site ;;
				*)           _k=${1#--} ;;
			esac
			die "$1 was replaced by --site-config; put \"$_k\" in that file.
       Per-invocation identity is how a failover pair drifts apart, which is
       the whole reason these moved. See --help." ;;
		*)              usage >&2; die "unknown argument: $1" ;;
	esac
done

[ -n "$DOMAIN" ]      || { usage >&2; die "--domain is required"; }
[ -n "$SITE_CONFIG" ] || { usage >&2; die "--site-config is required"; }
[ -d "$TEMPLATES" ]   || die "templates/ not found next to setup.sh (looked in $TEMPLATES)"

# ---- site config ---------------------------------------------------------

trim() {
	v=$1
	v=${v#"${v%%[![:space:]]*}"}
	v=${v%"${v##*[![:space:]]}"}
	printf '%s' "$v"
}

read_site_config() {
	conf=$1
	[ -f "$conf" ] || die "site config not found: $conf"
	[ -r "$conf" ] || die "site config not readable: $conf"

	# It holds the AUTH_SECRET; anything readable beyond the owner is a leak
	# waiting to happen. Warn rather than refuse — the file may be on a
	# single-user box and this is not our call to enforce.
	case "$(ls -ld "$conf" | cut -c5-10)" in
		*[rwx]*) warn "$conf is readable beyond its owner; it holds the AUTH_SECRET.
              chmod 600 \"$conf\"" ;;
	esac

	lineno=0
	while IFS= read -r line || [ -n "$line" ]; do
		lineno=$((lineno + 1))
		t=$(trim "$line")
		[ -z "$t" ] && continue
		case "$t" in \#*) continue ;; esac
		case "$t" in *=*) ;; *) die "$conf:$lineno: expected \"key = value\", got: $t" ;; esac
		k=$(trim "${t%%=*}")
		v=$(trim "${t#*=}")
		case "$k" in
			site)         CFG_SITE=$v ;;
			auth-secret)  CFG_AUTH_SECRET=$v ;;
			peers)        CFG_PEERS=$v ;;
			tls)          CFG_TLS=$v ;;
			user)         CFG_USER=$v ;;
			install-dir)  CFG_INSTALL_DIR=$v ;;
			rpc-conf)     CFG_RPC_CONF=$v ;;
			rpc-url)      CFG_RPC_URL=$v ;;
			node)         CFG_NODE=$v ;;
			port)         CFG_PORT=$v ;;
			service-name) CFG_SERVICE_NAME=$v ;;
			domain)
				die "$conf:$lineno: \"domain\" is not allowed in a site config.
       The config is shared by every domain of the site; the domain is what
       distinguishes one instance from another. Pass it as --domain." ;;
			*)  die "$conf:$lineno: unknown key \"$k\"" ;;
		esac
	done < "$conf"

	[ -n "$CFG_SITE" ] || die "$conf: \"site\" is required (the signing realm shared by every instance)"
	if [ -z "$CFG_AUTH_SECRET" ]; then
		die "$conf: \"auth-secret\" is required.
       It has no command-line form on purpose: every instance of a site must
       use the same value. Generate one once and keep it in this file:
           printf 'auth-secret = %s\\n' \"\$(openssl rand -hex 32)\" >> \"$conf\""
	fi
}

read_site_config "$SITE_CONFIG"

# ---- merge: command line > site config > default -------------------------

pick() { [ -n "$1" ] && printf '%s' "$1" || printf '%s' "$2"; }

PORT=$(pick "$CLI_PORT"                 "$(pick "$CFG_PORT" 3333)")
RUN_USER=$(pick "$CLI_USER"             "$(pick "$CFG_USER" "$(id -un)")")
RPC_URL=$(pick "$CLI_RPC_URL"           "$(pick "$CFG_RPC_URL" http://127.0.0.1:50542)")
TLS=$(pick "$CLI_TLS"                   "$(pick "$CFG_TLS" both)")
SERVICE_NAME=$(pick "$CLI_SERVICE_NAME" "$(pick "$CFG_SERVICE_NAME" breakout-proxy)")
INSTALL_DIR=$(pick "$CLI_INSTALL_DIR"   "$CFG_INSTALL_DIR")
RPC_CONF=$(pick "$CLI_RPC_CONF"         "$CFG_RPC_CONF")
NODE_BIN=$(pick "$CLI_NODE"             "$CFG_NODE")
OUT=$CLI_OUT

SITE_NAME=$CFG_SITE
AUTH_SECRET=$CFG_AUTH_SECRET

# ---- validation ----------------------------------------------------------

# Values are substituted with sed using | as the delimiter, and land in a
# systemd unit where a newline would silently truncate the directive. Reject
# anything that could break either.
check_clean() {
	case "$2" in
		*'|'*)  die "$1 must not contain '|'" ;;
		*'&'*)  die "$1 must not contain '&'" ;;
		*'
'*)            die "$1 must not contain a newline" ;;
	esac
}

case "$DOMAIN" in
	*[!A-Za-z0-9.-]*) die "--domain must be a hostname: letters, digits, dots, hyphens" ;;
esac
case "$PORT" in
	''|*[!0-9]*) die "port must be numeric" ;;
esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "port must be 1-65535"
case "$RUN_USER" in
	*[!A-Za-z0-9._-]*) die "user is not a valid username" ;;
esac
case "$TLS" in
	apache|caddy|both) ;;
	*) die "tls must be apache, caddy or both (got \"$TLS\")" ;;
esac
case "$SITE_NAME" in
	*[!A-Za-z0-9.-]*) die "site must be a hostname-like realm: letters, digits, dots, hyphens" ;;
esac
case "$CFG_PEERS" in
	*[!A-Za-z0-9.,-]*) die "peers must be a comma-separated hostname list" ;;
esac
case "$AUTH_SECRET" in
	*[!0-9a-fA-F]*) die "auth-secret must be hex (openssl rand -hex 32)" ;;
esac
[ "${#AUTH_SECRET}" -ge 32 ] || die "auth-secret is too short; use at least 32 hex chars"

# ---- peers: drop this domain, dedupe -------------------------------------

PEERS=""
saveIFS=$IFS
IFS=','
for p in $CFG_PEERS; do
	p=$(trim "$p")
	[ -z "$p" ] && continue
	[ "$p" = "$DOMAIN" ] && continue
	case ",$PEERS," in *",$p,"*) continue ;; esac
	PEERS="${PEERS:+$PEERS,}$p"
done
IFS=$saveIFS

# A peer that does not resolve is a dead failover target advertised to every
# wallet. Advisory only: DNS may be unavailable, or the host not yet created.
if command -v host >/dev/null 2>&1; then
	saveIFS=$IFS
	IFS=','
	for p in $PEERS $DOMAIN; do
		host -W 2 "$p" >/dev/null 2>&1 || warn "\"$p\" does not resolve — check the site config for a typo"
	done
	IFS=$saveIFS
fi

# ---- derived defaults ----------------------------------------------------

[ -n "$INSTALL_DIR" ]  || INSTALL_DIR="/home/$RUN_USER/breakout-proxy"
[ -n "$RPC_CONF" ]     || RPC_CONF="/home/$RUN_USER/.breakout/breakout.conf"
[ -n "$OUT" ]          || OUT="$SELF_DIR/generated/install-$DOMAIN"

if [ -z "$NODE_BIN" ]; then
	NODE_BIN=$(command -v node 2>/dev/null || true)
	[ -n "$NODE_BIN" ] || NODE_BIN=/usr/bin/node
fi

for pair in "install-dir:$INSTALL_DIR" "rpc-conf:$RPC_CONF" "rpc-url:$RPC_URL" \
            "site:$SITE_NAME" "node:$NODE_BIN" "service-name:$SERVICE_NAME"; do
	check_clean "${pair%%:*}" "${pair#*:}"
done

# ---- output directory ----------------------------------------------------

if [ -e "$OUT" ] && [ "$FORCE" -ne 1 ]; then
	die "$OUT already exists; pass --force to overwrite"
fi
mkdir -p "$OUT"

render() {
	src=$1; dst=$2
	[ -f "$src" ] || die "missing template: $src"
	sed -e "s|@DOMAIN@|$DOMAIN|g" \
	    -e "s|@PORT@|$PORT|g" \
	    -e "s|@USER@|$RUN_USER|g" \
	    -e "s|@INSTALL_DIR@|$INSTALL_DIR|g" \
	    -e "s|@RPC_CONF@|$RPC_CONF|g" \
	    -e "s|@RPC_URL@|$RPC_URL|g" \
	    -e "s|@SITE_NAME@|$SITE_NAME|g" \
	    -e "s|@PEERS@|$PEERS|g" \
	    -e "s|@AUTH_SECRET@|$AUTH_SECRET|g" \
	    -e "s|@NODE_BIN@|$NODE_BIN|g" \
	    -e "s|@SERVICE_NAME@|$SERVICE_NAME|g" \
	    "$src" > "$dst"
}

render "$TEMPLATES/breakout-proxy.service.tmpl" "$OUT/$SERVICE_NAME.service"
chmod 600 "$OUT/$SERVICE_NAME.service"   # contains AUTH_SECRET

# Copy the proxy in so the output directory is self-contained: it can be
# scp'd to the server on its own and install.sh will find everything beside
# itself, rather than pointing back at paths on the machine that generated it.
[ -f "$SELF_DIR/breakout-cors-proxy.js" ] \
	|| die "breakout-cors-proxy.js not found next to setup.sh"
cp "$SELF_DIR/breakout-cors-proxy.js" "$OUT/breakout-cors-proxy.js"

if [ "$TLS" = apache ] || [ "$TLS" = both ]; then
	render "$TEMPLATES/apache-http.conf.tmpl" "$OUT/$DOMAIN.conf"
	render "$TEMPLATES/apache-ssl.conf.tmpl"  "$OUT/$DOMAIN-le-ssl.conf"
fi
if [ "$TLS" = caddy ] || [ "$TLS" = both ]; then
	render "$TEMPLATES/Caddyfile.tmpl" "$OUT/Caddyfile"
fi

# ---- generated installer -------------------------------------------------
#
# The installer detects the reverse proxy actually present on the box rather
# than assuming the one this machine happens to run. A host fronted by Caddy
# has no a2enmod, and vice versa; --tls both emits configs for either and lets
# the target decide.

{
	cat <<EOF
#!/bin/sh
# Generated by setup.sh for $DOMAIN. Review before running; needs root.
set -eu

SRC=\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd)

echo "==> installing proxy to $INSTALL_DIR"
install -d -o "$RUN_USER" -g "$RUN_USER" "$INSTALL_DIR"
install -o "$RUN_USER" -g "$RUN_USER" -m 644 \\
        "\$SRC/breakout-cors-proxy.js" "$INSTALL_DIR/breakout-cors-proxy.js"

echo "==> resolving node on THIS host"
# The unit ships with whatever path the generating machine had, which is
# routinely wrong across a macOS -> Linux hop (/usr/local/bin/node vs
# /usr/bin/node) and shows up only as systemd status=203/EXEC. Trust the
# generated path just far enough to check it is executable here.
NODE="$NODE_BIN"
if [ ! -x "\$NODE" ]; then
	NODE=\$(command -v node 2>/dev/null || true)
	if [ -z "\$NODE" ]; then
		for c in /usr/bin/node /usr/local/bin/node /snap/bin/node /opt/node/bin/node; do
			[ -x "\$c" ] && NODE="\$c" && break
		done
	fi
	if [ -z "\$NODE" ] || [ ! -x "\$NODE" ]; then
		echo "    ERROR: no usable node on this host (generated unit wanted $NODE_BIN)." >&2
		echo "           Install node, or re-run setup.sh with --node <path>." >&2
		exit 1
	fi
	echo "    generated unit wanted $NODE_BIN, which is not executable here"
fi
echo "    using \$NODE"

echo "==> installing systemd unit"
install -m 600 "\$SRC/$SERVICE_NAME.service" "/etc/systemd/system/$SERVICE_NAME.service"
# Rewrite in place, after install, so the secret never lands in a temp file.
sed -i "s|^ExecStart=.*|ExecStart=\$NODE $INSTALL_DIR/breakout-cors-proxy.js|" \\
    "/etc/systemd/system/$SERVICE_NAME.service"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
# restart, not "enable --now": on an already-running service --now does
# nothing, so a changed Environment= would silently not take effect.
systemctl restart "$SERVICE_NAME"
systemctl --no-pager status "$SERVICE_NAME" || true

echo "==> waiting for the proxy to answer"
# systemctl restart returns as soon as the process is forked, so both checks
# below race node's startup unless we wait for it to actually bind.
i=0
while [ \$i -lt 15 ]; do
	curl -sf "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break
	i=\$((i + 1))
	sleep 1
done

echo "==> confirming it is on loopback only"
ss -ltnp | grep ":$PORT" || echo "    (nothing listening on $PORT)"

echo "==> confirming the running process picked up this unit's environment"
INSTALL_OK=1
if curl -s "http://127.0.0.1:$PORT/" | grep -q '"instance":"$DOMAIN"'; then
	echo "    ok: reports instance $DOMAIN"
else
	INSTALL_OK=0
	echo "    FAILED: / does not report instance $DOMAIN" >&2
	echo "    ---- last 20 journal lines ----" >&2
	journalctl -u "$SERVICE_NAME" -n 20 --no-pager >&2 || true
	echo "    -------------------------------" >&2
fi
EOF

	# --- Apache branch, emitted only if apache configs were generated ---
	if [ "$TLS" = apache ] || [ "$TLS" = both ]; then
		cat <<EOF

if command -v a2enmod >/dev/null 2>&1; then
	echo "==> Apache detected: installing vhost"
	a2enmod proxy proxy_http rewrite
	if [ -e "/etc/apache2/sites-available/$DOMAIN.conf" ]; then
		echo "    /etc/apache2/sites-available/$DOMAIN.conf already exists — leaving it alone."
		echo "    Compare against \$SRC/$DOMAIN.conf yourself; overwriting would revert"
		echo "    any post-certbot redirect you have already switched on."
	else
		install -m 644 "\$SRC/$DOMAIN.conf" "/etc/apache2/sites-available/$DOMAIN.conf"
		a2ensite "$DOMAIN"
	fi
	apache2ctl configtest && systemctl reload apache2

	cat <<'NOTE'

    If this host has no certificate yet, obtain one — certbot writes the
    :443 vhost itself:

        apt install -y certbot python3-certbot-apache
        certbot --apache -d $DOMAIN

    Then edit /etc/apache2/sites-available/$DOMAIN.conf and switch it from
    the stage-1 ProxyPass block to the stage-2 redirect block (the file has
    both, commented), and reload Apache.

    A reference :443 vhost is included as $DOMAIN-le-ssl.conf. certbot
    normally manages that file — do not overwrite certbot's copy with it.
NOTE
EOF
		if [ "$TLS" != both ]; then cat <<EOF
else
	echo "==> Apache not found on this host (no a2enmod)."
	echo "    Regenerate with --tls caddy, or configure your reverse proxy by hand"
	echo "    to forward to 127.0.0.1:$PORT — and do not add CORS headers there,"
	echo "    the proxy sets them itself."
fi
EOF
		fi
	fi

	# --- Caddy branch ---------------------------------------------------
	if [ "$TLS" = caddy ] || [ "$TLS" = both ]; then
		if [ "$TLS" = both ]; then printf 'elif'; else printf '\nif'; fi
		cat <<EOF
 command -v caddy >/dev/null 2>&1; then
	echo "==> Caddy detected"
	if [ ! -e /etc/caddy/Caddyfile ]; then
		install -m 644 "\$SRC/Caddyfile" /etc/caddy/Caddyfile
		systemctl restart caddy
		echo "    installed /etc/caddy/Caddyfile and restarted caddy"
	elif grep -q "^[[:space:]]*$DOMAIN[[:space:]]*{" /etc/caddy/Caddyfile; then
		echo "    /etc/caddy/Caddyfile already has a block for $DOMAIN — nothing to do."
	else
		echo "    /etc/caddy/Caddyfile exists and may serve other sites, so it was NOT"
		echo "    modified. Append this block yourself, then: systemctl reload caddy"
		echo
		sed 's/^/        /' "\$SRC/Caddyfile"
	fi
else
	echo "==> No supported reverse proxy found (looked for a2enmod and caddy)."
	echo "    Point your own front end at 127.0.0.1:$PORT — and do not add CORS"
	echo "    headers there, the proxy sets them itself."
fi
EOF
	fi

	cat <<EOF

echo
if [ "\$INSTALL_OK" = 1 ]; then
	echo "Done. Smoke test:"
	if command -v jq >/dev/null 2>&1; then
		echo "    curl -s https://$DOMAIN/ | jq '{version, instance, peers, site_name}'"
	else
		echo "    curl -s https://$DOMAIN/"
		echo "    (install jq for a readable summary:"
		echo "     curl -s https://$DOMAIN/ | jq '{version, instance, peers, site_name}')"
	fi
else
	echo "FINISHED WITH ERRORS: the proxy is not answering on 127.0.0.1:$PORT." >&2
	echo "The reverse proxy above may be configured correctly, but there is" >&2
	echo "nothing behind it. See the journal lines printed above." >&2
	exit 1
fi
EOF
} > "$OUT/install.sh"
chmod 755 "$OUT/install.sh"

# ---- summary -------------------------------------------------------------

# A short hash of the AUTH_SECRET, so two runs can be eyeballed as matching
# without ever printing the secret itself.
AUTH_SECRET_FP=$(
	printf '%s' "$AUTH_SECRET" | {
		if command -v shasum >/dev/null 2>&1; then shasum -a 256
		elif command -v sha256sum >/dev/null 2>&1; then sha256sum
		else echo "unavailable"; fi
	} | cut -c1-12
)

cat <<EOF

Generated for $DOMAIN in:
  $OUT

  $SERVICE_NAME.service   systemd unit (mode 600 — contains AUTH_SECRET)
  breakout-cors-proxy.js  the proxy, copied in so this directory ships alone
EOF
if [ "$TLS" = apache ] || [ "$TLS" = both ]; then
	cat <<EOF
  $DOMAIN.conf            Apache :80 vhost (proxy now, redirect after certbot)
  $DOMAIN-le-ssl.conf     Apache :443 vhost (reference; certbot usually owns this)
EOF
fi
if [ "$TLS" = caddy ] || [ "$TLS" = both ]; then
	cat <<EOF
  Caddyfile               Caddy alternative to the Apache pair
EOF
fi
cat <<EOF
  install.sh              review, then run as root on the server

From the site config ($SITE_CONFIG):
  signing realm  $SITE_NAME
  peers          ${PEERS:-(none)}
  auth-secret    ${AUTH_SECRET_FP} (fingerprint — every instance of this site
                 must show the same one)

Settings:
  port           127.0.0.1:$PORT
  user           $RUN_USER
  install dir    $INSTALL_DIR
  rpc conf       $RPC_CONF
  rpc url        $RPC_URL
  node           $NODE_BIN
  tls            $TLS
EOF

cat <<EOF

The output directory contains a live secret. It is covered by .gitignore —
do not commit it or copy it anywhere public. The same goes for
$SITE_CONFIG.
EOF

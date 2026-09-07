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
# are just two runs of this script with different --domain values and the SAME
# --auth-secret and --site-name, so a token minted by one is accepted by the
# other. See SETUP_GUIDE.md section 6.

set -eu

die() { printf 'setup.sh: %s\n' "$*" >&2; exit 1; }

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TEMPLATES="$SELF_DIR/templates"

# ---- defaults ------------------------------------------------------------

DOMAIN=""
PORT=3333
RUN_USER=$(id -un)
INSTALL_DIR=""
RPC_CONF=""
RPC_URL="http://127.0.0.1:50542"
SITE_NAME=""
PEERS=""
AUTH_SECRET=""
NODE_BIN=""
OUT=""
TLS="both"
SERVICE_NAME=""
FORCE=0

usage() {
	cat <<'EOF'
Usage: ./setup.sh --domain <fqdn> [options]

Required:
  --domain <fqdn>        Public hostname for this instance (e.g. explore.brk.zone)

Identity / failover:
  --site-name <name>     Realm shown to users signing an auth challenge.
                         Default: the domain. Instances sharing an AUTH_SECRET
                         MUST share this value.
  --peers <a,b,c>        Comma-separated hostnames of equivalent instances,
                         advertised by the index at "/" so wallets can offer
                         them as failover choices.
  --auth-secret <hex>    HMAC key for auth tokens. Default: freshly generated.
                         Pass the SAME value to every instance in a failover
                         pair, or tokens will not carry across.

Placement:
  --user <name>          System user the service runs as. Default: current user.
  --install-dir <path>   Where breakout-cors-proxy.js lives on the server.
                         Default: /home/<user>/breakout-proxy
  --rpc-conf <path>      breakout.conf to read RPC credentials from.
                         Default: /home/<user>/.breakout/breakout.conf
  --rpc-url <url>        Upstream RPC. Default: http://127.0.0.1:50542
  --node <path>          node binary. Default: `command -v node`, else /usr/bin/node
  --port <n>             Loopback port for this instance. Default: 3333
  --service-name <name>  systemd unit name, no .service suffix.
                         Default: breakout-proxy

Output:
  --tls apache|caddy|both   Which reverse-proxy configs to emit. Default: both
  --out <dir>            Output directory. Default: ./generated/<domain>
  --force                Overwrite an existing output directory
  -h, --help             This message

Example — a primary and its live backup, sharing tokens:

  SECRET=$(openssl rand -hex 32)
  ./setup.sh --domain explore.brk.zone --site-name brk.zone \
             --peers api.brk.zone --auth-secret "$SECRET"
  ./setup.sh --domain api.brk.zone     --site-name brk.zone \
             --peers explore.brk.zone --auth-secret "$SECRET"
EOF
}

# ---- argument parsing ----------------------------------------------------

while [ $# -gt 0 ]; do
	case "$1" in
		--domain)       [ $# -ge 2 ] || die "--domain needs a value";       DOMAIN=$2; shift 2 ;;
		--port)         [ $# -ge 2 ] || die "--port needs a value";         PORT=$2; shift 2 ;;
		--user)         [ $# -ge 2 ] || die "--user needs a value";         RUN_USER=$2; shift 2 ;;
		--install-dir)  [ $# -ge 2 ] || die "--install-dir needs a value";  INSTALL_DIR=$2; shift 2 ;;
		--rpc-conf)     [ $# -ge 2 ] || die "--rpc-conf needs a value";     RPC_CONF=$2; shift 2 ;;
		--rpc-url)      [ $# -ge 2 ] || die "--rpc-url needs a value";      RPC_URL=$2; shift 2 ;;
		--site-name)    [ $# -ge 2 ] || die "--site-name needs a value";    SITE_NAME=$2; shift 2 ;;
		--peers)        [ $# -ge 2 ] || die "--peers needs a value";        PEERS=$2; shift 2 ;;
		--auth-secret)  [ $# -ge 2 ] || die "--auth-secret needs a value";  AUTH_SECRET=$2; shift 2 ;;
		--node)         [ $# -ge 2 ] || die "--node needs a value";         NODE_BIN=$2; shift 2 ;;
		--out)          [ $# -ge 2 ] || die "--out needs a value";          OUT=$2; shift 2 ;;
		--tls)          [ $# -ge 2 ] || die "--tls needs a value";          TLS=$2; shift 2 ;;
		--service-name) [ $# -ge 2 ] || die "--service-name needs a value"; SERVICE_NAME=$2; shift 2 ;;
		--force)        FORCE=1; shift ;;
		-h|--help)      usage; exit 0 ;;
		*)              usage >&2; die "unknown argument: $1" ;;
	esac
done

# ---- validation ----------------------------------------------------------

[ -n "$DOMAIN" ] || { usage >&2; die "--domain is required"; }
[ -d "$TEMPLATES" ] || die "templates/ not found next to setup.sh (looked in $TEMPLATES)"

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
	''|*[!0-9]*) die "--port must be numeric" ;;
esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "--port must be 1-65535"
case "$RUN_USER" in
	*[!A-Za-z0-9._-]*) die "--user is not a valid username" ;;
esac
case "$TLS" in
	apache|caddy|both) ;;
	*) die "--tls must be apache, caddy or both" ;;
esac
case "$PEERS" in
	*[!A-Za-z0-9.,-]*) die "--peers must be a comma-separated hostname list" ;;
esac

# ---- derived defaults ----------------------------------------------------

[ -n "$INSTALL_DIR" ]  || INSTALL_DIR="/home/$RUN_USER/breakout-proxy"
[ -n "$RPC_CONF" ]     || RPC_CONF="/home/$RUN_USER/.breakout/breakout.conf"
[ -n "$SITE_NAME" ]    || SITE_NAME="$DOMAIN"
[ -n "$SERVICE_NAME" ] || SERVICE_NAME="breakout-proxy"
[ -n "$OUT" ]          || OUT="$SELF_DIR/generated/$DOMAIN"

if [ -z "$NODE_BIN" ]; then
	NODE_BIN=$(command -v node 2>/dev/null || true)
	[ -n "$NODE_BIN" ] || NODE_BIN=/usr/bin/node
fi

GENERATED_SECRET=0
if [ -z "$AUTH_SECRET" ]; then
	if command -v openssl >/dev/null 2>&1; then
		AUTH_SECRET=$(openssl rand -hex 32)
	elif [ -r /dev/urandom ]; then
		AUTH_SECRET=$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')
	else
		die "cannot generate an AUTH_SECRET: no openssl and no /dev/urandom. Pass --auth-secret."
	fi
	GENERATED_SECRET=1
fi
case "$AUTH_SECRET" in
	*[!0-9a-fA-F]*) die "--auth-secret must be hex (openssl rand -hex 32)" ;;
esac
[ "${#AUTH_SECRET}" -ge 32 ] || die "--auth-secret is too short; use at least 32 hex chars"

for pair in "install-dir:$INSTALL_DIR" "rpc-conf:$RPC_CONF" "rpc-url:$RPC_URL" \
            "site-name:$SITE_NAME" "node:$NODE_BIN" "service-name:$SERVICE_NAME"; do
	check_clean "--${pair%%:*}" "${pair#*:}"
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

echo "==> installing systemd unit"
install -m 600 "\$SRC/$SERVICE_NAME.service" "/etc/systemd/system/$SERVICE_NAME.service"
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"
systemctl --no-pager status "$SERVICE_NAME" || true

echo "==> confirming it is on loopback only"
ss -ltnp | grep ":$PORT" || echo "    (nothing listening on $PORT yet — check the journal)"
EOF

	if [ "$TLS" = apache ] || [ "$TLS" = both ]; then
		cat <<EOF

echo "==> Apache vhosts"
a2enmod proxy proxy_http rewrite
install -m 644 "\$SRC/$DOMAIN.conf" "/etc/apache2/sites-available/$DOMAIN.conf"
a2ensite "$DOMAIN"
apache2ctl configtest && systemctl reload apache2

cat <<'NOTE'

    Next: obtain the certificate, which writes the :443 vhost itself —

        apt install -y certbot python3-certbot-apache
        certbot --apache -d $DOMAIN

    Then edit /etc/apache2/sites-available/$DOMAIN.conf and switch it from
    the stage-1 ProxyPass block to the stage-2 redirect block (the file has
    both, commented), and reload Apache.

    A reference :443 vhost is included as $DOMAIN-le-ssl.conf. certbot
    normally manages that file — do not overwrite certbot's copy with it.
NOTE
EOF
	fi

	if [ "$TLS" = caddy ] || [ "$TLS" = both ]; then
		cat <<EOF

echo "==> Caddy (skip if you are using Apache)"
echo "    install -m 644 \$SRC/Caddyfile /etc/caddy/Caddyfile && systemctl restart caddy"
EOF
	fi

	cat <<EOF

echo
echo "Done. Smoke test:  curl https://$DOMAIN/"
EOF
} > "$OUT/install.sh"
chmod 755 "$OUT/install.sh"

# ---- summary -------------------------------------------------------------

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

Settings:
  port           127.0.0.1:$PORT
  user           $RUN_USER
  install dir    $INSTALL_DIR
  rpc conf       $RPC_CONF
  rpc url        $RPC_URL
  signing realm  $SITE_NAME
  peers          ${PEERS:-(none)}
  node           $NODE_BIN
EOF

if [ "$GENERATED_SECRET" -eq 1 ]; then
	cat <<EOF

NOTE: a fresh AUTH_SECRET was generated for this instance. If this proxy is
      part of a failover pair, pass the SAME secret to the other instance:

        ./setup.sh --domain <other-host> --site-name $SITE_NAME \\
                   --auth-secret $AUTH_SECRET

      Otherwise a token minted here will be rejected there and wallets will
      have to re-authenticate after failing over.
EOF
fi

cat <<EOF

The output directory contains a live secret. It is covered by .gitignore —
do not commit it or copy it anywhere public.
EOF

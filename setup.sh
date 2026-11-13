#!/usr/bin/env bash
# Run WuzAPI on this Linux server: check WhatsApp is reachable, generate secrets,
# start it locked down, and print what the app needs. Safe to rerun.
#
#   ./setup.sh                                 # bind 127.0.0.1, reach it over SSH tunnel
#   BIND_ADDR=10.1.2.3 ALLOW_FROM=10.1.2.50 ./setup.sh   # private IP, one app server allowed
#   PROXY=http://proxy:8080 ./setup.sh         # reach check through a proxy
#   TRUST_HOST_CA=1 ./setup.sh                 # network inspects TLS, host trusts its CA
#   FORCE=1 ./setup.sh                         # start even if the reach check fails
set -euo pipefail
cd "$(dirname "$0")"
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || die "Docker is not installed (https://docs.docker.com/engine/install/)"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is missing (the docker-compose-plugin package)"
command -v curl >/dev/null || die "curl is missing"
command -v openssl >/dev/null || die "openssl is missing"

BIND_ADDR=${BIND_ADDR:-127.0.0.1}
WUZAPI_PORT=${WUZAPI_PORT:-8080}
case "$BIND_ADDR" in
  0.0.0.0|::|"") die "refusing BIND_ADDR=$BIND_ADDR: WuzAPI must not listen on every interface. Use 127.0.0.1 or this server's private IP." ;;
esac

if [ "$BIND_ADDR" != 127.0.0.1 ] && command -v ip >/dev/null; then
  ip -o addr show | grep -qw "inet $BIND_ADDR" \
    || die "BIND_ADDR=$BIND_ADDR is not an address of this server (ip -o addr show lists them)."
fi

say "1/4 Can this server reach WhatsApp?"
CHECK=""
for c in ./check-whatsapp-reach.sh ../../scripts/check-whatsapp-reach.sh; do [ -x "$c" ] && { CHECK=$c; break; }; done
if [ -z "$CHECK" ]; then
  echo "check-whatsapp-reach.sh not found next to setup.sh; skipping (copy it here to enable)."
elif ! env -u WUZAPI_URL -u WEBHOOK_URL "$CHECK"; then
  [ "${FORCE:-0}" = 1 ] || die "WhatsApp is not reachable from here (see above). Fix the network, or FORCE=1 to start anyway."
  echo "FORCE=1: starting despite failed checks."
fi

say "2/4 Secrets (.env, readable only by you)"
umask 077
if [ ! -f .env ]; then
  {
    echo "WUZAPI_ADMIN_TOKEN=$(openssl rand -hex 24)"
    echo "WUZAPI_GLOBAL_ENCRYPTION_KEY=$(openssl rand -hex 16)"
    echo "WUZAPI_GLOBAL_HMAC_KEY=$(openssl rand -hex 32)"
  } > .env
  echo "generated .env"
else
  echo ".env exists, keeping it (the encryption key must not change once a session is linked)"
fi
chmod 600 .env
# Settings that may change between runs are always rewritten.
sed -i.bak -e '/^BIND_ADDR=/d' -e '/^WUZAPI_PORT=/d' .env && rm -f .env.bak
printf 'BIND_ADDR=%s\nWUZAPI_PORT=%s\n' "$BIND_ADDR" "$WUZAPI_PORT" >> .env

say "3/4 Start WuzAPI"
FILES=(-f docker-compose.yml)
[ "${TRUST_HOST_CA:-0}" = 1 ] && FILES+=(-f docker-compose.ca.yml)
docker compose "${FILES[@]}" --env-file .env up -d \
  || die "docker compose could not start WuzAPI (above). Port $WUZAPI_PORT busy, or $BIND_ADDR not bindable."
URL="http://$BIND_ADDR:$WUZAPI_PORT"
for i in $(seq 1 30); do curl -fsS -m 2 "$URL/health" >/dev/null 2>&1 && break; sleep 2; done
curl -fsS -m 2 "$URL/health" >/dev/null 2>&1 || die "WuzAPI did not come up on $URL: docker compose logs wuzapi"
ADMIN=$(sed -n 's/^WUZAPI_ADMIN_TOKEN=//p' .env)
code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 -H "Authorization: $ADMIN" "$URL/admin/users")
[ "$code" = 200 ] || die "WuzAPI is up but the admin token is refused (HTTP $code)"
echo "WuzAPI healthy on $URL, admin API answers"

say "4/4 Connect the app"
cat <<EOF
Put these in the app's .env (the app creates its WuzAPI user, sets the webhook
and shows the QR in its console on boot):

  WUZAPI_ADMIN_TOKEN=$ADMIN
  WUZAPI_URL=<see below>
  PUBLIC_WEBHOOK_URL=<the app's URL as seen FROM THIS SERVER>/api/webhook

Then run, on this server, after the app has started:
  WUZAPI_URL=$URL WUZAPI_USER_TOKEN=<app's token> WEBHOOK_URL=<webhook> $CHECK
EOF
if [ "$BIND_ADDR" = 127.0.0.1 ]; then
  cat <<EOF

WuzAPI only listens on this server's loopback. From the app machine, open a tunnel
and keep it running (autossh or a systemd unit for permanence):
  ssh -N -L $WUZAPI_PORT:127.0.0.1:$WUZAPI_PORT $(id -un)@$(hostname -f 2>/dev/null || hostname)
and use WUZAPI_URL=http://127.0.0.1:$WUZAPI_PORT on the app machine.
EOF
else
  cat <<EOF

WuzAPI listens on $BIND_ADDR. Docker-published ports BYPASS ufw/firewalld, so
restrict them in the DOCKER-USER chain (run as root, and persist it):
EOF
  if [ -n "${ALLOW_FROM:-}" ]; then
    cat <<EOF
  iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport $WUZAPI_PORT ! -s $ALLOW_FROM -j DROP
EOF
  else
    echo "  (set ALLOW_FROM=<app server IP> and rerun to print the exact rule)"
  fi
  echo "and use WUZAPI_URL=$URL on the app server."
fi

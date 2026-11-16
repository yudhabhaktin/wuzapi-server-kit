#!/usr/bin/env bash
# Run WuzAPI as a native systemd service: no Docker, no firewall side effects.
# Checks WhatsApp reachability, installs a checksum-verified binary, creates a
# locked-down service user and unit, generates secrets once. Safe to rerun.
#
#   sudo ./setup-native.sh                                     # loopback (SSH tunnel)
#   sudo BIND_ADDR=10.1.2.3 ALLOW_FROM=10.1.2.50 ./setup-native.sh
#   sudo PROXY=http://proxy:8080 ./setup-native.sh             # reach check via proxy
#   sudo FORCE=1 ./setup-native.sh                             # start despite failed checks
#   sudo ./setup-native.sh uninstall                           # stop and remove (keeps data)
set -euo pipefail
cd "$(dirname "$0")"
KIT_TAG=${KIT_TAG:-v1.2.0}
KIT_URL="https://github.com/yudhabhaktin/wuzapi-server-kit/releases/download/$KIT_TAG"
SVC=wuzapi; BIN_DIR=/opt/wuzapi; DATA=/var/lib/wuzapi; ETC=/etc/wuzapi; ENVF=$ETC/wuzapi.env
UNIT=/etc/systemd/system/$SVC.service
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run with sudo: sudo $0 $*"
command -v systemctl >/dev/null || die "systemd is required"
for c in curl openssl sha256sum; do command -v $c >/dev/null || die "$c is missing (apt install $c)"; done

if [ "${1:-}" = uninstall ]; then
  systemctl disable --now $SVC 2>/dev/null || true
  rm -f "$UNIT"; systemctl daemon-reload
  echo "Removed the service. Kept: $DATA (linked session) and $ENVF (secrets)."
  echo "Delete them too, to forget the WhatsApp link: rm -rf $DATA $ETC $BIN_DIR; userdel $SVC"
  exit 0
fi

BIND_ADDR=${BIND_ADDR:-127.0.0.1}
WUZAPI_PORT=${WUZAPI_PORT:-8080}
case "$BIND_ADDR" in
  0.0.0.0|::|"") die "refusing BIND_ADDR=$BIND_ADDR: WuzAPI must not listen on every interface. Use 127.0.0.1 or this server's private IP." ;;
esac
if [ "$BIND_ADDR" != 127.0.0.1 ] && command -v ip >/dev/null; then
  ip -o addr show | grep -qw "inet $BIND_ADDR" || die "BIND_ADDR=$BIND_ADDR is not an address of this server (ip -o -4 addr show)."
fi
if command -v ss >/dev/null && ! systemctl is-active -q $SVC; then
  ss -Hltn "( sport = :$WUZAPI_PORT )" | grep -q . && die "port $WUZAPI_PORT is already in use: ss -ltnp | grep :$WUZAPI_PORT, or set WUZAPI_PORT"
fi
case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; *) die "unsupported CPU $(uname -m)" ;;
esac

say "1/5 Can this server reach WhatsApp?"
if [ -x ./check-whatsapp-reach.sh ]; then
  if ! env -u WUZAPI_URL -u WEBHOOK_URL ./check-whatsapp-reach.sh; then
    [ "${FORCE:-0}" = 1 ] || die "WhatsApp is not reachable from here (see above). Fix the network, or FORCE=1."
    echo "FORCE=1: continuing."
  fi
else echo "check-whatsapp-reach.sh not found next to this script; skipping."; fi

say "2/5 WuzAPI binary (linux-$ARCH, checksum-verified)"
B=wuzapi-linux-$ARCH
[ -f "$B" ] || curl -fsSL -o "$B" "$KIT_URL/$B"
[ -f SHA256SUMS-wuzapi ] || curl -fsSL -o SHA256SUMS-wuzapi "$KIT_URL/SHA256SUMS-wuzapi"
grep " $B\$" SHA256SUMS-wuzapi | sha256sum -c - >/dev/null || die "checksum mismatch for $B: delete it and rerun"
install -d -m 755 -o root -g root $BIN_DIR
install -m 755 -o root -g root "$B" $BIN_DIR/wuzapi
echo "installed $BIN_DIR/wuzapi ($("$BIN_DIR/wuzapi" -version 2>/dev/null | head -1 || echo v?))"

say "3/5 Service user and folders"
id $SVC >/dev/null 2>&1 || useradd --system --home-dir $DATA --shell /usr/sbin/nologin $SVC
install -d -m 700 -o $SVC -g $SVC $DATA
install -d -m 700 -o $SVC -g $SVC $BIN_DIR/files     # WuzAPI writes downloaded media next to its binary
install -d -m 700 -o root -g root $ETC
echo "user $SVC; data $DATA (700); binary dir root-owned, only $BIN_DIR/files writable"

say "4/5 Secrets ($ENVF, root only)"
umask 077
if [ ! -f $ENVF ]; then
  {
    echo "WUZAPI_ADMIN_TOKEN=$(openssl rand -hex 24)"
    echo "WUZAPI_GLOBAL_ENCRYPTION_KEY=$(openssl rand -hex 16)"
    echo "WUZAPI_GLOBAL_HMAC_KEY=$(openssl rand -hex 32)"
  } > $ENVF
  echo "generated"
else echo "kept (the encryption key must not change once a session is linked)"; fi
sed -i -e '/^WUZAPI_ADDRESS=/d' -e '/^WUZAPI_PORT=/d' -e '/^WEBHOOK_FORMAT=/d' -e '/^TZ=/d' -e '/^SESSION_DEVICE_NAME=/d' $ENVF
cat >> $ENVF <<EOF
WUZAPI_ADDRESS=$BIND_ADDR
WUZAPI_PORT=$WUZAPI_PORT
WEBHOOK_FORMAT=json
TZ=${TZ:-Asia/Jakarta}
SESSION_DEVICE_NAME=${SESSION_DEVICE_NAME:-WA Demo}
EOF
chmod 600 $ENVF; chown root:root $ENVF

say "5/5 systemd service"
cat > $UNIT <<EOF
[Unit]
Description=WuzAPI WhatsApp gateway
Documentation=https://github.com/yudhabhaktin/wuzapi-server-kit
After=network-online.target
Wants=network-online.target

[Service]
User=$SVC
Group=$SVC
EnvironmentFile=$ENVF
WorkingDirectory=$DATA
ExecStart=$BIN_DIR/wuzapi -datadir $DATA -logtype json
Restart=on-failure
RestartSec=5
UMask=0077
LimitNOFILE=65536
# Hardening: read-only system, no privilege, network only
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=$DATA $BIN_DIR/files
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable -q $SVC
systemctl restart $SVC
URL="http://$BIND_ADDR:$WUZAPI_PORT"
for i in $(seq 1 30); do curl -fsS -m 2 "$URL/health" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS -m 2 "$URL/health" >/dev/null 2>&1 || { journalctl -u $SVC -n 30 --no-pager; die "WuzAPI did not come up on $URL (log above)"; }
ADMIN=$(sed -n 's/^WUZAPI_ADMIN_TOKEN=//p' $ENVF)
code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 -H "Authorization: $ADMIN" "$URL/admin/users")
[ "$code" = 200 ] || die "WuzAPI is up but refuses the admin token (HTTP $code)"
echo "running: systemctl status $SVC · logs: journalctl -u $SVC -f"
echo "WuzAPI healthy on $URL, admin API answers"

say "Connect the app"
cat <<EOF
In the app's settings:
  WUZAPI_URL=$URL
  WUZAPI_ADMIN_TOKEN=$ADMIN
  PUBLIC_WEBHOOK_URL=<the app's URL as reachable FROM THIS SERVER>/api/webhook
(Read the token again any time: sudo grep ADMIN $ENVF)
EOF
if [ "$BIND_ADDR" = 127.0.0.1 ]; then
  echo; echo "Loopback only. From the app machine: ssh -N -L $WUZAPI_PORT:127.0.0.1:$WUZAPI_PORT $(logname 2>/dev/null || echo user)@<this server>"
else
  echo
  if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    echo "ufw is active. Allow only the app server:"
    echo "  sudo ufw allow from ${ALLOW_FROM:-<app server IP>} to $BIND_ADDR port $WUZAPI_PORT proto tcp"
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    echo "firewalld is active. Allow only the app server:"
    echo "  sudo firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=${ALLOW_FROM:-<app server IP>} port port=$WUZAPI_PORT protocol=tcp accept' && sudo firewall-cmd --reload"
  else
    echo "No host firewall is active, so any machine that can route to $BIND_ADDR reaches port $WUZAPI_PORT."
    echo "Restrict it (to ${ALLOW_FROM:-<app server IP>}) with ufw, or ask IT to filter it on the network."
  fi
fi

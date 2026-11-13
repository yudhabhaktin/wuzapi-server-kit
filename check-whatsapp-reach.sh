#!/usr/bin/env bash
# Can this server reach WhatsApp the way WuzAPI (whatsmeow) needs to?
# Run it on the server BEFORE installing WuzAPI, and again after.
#
#   ./scripts/check-whatsapp-reach.sh
#   PROXY=http://proxy.corp:8080 ./scripts/check-whatsapp-reach.sh        # if egress needs a proxy
#   WUZAPI_URL=http://127.0.0.1:8080 WUZAPI_USER_TOKEN=... \
#   WEBHOOK_URL=https://app.example/api/webhook ./scripts/check-whatsapp-reach.sh
#   SKIP_WHATSAPP=1 WUZAPI_URL=http://10.0.0.5:8080 WUZAPI_USER_TOKEN=... ./scripts/check-whatsapp-reach.sh
#                       # on the APP server: only "can the app reach WuzAPI?"
#
# Hosts come from whatsmeow itself: the chat link is wss://web.whatsapp.com/ws/chat,
# media goes to mmg(-fallback).whatsapp.net. Exit code = number of failures.
set -u
read -r -a HOSTS <<<"${HOSTS:-web.whatsapp.com mmg.whatsapp.net mmg-fallback.whatsapp.net static.whatsapp.net}"
fail=0; warn=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
note() { printf '  \033[33mWARN\033[0m %s\n' "$*"; warn=$((warn+1)); }
CURL=(curl -sS --max-time 10); [ -n "${PROXY:-}" ] && CURL+=(--proxy "$PROXY")

resolve() { (getent ahostsv4 "$1" 2>/dev/null || dig +short "$1" 2>/dev/null || nslookup "$1" 2>/dev/null) \
            | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '^127\.0\.0\.53$' | head -1; }
private() { [[ $1 =~ ^(0\.|127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.64\.) ]]; }

if [ "${SKIP_WHATSAPP:-0}" = 1 ]; then
  echo "1-4. WhatsApp reachability: skipped (SKIP_WHATSAPP=1, run them on the WuzAPI server)"
else
echo "1. DNS (a sinkhole answers 0.0.0.0, 127.x or a private address)"
for h in "${HOSTS[@]}"; do
  ip=$(resolve "$h")
  if [ -z "$ip" ]; then bad "$h does not resolve"
  elif private "$ip" && [ -z "${PROXY:-}" ]; then bad "$h -> $ip (sinkholed or internal)"
  else ok "$h -> $ip"; fi
done

echo "2. TCP 443"
if [ -n "${PROXY:-}" ]; then note "skipped: egress goes through $PROXY (step 4 tests it end to end)"
else for h in "${HOSTS[@]}"; do
  if timeout 6 bash -c "exec 3<>/dev/tcp/$h/443" 2>/dev/null; then ok "$h:443 open"; else bad "$h:443 blocked or timing out"; fi
done; fi

echo "3. TLS issuer (must be DigiCert; anything else means TLS inspection, which breaks WuzAPI)"
for h in "${HOSTS[@]}"; do
  iss=$("${CURL[@]}" -o /dev/null -v "https://$h/" 2>&1 | sed -n 's/^\*  *issuer: //p' | head -1)
  # openssl only as a fallback for a curl that doesn't print the issuer, and only
  # when there's no proxy: openssl would go direct and pass a check the proxy fails.
  [ -z "$iss" ] && [ -z "${PROXY:-}" ] && iss=$(echo | timeout 8 openssl s_client -connect "$h:443" -servername "$h" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null)
  if   [ -z "$iss" ]; then bad "$h: no TLS handshake"
  elif grep -qi digicert <<<"$iss"; then ok "$h: $iss"
  else bad "$h: issued by '$iss' -> TLS inspection. Ask IT to bypass *.whatsapp.net and *.whatsapp.com"; fi
done

echo "4. WebSocket upgrade on the chat endpoint (needs HTTP 101)"
code=$("${CURL[@]}" --http1.1 --max-time 6 -o /dev/null -w '%{http_code}' \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'Origin: https://web.whatsapp.com' \
  https://web.whatsapp.com/ws/chat 2>/dev/null)
case "$code" in
  101) ok "wss://web.whatsapp.com/ws/chat -> 101 Switching Protocols" ;;
  000) bad "no response: blocked, or a proxy that drops WebSocket upgrades" ;;
  *)   bad "HTTP $code: something in between refuses the upgrade (proxy or firewall policy)" ;;
esac
fi

if [ -n "${WUZAPI_URL:-}" ] && [ -n "${WUZAPI_USER_TOKEN:-}" ]; then
  echo "5. WuzAPI session"
  s=$(curl -sS --max-time 5 -H "Token: $WUZAPI_USER_TOKEN" "$WUZAPI_URL/session/status" 2>&1)
  c=$(grep -oE '"connected": *(true|false)' <<<"$s" | grep -oE 'true|false')
  l=$(grep -oE '"loggedIn": *(true|false)' <<<"$s" | grep -oE 'true|false')
  if   [ "$c" = true ] && [ "$l" = true ]; then ok "connected and logged in ($(grep -oE '"jid":"[^"]*"' <<<"$s"))"
  elif [ "$c" = true ]; then note "connected to WhatsApp but not linked: scan the QR (GET /session/qr)"
  elif [ -n "$c" ]; then bad "WuzAPI is up but NOT connected to WhatsApp: POST /session/connect, then read its log"
  elif grep -q '"code":401' <<<"$s"; then bad "WuzAPI answered but refused the token (401): use the app's WUZAPI_USER_TOKEN"
  else bad "WuzAPI not answering at $WUZAPI_URL: $s"; fi
fi

if [ -n "${WEBHOOK_URL:-}" ]; then
  echo "6. Webhook back to the app (any HTTP status means reachable; WuzAPI signs real calls)"
  code=$(curl -sS --max-time 8 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' "$WEBHOOK_URL" 2>/dev/null)
  if [ "$code" = 000 ]; then bad "$WEBHOOK_URL unreachable from this server"; else ok "$WEBHOOK_URL answered HTTP $code"; fi
fi

echo; if [ $fail -eq 0 ]; then echo "RESULT: reachable ($warn warning(s))"; else echo "RESULT: $fail check(s) failed"; fi
exit $fail

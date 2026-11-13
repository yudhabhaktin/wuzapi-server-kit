# WuzAPI on a dedicated Linux server

Runs only WuzAPI (the WhatsApp link). The app runs elsewhere, reaches WuzAPI
privately, and receives messages on its webhook. The app itself creates its
WuzAPI user, sets the webhook and shows the QR in its console on boot.

## 1. Download the kit on the server

```bash
curl -fLO https://github.com/yudhabhaktin/wuzapi-server-kit/releases/latest/download/wuzapi-kit.tgz
curl -fLO https://github.com/yudhabhaktin/wuzapi-server-kit/releases/latest/download/wuzapi-kit.tgz.sha256
sha256sum -c wuzapi-kit.tgz.sha256 && tar -xzf wuzapi-kit.tgz && cd wuzapi
```

(`wget` works too.) The server needs Docker Engine with the Compose plugin, `curl` and
`openssl`, and outbound HTTPS to `github.com` for this download and to Docker Hub
for the WuzAPI image.

On a Windows app server, download only the check script:

```powershell
Invoke-WebRequest https://github.com/yudhabhaktin/wuzapi-server-kit/releases/latest/download/check-whatsapp-reach.ps1 -OutFile check-whatsapp-reach.ps1
```

## 2. Run setup on the server

```bash
./setup.sh
```

It (1) checks the server can reach WhatsApp and stops if not, (2) generates
`.env` with the admin token and keys (mode 600), (3) starts WuzAPI and checks
`/health` and the admin API, (4) prints what to put in the app. Safe to rerun:
existing secrets are kept, because changing the encryption key loses the
linked session.

| Situation | Command |
|---|---|
| App on another network (VPS, your laptop) | `./setup.sh` — loopback only; the app connects through an SSH tunnel |
| App server on the same private network | `BIND_ADDR=<this server's private IP> ALLOW_FROM=<app server IP> ./setup.sh` |
| Egress through a proxy | add `PROXY=http://proxy:8080` |
| Network inspects TLS and the host trusts IT's CA | add `TRUST_HOST_CA=1` |

`BIND_ADDR=0.0.0.0` is refused: WuzAPI speaks plain HTTP, and its tokens control
the WhatsApp number.

**Firewall:** ports published by Docker bypass `ufw`/`firewalld`. With
`BIND_ADDR` set to a private IP, the script prints the `DOCKER-USER` iptables rule
that admits only `ALLOW_FROM`. Run it as root and persist it
(`iptables-persistent` / `netfilter-persistent save`).

## 3. Point the app at it

In the app's `.env`:

```
WUZAPI_URL=http://127.0.0.1:8080          # through the SSH tunnel, or http://<private IP>:8080
WUZAPI_ADMIN_TOKEN=<printed by setup.sh>
PUBLIC_WEBHOOK_URL=<the app's URL as reachable FROM the WuzAPI server>/api/webhook
```

SSH tunnel from the app machine (keep it running; `autossh -M 0 -N -L ...` restarts it):

```bash
ssh -N -L 8080:127.0.0.1:8080 user@server
```

Start the app, scan the QR in its console with the business phone
(WhatsApp → Linked devices), then confirm everything from the server:

```bash
WUZAPI_URL=http://127.0.0.1:8080 WUZAPI_USER_TOKEN=<app's user token> \
WEBHOOK_URL=<webhook URL> ./check-whatsapp-reach.sh
```

Healthy: every check PASS, step 5 `connected and logged in`.

## Layout: WuzAPI on Linux, the app on an IIS server in the same network

```
 WhatsApp ◀──(1) wss 443──  Linux: WuzAPI :8080  ◀──(2) API, token──  IIS: app
                                   └──────────(3) webhook POST, HMAC──────▶
```

All three paths must work. Check each from the side that opens it:

| Path | Run on | Command |
|---|---|---|
| (1) Linux → WhatsApp | Linux | `./check-whatsapp-reach.sh` (all PASS) |
| (2) IIS → WuzAPI | IIS | `powershell -ExecutionPolicy Bypass -File .\check-whatsapp-reach.ps1 -SkipWhatsApp -WuzapiUrl http://<linux IP>:8080 -WuzapiToken <user token>` |
| (3) Linux → IIS webhook | Linux | `SKIP_WHATSAPP=1 WEBHOOK_URL=<webhook> ./check-whatsapp-reach.sh` (any HTTP status passes) |

Steps:

1. On Linux: `BIND_ADDR=<linux private IP> ALLOW_FROM=<IIS IP> ./setup.sh`, then run
   the printed `iptables -I DOCKER-USER ...` rule as root and persist it.
2. Open TCP 8080 from the IIS server to the Linux server in any firewall between
   them (Windows outbound rarely blocks; a network firewall may).
3. Give the app `WUZAPI_URL=http://<linux private IP>:8080`, the admin token, and a
   webhook URL that the **Linux server** can reach: the IIS server's internal name
   or IP with the site's binding, not the public Akamai name (WAF rules and
   egress can drop it).
4. Start the app, scan the QR in its console, then run path checks (1)–(3).

WuzAPI → app traffic is plain HTTP inside the network unless the IIS binding is
HTTPS; the webhook is HMAC-signed and the API needs the token either way.

## Operating it

| Task | Command |
|---|---|
| Logs | `docker compose logs -f wuzapi` |
| Restart | `docker compose --env-file .env restart` |
| Upgrade | change the image tag in `docker-compose.yml`, then `./setup.sh` |
| Back up the linked session | `docker run --rm -v wuzapi-server_wuzapi_data:/d -v $PWD:/b alpine tar czf /b/wuzapi-data.tgz -C /d .` (plus `.env`) |
| Unlink | the app's console, or WhatsApp → Linked devices on the phone |

# WuzAPI on a dedicated Linux server

Runs only WuzAPI (the WhatsApp link), natively under systemd or in Docker. The app runs elsewhere, reaches WuzAPI
privately, and receives messages on its webhook. The app itself creates its
WuzAPI user, sets the webhook and shows the QR in its console on boot.

## 1. Download the kit on the server

Work in a folder you own (not `/` or `/opt`):

```bash
mkdir -p ~/wuzapi-kit && cd ~/wuzapi-kit
curl -fLO https://github.com/yudhabhaktin/wuzapi-server-kit/releases/latest/download/wuzapi-kit.tgz
curl -fLO https://github.com/yudhabhaktin/wuzapi-server-kit/releases/latest/download/wuzapi-kit.tgz.sha256
sha256sum -c wuzapi-kit.tgz.sha256 && tar -xzf wuzapi-kit.tgz && cd wuzapi
./check-whatsapp-reach.sh
```

On a Windows app server, download only the check script:

```powershell
Invoke-WebRequest https://github.com/yudhabhaktin/wuzapi-server-kit/releases/latest/download/check-whatsapp-reach.ps1 -OutFile check-whatsapp-reach.ps1
```

## 2. Install WuzAPI: native (recommended) or Docker

**Native systemd service: `setup-native.sh`.** No Docker. Use it on a server that
runs other things: it leaves the firewall untouched, so `ufw`/`firewalld` rules
keep working. It downloads the WuzAPI binary for the CPU from this release,
verifies its checksum, and runs it as a locked-down service (`systemd-analyze
security` rates it 3.1, OK).

```bash
sudo ./setup-native.sh                                              # loopback only (SSH tunnel)
sudo BIND_ADDR=<this server's private IP> ALLOW_FROM=<app server IP> ./setup-native.sh
```

| Path | Holds |
|---|---|
| `/opt/wuzapi/wuzapi` | the binary (root-owned) |
| `/var/lib/wuzapi` | the linked session and database (service user only) |
| `/etc/wuzapi/wuzapi.env` | admin token and keys (root only, `600`) |

Logs: `journalctl -u wuzapi -f` · status: `systemctl status wuzapi` · remove:
`sudo ./setup-native.sh uninstall` (keeps the session and secrets until you delete them).

**Docker: `setup.sh`.** For a server dedicated to WuzAPI that already has Docker
Engine and the Compose plugin. Docker rewrites iptables and its published ports
bypass `ufw`; the script prints the `DOCKER-USER` rule that compensates.

```bash
./setup.sh                                                          # loopback only
BIND_ADDR=<private IP> ALLOW_FROM=<app server IP> ./setup.sh
```

Both scripts first check that WhatsApp is reachable and stop if not, generate
the secrets once (rerunning keeps them: a new encryption key loses the linked
session), refuse `0.0.0.0` (WuzAPI speaks plain HTTP and its tokens control the
WhatsApp number), verify `/health` and the admin API, and print what the app needs.

| Option | Native | Docker |
|---|---|---|
| Egress through a proxy | `PROXY=http://proxy:8080` | same |
| Network inspects TLS | the host trust store applies automatically | `TRUST_HOST_CA=1` |
| Start despite a failed check | `FORCE=1` | same |

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

1. On Linux: `sudo BIND_ADDR=<linux private IP> ALLOW_FROM=<IIS IP> ./setup-native.sh`,
   then run the firewall rule it prints (`ufw allow from <IIS IP> ...`). With Docker
   instead: `./setup.sh`, and the printed `iptables -I DOCKER-USER ...` rule, persisted.
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

| Task | Native (`setup-native.sh`) | Docker (`setup.sh`) |
|---|---|---|
| Logs | `journalctl -u wuzapi -f` | `docker compose logs -f wuzapi` |
| Restart | `sudo systemctl restart wuzapi` | `docker compose --env-file .env restart` |
| Upgrade | rerun with a newer kit: `sudo KIT_TAG=<tag> ./setup-native.sh` | change the image tag in `docker-compose.yml`, then `./setup.sh` |
| Admin token | `sudo grep ADMIN /etc/wuzapi/wuzapi.env` | `grep ADMIN .env` |
| Back up the linked session | `sudo tar czf wuzapi-backup.tgz /var/lib/wuzapi /etc/wuzapi` | `docker run --rm -v wuzapi-server_wuzapi_data:/d -v $PWD:/b alpine tar czf /b/wuzapi-data.tgz -C /d .` (plus `.env`) |
| Remove | `sudo ./setup-native.sh uninstall` | `docker compose --env-file .env down` |
| Unlink the number | the app's console, or WhatsApp → Linked devices on the phone | same |

A backup holds the device keys of the linked number: keep it encrypted and on
the server's own backup, never in chat or email.

## On a desktop (Windows, macOS) without Docker

The release also carries `wuzapi-windows-amd64.exe` and `wuzapi-darwin-<cpu>`, for
running WuzAPI next to an app on a developer machine. `wuzapi-local.mjs` (Node 24,
no other dependency) does it: run `node wuzapi-local.mjs` in a folder whose `.env`
holds `WUZAPI_ADMIN_TOKEN`, `WUZAPI_GLOBAL_ENCRYPTION_KEY` and
`WUZAPI_GLOBAL_HMAC_KEY`. It downloads the binary for the OS and CPU, verifies it
against `SHA256SUMS-wuzapi`, and starts it on `127.0.0.1` (data in `.wuzapi/`).
The `whatsapp-demo` app ships the same script as `npm run wuzapi`.

Licences of the redistributed WuzAPI binary: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

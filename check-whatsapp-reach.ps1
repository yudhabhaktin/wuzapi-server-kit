<#
  Can this Windows server reach WhatsApp the way WuzAPI (whatsmeow) needs to?
  Run it on the server BEFORE installing WuzAPI, and again after.
  Works in Windows PowerShell 5.1 (Windows Server default) and PowerShell 7.

    powershell -ExecutionPolicy Bypass -File .\check-whatsapp-reach.ps1
    ... -Proxy http://proxy.corp:8080                        # if egress needs a proxy
    ... -WuzapiUrl http://127.0.0.1:8080 -WuzapiToken <user token> -WebhookUrl https://app/api/webhook
    ... -SkipWhatsApp -WuzapiUrl http://10.0.0.5:8080 -WuzapiToken <token>
                   # on the APP (IIS) server: only "can the app reach WuzAPI?"

  Hosts come from whatsmeow: the chat link is wss://web.whatsapp.com/ws/chat, media goes
  to mmg(-fallback).whatsapp.net. Exit code = number of failures.
#>
param(
  [string[]]$Hosts = @('web.whatsapp.com', 'mmg.whatsapp.net', 'mmg-fallback.whatsapp.net', 'static.whatsapp.net'),
  [string]$Proxy = '',
  [string]$WuzapiUrl = '',
  [string]$WuzapiToken = '',
  [string]$WebhookUrl = '',
  [switch]$SkipWhatsApp
)
$ErrorActionPreference = 'Stop'
$script:fail = 0; $script:warn = 0
function Pass($m) { Write-Host '  PASS ' -ForegroundColor Green -NoNewline; Write-Host $m }
function Fail($m) { Write-Host '  FAIL ' -ForegroundColor Red -NoNewline; Write-Host $m; $script:fail++ }
function Warn($m) { Write-Host '  WARN ' -ForegroundColor Yellow -NoNewline; Write-Host $m; $script:warn++ }

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
$webProxy = $null
if ($Proxy) { $webProxy = New-Object System.Net.WebProxy($Proxy) }

function Test-Private([string]$ip) {
  return $ip -match '^(0\.|127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.64\.)'
}

if ($SkipWhatsApp) { Write-Host '1-4. WhatsApp reachability: skipped (-SkipWhatsApp, run them on the WuzAPI server)' }
else {
Write-Host '1. DNS (a sinkhole answers 0.0.0.0, 127.x or a private address)'
foreach ($h in $Hosts) {
  try {
    $ip = ([System.Net.Dns]::GetHostAddresses($h) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1).IPAddressToString
    if (-not $ip) { Fail "$h has no IPv4 address" }
    elseif ((Test-Private $ip) -and -not $Proxy) { Fail "$h -> $ip (sinkholed or internal)" }
    else { Pass "$h -> $ip" }
  } catch { Fail "$h does not resolve" }
}

Write-Host '2. TCP 443'
if ($Proxy) { Warn "skipped: egress goes through $Proxy (step 4 tests it end to end)" }
else {
  foreach ($h in $Hosts) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
      $t = $c.ConnectAsync($h, 443)
      if ($t.Wait(6000) -and $c.Connected) { Pass "${h}:443 open" } else { Fail "${h}:443 blocked or timing out" }
    } catch { Fail "${h}:443 blocked or timing out" } finally { $c.Close() }
  }
}

Write-Host '3. TLS issuer (must be DigiCert; anything else means TLS inspection, which breaks WuzAPI)'
# Synchronous SslStream: the validation callback then runs on this thread, which
# PowerShell requires (a script block can't run on a thread-pool thread).
function Get-TlsIssuer([string]$h) {
  $tcp = New-Object System.Net.Sockets.TcpClient
  try {
    if ($webProxy) {
      $pu = [Uri]$Proxy
      if (-not $tcp.ConnectAsync($pu.Host, $pu.Port).Wait(6000)) { return $null }
      $raw = $tcp.GetStream(); $raw.ReadTimeout = 8000
      $req = [Text.Encoding]::ASCII.GetBytes("CONNECT ${h}:443 HTTP/1.1`r`nHost: ${h}:443`r`n`r`n")
      $raw.Write($req, 0, $req.Length)
      $buf = New-Object byte[] 4096; $n = $raw.Read($buf, 0, $buf.Length)
      $line = [Text.Encoding]::ASCII.GetString($buf, 0, $n).Split("`n")[0]
      if ($line -notmatch ' 200 ') { return "proxy refused CONNECT: $($line.Trim())" }
    } elseif (-not $tcp.ConnectAsync($h, 443).Wait(6000)) { return $null }
    $script:seen = $null
    $cb = [System.Net.Security.RemoteCertificateValidationCallback] { param($sender, $cert, $chain, $errors) $script:seen = $cert; return $true }
    $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, $cb)
    $ssl.ReadTimeout = 8000; $ssl.WriteTimeout = 8000
    $ssl.AuthenticateAsClient($h)
    $cert = $ssl.RemoteCertificate; if (-not $cert) { $cert = $script:seen }
    $ssl.Dispose()
    if ($cert) { return $cert.Issuer } else { return $null }
  } catch { return $null } finally { $tcp.Close() }
}
foreach ($h in $Hosts) {
  $issuer = Get-TlsIssuer $h
  if (-not $issuer) { Fail "${h}: no TLS handshake" }
  elseif ($issuer -like 'proxy refused*') { Fail "${h}: $issuer" }
  elseif ($issuer -match 'DigiCert') { Pass "${h}: $issuer" }
  else { Fail "${h}: issued by '$issuer' -> TLS inspection. Ask IT to bypass *.whatsapp.net and *.whatsapp.com" }
}

Write-Host '4. WebSocket upgrade on the chat endpoint (needs 101 Switching Protocols)'
$ws = New-Object System.Net.WebSockets.ClientWebSocket
$ws.Options.SetRequestHeader('Origin', 'https://web.whatsapp.com')
if ($webProxy) { $ws.Options.Proxy = $webProxy }
$cts = New-Object System.Threading.CancellationTokenSource(8000)
try {
  $null = $ws.ConnectAsync([Uri]'wss://web.whatsapp.com/ws/chat', $cts.Token).GetAwaiter().GetResult()
  if ($ws.State -eq 'Open') { Pass 'wss://web.whatsapp.com/ws/chat -> 101 Switching Protocols' } else { Fail "socket state $($ws.State)" }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  Fail "refused or blocked: $($e.Message)"
} finally { $ws.Abort(); $ws.Dispose() }
}

if ($WuzapiUrl -and $WuzapiToken) {
  Write-Host '5. WuzAPI session'
  try {
    $s = Invoke-RestMethod -Uri "$WuzapiUrl/session/status" -Headers @{ Token = $WuzapiToken } -TimeoutSec 5
    $d = $s.data
    if ($d.connected -and $d.loggedIn) { Pass "connected and logged in ($($d.jid))" }
    elseif ($d.connected) { Warn 'connected to WhatsApp but not linked: scan the QR (GET /session/qr)' }
    else { Fail 'WuzAPI is up but NOT connected to WhatsApp: POST /session/connect, then read its log' }
  } catch {
    $resp = $_.Exception.Response
    if ($resp -and [int]$resp.StatusCode -eq 401) { Fail "WuzAPI answered but refused the token (401): use the app's WUZAPI_USER_TOKEN" }
    else { Fail "WuzAPI not answering at ${WuzapiUrl}: $($_.Exception.Message)" }
  }
}

if ($WebhookUrl) {
  Write-Host '6. Webhook back to the app (any HTTP status means reachable; WuzAPI signs real calls)'
  try {
    $r = Invoke-WebRequest -Uri $WebhookUrl -Method Post -Body '{}' -ContentType 'application/json' -TimeoutSec 8 -UseBasicParsing
    Pass "$WebhookUrl answered HTTP $([int]$r.StatusCode)"
  } catch {
    $resp = $_.Exception.Response
    if ($resp) { Pass "$WebhookUrl answered HTTP $([int]$resp.StatusCode)" } else { Fail "$WebhookUrl unreachable from this server" }
  }
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "RESULT: reachable ($($script:warn) warning(s))" } else { Write-Host "RESULT: $($script:fail) check(s) failed" }
exit $script:fail

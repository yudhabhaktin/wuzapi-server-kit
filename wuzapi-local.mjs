// Runs WuzAPI on this machine without Docker (Windows, macOS, Linux).
// Downloads the WuzAPI binary for this OS/CPU from the public wuzapi-server-kit
// release, verifies its SHA-256, and starts it with the settings in .env,
// listening on 127.0.0.1 only. Keep it running while the app runs.
//
//   npm run wuzapi
import { spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const KIT_TAG = process.env.WUZAPI_KIT_TAG ?? 'v1.2.0'
const BASE = `https://github.com/yudhabhaktin/wuzapi-server-kit/releases/download/${KIT_TAG}`
const DIR = '.wuzapi'

const fail = (message) => {
  console.error(`ERROR: ${message}`)
  process.exit(1)
}

if (!existsSync('.env')) fail('no .env here. Run `npm run setup` first, from the repository folder.')
process.loadEnvFile('.env')
for (const key of ['WUZAPI_ADMIN_TOKEN', 'WUZAPI_GLOBAL_ENCRYPTION_KEY', 'WUZAPI_GLOBAL_HMAC_KEY']) {
  if (!process.env[key] || process.env[key].startsWith('replace-with')) fail(`${key} is not set in .env (npm run setup).`)
}

const os = { win32: 'windows', darwin: 'darwin', linux: 'linux' }[process.platform]
const cpu = { x64: 'amd64', arm64: 'arm64' }[process.arch]
if (!os || !cpu) fail(`no WuzAPI build for ${process.platform}/${process.arch}`)
const name = `wuzapi-${os}-${cpu}${os === 'windows' ? '.exe' : ''}`
const bin = join(DIR, name)

async function download(file) {
  const res = await fetch(`${BASE}/${file}`, { redirect: 'follow' })
  if (!res.ok) fail(`download of ${file} failed: HTTP ${res.status} (can this PC reach github.com?)`)
  return Buffer.from(await res.arrayBuffer())
}

const sha256 = (buf) => createHash('sha256').update(buf).digest('hex')

mkdirSync(DIR, { recursive: true })
const sums = (await download('SHA256SUMS-wuzapi')).toString('utf8')
const expected = sums.split('\n').map((l) => l.trim().split(/\s+/)).find(([, f]) => f === name)?.[0]
if (!expected) fail(`${name} is not in the ${KIT_TAG} release`)
if (!existsSync(bin) || sha256(readFileSync(bin)) !== expected) {
  console.log(`Downloading ${name} (${KIT_TAG})...`)
  const buf = await download(name)
  if (sha256(buf) !== expected) fail(`checksum mismatch for ${name}; not running it`)
  writeFileSync(bin, buf)
  if (os !== 'windows') chmodSync(bin, 0o755)
}
console.log(`WuzAPI binary ok: ${bin} (sha256 ${expected.slice(0, 12)}...)`)

const port = process.env.WUZAPI_PORT || new URL(process.env.WUZAPI_URL || 'http://localhost:8080').port || '8080'
const webhook = process.env.PUBLIC_WEBHOOK_URL ?? ''
if (webhook.includes('host.docker.internal')) {
  console.warn(
    `WARNING: PUBLIC_WEBHOOK_URL=${webhook} only works with Docker. Set it to ` +
      `http://localhost:${process.env.APP_PORT || 3000}/api/webhook in .env and restart the app.`,
  )
}

const child = spawn(bin, ['-address', '127.0.0.1', '-port', port, '-datadir', join(DIR, 'data'), '-logtype', 'console'], {
  stdio: 'inherit',
  env: {
    ...process.env,
    WEBHOOK_FORMAT: 'json',
    TZ: process.env.TZ || 'Asia/Jakarta',
    SESSION_DEVICE_NAME: process.env.SESSION_DEVICE_NAME || 'WA Demo',
  },
})
console.log(`WuzAPI starting on http://127.0.0.1:${port}  (Ctrl+C to stop)`)
for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => child.kill(sig))
child.on('exit', (code) => process.exit(code ?? 0))

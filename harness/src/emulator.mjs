// The emulator under test. Host CLI contract (same as msduck
// tests/support/client.mjs): `<bin> --listen 127.0.0.1:0` prints
// `listening on 127.0.0.1:<port>` on stderr once it accepts connections.
//
//   BITSQL_ADDR=host:port   connect to an already running server (no spawn)
//   BITSQL_BIN=path         binary to spawn
//   otherwise               `moon build --target native` at the repo root and
//                           spawn the newest _build/native/**/host/host.exe
import { spawn, execFileSync } from 'node:child_process'
import { readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { repoDir } from './env.mjs'
import { connect, close, tediousConfig } from './client.mjs'

export function emulatorConfig({ host, port }) {
  return tediousConfig({ host, port, password: 'bitsql', tls: false, connectTimeout: 5000, requestTimeout: 15000 })
}

function findHostExe(dir) {
  const found = []
  const visit = d => {
    let entries
    try { entries = readdirSync(d, { withFileTypes: true }) } catch { return }
    for (const e of entries) {
      const p = join(d, e.name)
      if (e.isDirectory()) visit(p)
      else if (e.name === 'host.exe' && d.endsWith('/host')) found.push({ p, t: statSync(p).mtimeMs })
    }
  }
  visit(dir)
  return found.sort((a, b) => b.t - a.t)[0]?.p ?? null
}

let built = null
export function emulatorBinary({ log = () => {} } = {}) {
  if (process.env.BITSQL_BIN) return process.env.BITSQL_BIN
  if (built) return built
  log('building bitsql (moon build --target native)\n')
  try { execFileSync('moon', ['build', '--target', 'native'], { cwd: repoDir, stdio: ['ignore', 'ignore', 'pipe'] }) }
  catch (error) { throw new Error(`moon build failed: ${error.stderr?.toString().split('\n').filter(l => /error/i.test(l)).slice(0, 5).join('\n') || error.message}`) }
  built = findHostExe(join(repoDir, '_build', 'native'))
  if (!built) throw new Error('no host.exe under _build/native after moon build')
  return built
}

// Spawns one server process. Resolves { host, port, stop() } or rejects with
// a "server not available" error when the binary exits or never listens.
export function spawnEmulator({ bin = emulatorBinary(), args = [], timeout = 10000 } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(bin, ['--listen', '127.0.0.1:0', ...args], { stdio: ['ignore', 'ignore', 'pipe'] })
    let logs = ''
    let settled = false
    const fail = message => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      child.kill('SIGKILL')
      reject(new Error(`server not available: ${message}${logs ? `\n${logs.trim().slice(0, 500)}` : ''}`))
    }
    const timer = setTimeout(() => fail(`no "listening on" line within ${timeout} ms`), timeout)
    child.once('error', error => fail(error.message))
    child.once('exit', code => fail(`${bin} exited (${code}) before listening`))
    child.stderr.on('data', data => {
      logs += data.toString()
      const match = logs.match(/listening on 127\.0\.0\.1:(\d+)/)
      if (match && !settled) {
        settled = true
        clearTimeout(timer)
        child.removeAllListeners('exit')
        const stop = () => new Promise(done => {
          if (child.exitCode !== null || child.signalCode !== null) return done()
          child.once('exit', () => done())
          child.kill('SIGTERM')
          setTimeout(() => child.kill('SIGKILL'), 2000).unref()
        })
        resolve({ host: '127.0.0.1', port: Number(match[1]), stop, logs: () => logs })
      }
    })
  })
}

export function fixedAddress(env = process.env) {
  if (!env.BITSQL_ADDR) return null
  const [host, port] = env.BITSQL_ADDR.split(':')
  return { host: host || '127.0.0.1', port: Number(port) }
}

// Probe: can a tedious client log in? Returns null on success or an Error.
export async function probe(address) {
  try { await close(await connect(emulatorConfig(address))); return null }
  catch (error) { return new Error(`server not available: login to ${address.host}:${address.port} failed: ${error.message}`) }
}

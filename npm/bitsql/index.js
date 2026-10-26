'use strict'
// Starts the native bitsql server as a child process. Host CLI contract:
// `<bin> --listen HOST:PORT` prints `listening on HOST:PORT` on stderr once it
// accepts connections (src/host/main.mbt). With `--exit-with-stdin` it exits
// when its stdin pipe closes, so however this process ends (SIGKILL of a test
// worker included), no server outlives it.
const { spawn } = require('node:child_process')
const { join } = require('node:path')

const version = require('./package.json').version
const platformPackage = `bitsql-${process.platform}-${process.arch}`
const logLimit = 64 * 1024

// Servers still running at a normal exit are killed at once.
const running = new Set()
process.on('exit', () => { for (const child of running) child.kill('SIGKILL') })

function binaryPath() {
  if (process.env.BITSQL_BIN) return process.env.BITSQL_BIN
  try {
    return join(require.resolve(`${platformPackage}/package.json`), '..', 'bin', 'bitsql')
  } catch {
    throw new Error(
      `bitsql: no native binary for ${process.platform}-${process.arch} ` +
      `(optional dependency ${platformPackage} is not installed). ` +
      'Set BITSQL_BIN to a bitsql executable, or run the mirek/bitsql container.',
    )
  }
}

function serverArgs(options) {
  const host = options.host ?? '127.0.0.1'
  const args = ['--listen', `${host}:${options.port ?? 0}`, '--exit-with-stdin']
  for (const name of options.databases ?? []) args.push('--database', name)
  if (options.autoCreateDatabases) args.push('--auto-create-databases')
  if (options.tls === false) args.push('--no-tls')
  else if (options.tls && typeof options.tls === 'object') args.push('--tls-cert', options.tls.cert, '--tls-key', options.tls.key)
  if (options.httpCa !== undefined) args.push('--http-ca', options.httpCa)
  if (options.maxRequestWork !== undefined) args.push('--max-request-work', String(options.maxRequestWork))
  if (options.spinUs !== undefined) args.push('--spin-us', String(options.spinUs))
  if (options.record !== undefined) args.push('--record', options.record)
  return [...args, ...(options.args ?? [])]
}

function start(options = {}) {
  const bin = options.binary ?? binaryPath()
  const timeout = options.timeout ?? 10000
  const encrypt = options.tls !== false
  const child = spawn(bin, serverArgs(options), { stdio: ['pipe', 'ignore', 'pipe'] })
  let logs = ''
  // Drained for the server's lifetime: a full stderr pipe would block it.
  child.stderr.setEncoding('utf8')
  child.stderr.on('data', data => {
    logs = (logs + data).slice(-logLimit)
    options.onLog?.(data)
  })
  const kill = () => child.kill('SIGKILL')
  running.add(child)
  const exited = new Promise(done => child.once('exit', done))
  exited.then(() => running.delete(child))

  return new Promise((resolve, reject) => {
    let settled = false
    const fail = message => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      kill()
      reject(new Error(`bitsql: ${message}${logs ? `\n${logs.trim().slice(-2000)}` : ''}`))
    }
    const timer = setTimeout(() => fail(`no "listening on" line within ${timeout} ms`), timeout)
    child.once('error', error => fail(`cannot start ${bin}: ${error.message}`))
    child.once('exit', (code, signal) => fail(`${bin} exited (${signal ?? code}) before listening`))
    child.stderr.on('data', () => {
      const match = !settled && logs.match(/listening on (\S+):(\d+)\n/)
      if (!match) return
      settled = true
      clearTimeout(timer)
      // A server left running must not keep the test runner alive.
      child.unref()
      child.stdin.unref?.()
      child.stderr.unref?.()
      const host = match[1] === '0.0.0.0' ? '127.0.0.1' : match[1]
      const port = Number(match[2])
      const stop = () => {
        if (child.exitCode === null && child.signalCode === null) {
          child.kill('SIGTERM')
          setTimeout(kill, 2000).unref()
        }
        return exited.then(() => undefined)
      }
      const user = options.user ?? 'sa'
      const password = options.password ?? 'bitsql'
      resolve({
        host,
        port,
        pid: child.pid,
        stop,
        logs: () => logs,
        connectionString: (database = 'master') =>
          `Server=${host},${port};Database=${database};User Id=${user};Password=${password};` +
          `Encrypt=${encrypt};TrustServerCertificate=true`,
        tedious: (database = 'master') => ({
          server: host,
          authentication: { type: 'default', options: { userName: user, password } },
          options: { port, database, encrypt, trustServerCertificate: true },
        }),
        mssql: (database = 'master') => ({
          server: host,
          port,
          database,
          user,
          password,
          options: { encrypt, trustServerCertificate: true },
        }),
      })
    })
  })
}

module.exports = { start, binaryPath, version }
module.exports.default = module.exports

// Real SQL Server ("the oracle") in a docker container, adapted from msduck
// scripts/lib/reference-container.mjs. Differences: the container is named
// `bitsql-oracle`, binds a fixed loopback port (47314 by default) and is reused
// between runs for fast iteration; `npm run oracle:stop` removes it.
//
// Shared host rules: only containers whose name starts with `bitsql-` are ever
// stopped or removed here, and only the one this module manages.
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { randomBytes } from 'node:crypto'
import { setTimeout as delay } from 'node:timers/promises'
import { pathToFileURL } from 'node:url'
import { connect, close, tediousConfig } from './client.mjs'

// msduck pins sha256:86cc6144… (17.0.4065.4); that digest is not on this host,
// so bitsql pins the locally pulled 2025-latest instead (recorded 2026-10-03).
export const oracleImage = 'mcr.microsoft.com/mssql/server:2025-latest@sha256:2b5b581621126574f3d1f75e78d3eebe8d05aedb59ad0cfdf9aa42cb0634d726'
export const containerName = process.env.BITSQL_ORACLE_NAME ?? 'bitsql-oracle'
if (!containerName.startsWith('bitsql-oracle')) throw new Error('BITSQL_ORACLE_NAME must start with bitsql-oracle')
const exec = promisify(execFile)
const docker = async (args, env) => (await exec('docker', args, { env: { ...process.env, ...env }, maxBuffer: 16 * 1024 * 1024 })).stdout.trim()

export function oraclePort(env = process.env) {
  const port = Number(env.BITSQL_ORACLE_PORT ?? 47314)
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('BITSQL_ORACLE_PORT must be a TCP port')
  return port
}

async function inspect(name) {
  try { return JSON.parse(await docker(['inspect', name]))[0] } catch { return null }
}

function passwordOf(info) {
  const entry = (info?.Config?.Env ?? []).find(e => e.startsWith('MSSQL_SA_PASSWORD='))
  return entry?.slice('MSSQL_SA_PASSWORD='.length)
}

function portOf(info) {
  const binding = info?.NetworkSettings?.Ports?.['1433/tcp']?.find(b => b.HostIp === '127.0.0.1')
  return binding ? Number(binding.HostPort) : NaN
}

// An external oracle (BITSQL_ORACLE_ADDR=host:port + BITSQL_ORACLE_PASSWORD)
// skips docker entirely.
function externalConfig(env = process.env) {
  if (!env.BITSQL_ORACLE_ADDR) return null
  const [host, port] = env.BITSQL_ORACLE_ADDR.split(':')
  if (!env.BITSQL_ORACLE_PASSWORD) throw new Error('BITSQL_ORACLE_PASSWORD is required with BITSQL_ORACLE_ADDR')
  return tediousConfig({ host, port: Number(port), user: env.BITSQL_ORACLE_USER ?? 'sa', password: env.BITSQL_ORACLE_PASSWORD, tls: true })
}

async function waitReady(config, timeout = 180000, log = () => {}) {
  const deadline = Date.now() + timeout
  let last
  while (true) {
    const info = await inspect(containerName)
    if (!info?.State?.Running) throw new Error(`oracle container ${containerName} is not running${last ? `: ${last.message}` : ''}`)
    try { await close(await connect({ ...config, options: { ...config.options, connectTimeout: 3000 } })); return }
    catch (error) {
      last = error
      if (Date.now() >= deadline) throw new Error(`oracle login readiness timed out: ${error.message}`)
      log('.')
      await delay(1000)
    }
  }
}

// Ensures the oracle is running and returns { config, image, name }.
export async function startOracle({ log = () => {} } = {}) {
  const external = externalConfig()
  if (external) return { config: external, image: 'external', name: process.env.BITSQL_ORACLE_ADDR }
  let info = await inspect(containerName)
  if (info && !info.State.Running) {
    log(`removing stopped ${containerName}\n`)
    await docker(['rm', '--force', containerName])
    info = null
  }
  if (!info) {
    const port = oraclePort()
    const password = `Bitsql!9${randomBytes(16).toString('hex')}`
    log(`starting ${containerName} on 127.0.0.1:${port} (${oracleImage})\n`)
    await docker(['run', '--detach', '--name', containerName, '--hostname', 'bitsql-oracle',
      '--label', 'bitsql.oracle=1',
      '--env', 'ACCEPT_EULA=Y', '--env', 'MSSQL_PID=Developer', '--env', 'TZ=UTC',
      '--env', 'MSSQL_COLLATION=SQL_Latin1_General_CP1_CI_AS', '--env', 'MSSQL_MEMORY_LIMIT_MB=2048',
      '--env', 'MSSQL_SA_PASSWORD', '--publish', `127.0.0.1:${port}:1433`, oracleImage], { MSSQL_SA_PASSWORD: password })
    info = await inspect(containerName)
  }
  const port = portOf(info)
  const password = passwordOf(info)
  if (!Number.isInteger(port) || !password) throw new Error(`cannot read port/password of ${containerName}; run npm run oracle:stop`)
  const config = tediousConfig({ host: '127.0.0.1', port, password, tls: true })
  await waitReady(config, 180000, log)
  return { config, image: info.Config.Image, name: containerName }
}

export async function stopOracle({ log = () => {} } = {}) {
  const info = await inspect(containerName)
  if (!info) { log(`${containerName} is not present\n`); return }
  if (!info.Name.replace(/^\//, '').startsWith('bitsql-')) throw new Error('refusing to remove a non-bitsql container')
  await docker(['rm', '--force', containerName])
  log(`removed ${containerName}\n`)
}

export async function oracleStatus() {
  const info = await inspect(containerName)
  if (!info) return `${containerName}: not present`
  return `${containerName}: ${info.State.Status}, 127.0.0.1:${portOf(info)}, ${info.Config.Image}`
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const log = text => process.stderr.write(text)
  const command = process.argv[2]
  try {
    if (command === 'start') {
      const { config, image } = await startOracle({ log })
      const connection = await connect(config)
      const { query } = await import('./capture-core.mjs')
      const version = await query(connection, 'SELECT CAST(SERVERPROPERTY(\'ProductVersion\') AS nvarchar(64)) AS v')
      await close(connection)
      console.log(`oracle ready: ${containerName} 127.0.0.1:${config.options.port} ${image} SQL Server ${version.rows[0][0]}`)
    } else if (command === 'stop') await stopOracle({ log })
    else if (command === 'status') console.log(await oracleStatus())
    else { console.error('usage: oracle.mjs start|stop|status'); process.exitCode = 2 }
  } catch (error) { console.error(error.message); process.exitCode = 1 }
}

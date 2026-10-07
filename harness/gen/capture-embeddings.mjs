// node gen/capture-embeddings.mjs [--verify|--force]
// Creates and removes its own oracle. Never changes the shared oracle.
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { randomUUID } from 'node:crypto'
import { readFile, mkdir } from 'node:fs/promises'
import { join } from 'node:path'
import assert from 'node:assert/strict'
import { embeddingFixture } from '../src/embedding-fixture.mjs'
import { embeddingCases } from './embedding-cases.mjs'
import { connect, close } from '../src/client.mjs'
import { capture, query } from '../src/capture-core.mjs'
import { writeJson } from '../src/json.mjs'
import { harnessDir, outDir, useUtcTimeZone } from '../src/env.mjs'
const exec = promisify(execFile)
const docker = async args => (await exec('docker', args, { maxBuffer: 4 * 1024 * 1024 })).stdout.trim()
useUtcTimeZone()
if (process.env.BITSQL_ORACLE_ADDR) throw Error('embedding captures require their own temporary oracle')
process.env.BITSQL_ORACLE_NAME = `bitsql-oracle-embedding-${randomUUID().slice(0, 8)}`
const port = Number(process.env.BITSQL_ORACLE_PORT ?? 0)
if (!(port === 0 || (port >= 47300 && port <= 47399 && Number.isInteger(port)))) throw Error('oracle port must be 0 or 47300–47399')
const { startOracle, stopOracle, containerName } = await import('../src/oracle.mjs')
if (!containerName.startsWith('bitsql-oracle-embedding-')) throw Error('a dedicated embedding oracle name is required')
if (await docker(['ps', '-a', '--filter', `name=^/${containerName}$`, '--format', '{{.Names}}'])) throw Error('refusing to reuse an existing oracle')
const file = join(harnessDir, 'fixtures', 'embeddings.expected.json')
const verify = process.argv.includes('--verify'), force = process.argv.includes('--force')
const probe = process.argv.find(a => a.startsWith('--probe='))?.slice(8)
if (!probe && !verify && !force) {
  try { await readFile(file); throw Error('expectations exist; use --verify or --force') }
  catch (e) { if (e.code !== 'ENOENT') throw e }
}
await mkdir(outDir, { recursive: true })
let conn, fixture
try {
  let oracle = await startOracle({ port, log: s => process.stderr.write(s) })
  const gateway = await docker(['inspect', '--format', '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}', containerName])
  if (!/^\d+\.\d+\.\d+\.\d+$/.test(gateway)) throw Error('unexpected Docker gateway')
  fixture = await embeddingFixture(gateway)
  await docker(['cp', fixture.cert, `${containerName}:/usr/local/share/ca-certificates/bitsql-embedding.crt`])
  await docker(['exec', '--user', 'root', containerName, 'update-ca-certificates'])
  await docker(['exec', '--user', 'root', containerName, 'mkdir', '-p', '/var/opt/mssql/security/ca-certificates'])
  await docker(['cp', fixture.cert, `${containerName}:/var/opt/mssql/security/ca-certificates/bitsql-embedding.crt`])
  await docker(['restart', containerName])
  oracle = await startOracle()
  await docker(['exec', '--user', 'root', containerName, 'sh', '-c', `echo '${gateway} bitsql-embedding.test' >> /etc/hosts`])
  conn = await connect(oracle.config)
  const version = (await query(conn, "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(64))")).rows[0][0]
  await query(conn, "EXEC sp_configure 'external rest endpoint enabled',1; RECONFIGURE;")
  await query(conn, 'CREATE DATABASE embedding_capture;')
  await query(conn, 'USE embedding_capture;')
  const endpoint = `https://bitsql-embedding.test:${fixture.port}/v1/embeddings`
  const normalize = value => JSON.parse(JSON.stringify(value).replaceAll(`bitsql-embedding.test:${fixture.port}`, '{authority}'))
  const quote = s => "N'" + s.replaceAll("'", "''") + "'"
  const results = []
  for (const c of embeddingCases.filter(c => !probe || c.name === probe)) {
    const parameters = c.parameters === undefined ? '' : `,PARAMETERS=${quote(JSON.stringify(c.parameters))}`
    await query(conn, `CREATE EXTERNAL MODEL m WITH(LOCATION=${quote(endpoint)},API_FORMAT=${quote(c.api)},MODEL_TYPE=EMBEDDINGS,MODEL=${quote(c.model ?? 'fixture')}${parameters});`)
    fixture.setResponse(c.response)
    const result = await capture(conn, { kind: 'batch', sql: c.sql })
    await writeJson(join(outDir, 'embedding-capture-last.json'), { input: c, result, requests: fixture.requests }, { overwrite: true })
    if (result.errors.some(e => e.client)) throw Error(`transport failure: ${c.name}`)
    if (c.name === 'openai' && (result.errors.length || fixture.requests.length !== 1)) throw Error('HTTPS fixture health check failed: ' + JSON.stringify(result.errors))
    const fatal = result.errors.some(e => e.class >= 20)
    if (fatal !== Boolean(c.fatal)) throw Error(`unexpected fatal-error disposition: ${c.name}`)
    results.push({ input: c, result: normalize(result), requests: normalize(fixture.requests) })
    if (fatal) {
      await close(conn)
      conn = await connect(oracle.config)
      await query(conn, 'USE embedding_capture;')
    }
    await query(conn, 'DROP EXTERNAL MODEL m;')
    console.log(`${c.name}: ${result.errors.map(e => e.number).join(',') || 'OK'}; ${fixture.requests.length} request(s)`)
  }
  const doc = { server: { image: oracle.image, version }, cases: results }
  if (probe) {
    console.log(JSON.stringify(doc))
  } else if (verify) {
    assert.deepEqual(doc, JSON.parse(await readFile(file, 'utf8')))
    console.log(`verified ${results.length} embedding cases`)
  } else {
    await writeJson(file, doc, { overwrite: force })
    console.log(`captured ${results.length} embedding cases: ${file}`)
  }
} finally {
  await close(conn)
  try { await fixture?.close() } finally { await stopOracle({ log: s => process.stderr.write(s) }) }
}

// node gen/capture-embedding-concurrency.mjs [--verify|--force] [--prefix|--rpc-prefix|--proc-prefix|--cancel-prefix|--cancel-matrix]
// Creates and removes its own oracle. Never changes the shared oracle.
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { randomUUID } from 'node:crypto'
import { readFile, mkdir } from 'node:fs/promises'
import { join } from 'node:path'
import assert from 'node:assert/strict'
import { embeddingAfterSql } from '../src/embedding-normalize.mjs'
import { embeddingFixture } from '../src/embedding-fixture.mjs'

import { embeddingConcurrencyCases, embeddingPrefixCases, embeddingRpcPrefixCases, embeddingProcPrefixCases, embeddingCancellationCases, embeddingCancellationMatrixCases } from './embedding-concurrency-cases.mjs'
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
const cancelMatrix = process.argv.includes('--cancel-matrix')
const cancellation = process.argv.includes('--cancel-prefix')
const procPrefix = process.argv.includes('--proc-prefix')
const rpcPrefix = process.argv.includes('--rpc-prefix')
const prefix = process.argv.includes('--prefix') || rpcPrefix || procPrefix
const cases = cancelMatrix ? embeddingCancellationMatrixCases : cancellation ? embeddingCancellationCases : procPrefix ? embeddingProcPrefixCases : rpcPrefix ? embeddingRpcPrefixCases : prefix ? embeddingPrefixCases : embeddingConcurrencyCases
const file = join(harnessDir, 'fixtures', cancelMatrix ? 'embedding-cancellation-matrix.expected.json' : cancellation ? 'embedding-cancellation.expected.json' : procPrefix ? 'embedding-prefix-proc.expected.json' : rpcPrefix ? 'embedding-prefix-rpc.expected.json' : prefix ? 'embedding-prefix.expected.json' : 'embedding-concurrency.expected.json')
const verify = process.argv.includes('--verify'), force = process.argv.includes('--force')
const probe = process.argv.find(a => a.startsWith('--probe='))?.slice(8)
if (!probe && !verify && !force) {
  try { await readFile(file); throw Error('expectations exist; use --verify or --force') }
  catch (e) { if (e.code !== 'ENOENT') throw e }
}
await mkdir(outDir, { recursive: true })
let conn, fixture, other
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
  other = await connect(oracle.config)
  await query(other, 'USE embedding_capture; SET LOCK_TIMEOUT 200;')
  const results = []
  for (const c of cases.filter(c => !probe || c.name === probe)) {
    await query(conn, "EXEC sp_configure 'external rest endpoint enabled',1; RECONFIGURE;")
    await query(conn, c.setup)
    await query(conn, `CREATE EXTERNAL MODEL m WITH(LOCATION=${quote(endpoint)},API_FORMAT='OpenAI',MODEL_TYPE=EMBEDDINGS,MODEL='fixture');`)
    if (c.prepare) await query(conn, c.prepare)
    fixture.setResponse({ body: { data: [{ embedding: [1,2] }] }, hold: true })
    const serverRows = []
    const pending = capture(conn, { kind: c.kind ?? 'batch', sql: c.sql, params: c.params }, { onTokenRow: cancelMatrix ? row => serverRows.push(row) : undefined })
    const started = Date.now()
    while (fixture.requests.length === 0 && Date.now()-started < 5000) await new Promise(r => setTimeout(r, 10))
    if (!fixture.requests.length) throw Error('no HTTP request')
    const update = await capture(other, { kind: 'batch', sql: c.mutation })
    let beforeRelease
    if (c.cancel) {
      conn.cancel()
      let timer
      beforeRelease = await Promise.race([
        pending.then(() => true),
        new Promise(r => { timer = setTimeout(() => r(false), 500) }),
      ])
      clearTimeout(timer)
    }
    fixture.release()
    const result = await pending
    if (result.errors.some(e => e.client && !(c.cancel && e.code === 'ECANCEL'))) throw Error('unexpected client failure: ' + c.name)
    const after = c.after ? await capture(conn, { kind: 'batch', sql: embeddingAfterSql(c, result) }) : undefined
    results.push(normalize({ input: c, ...(cancelMatrix ? { serverRows } : {}), update, result, requests: fixture.requests.slice(), ...(after ? { after } : {}), ...(c.cancel ? { beforeRelease } : {}) }))
    console.log(c.name, JSON.stringify({ update, result }))
    if (c.cleanup) await query(conn, c.cleanup)
    await capture(conn, { kind: 'batch', sql: 'DROP TABLE t;' })
    await capture(conn, { kind: 'batch', sql: 'DROP EXTERNAL MODEL m;' })
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
  await close(other)
  await close(conn)
  try { await fixture?.close() } finally { await stopOracle({ log: s => process.stderr.write(s) }) }
}

// Runs from a directory where the packed `bitsql` tarballs are installed
// (scripts/npm-publish.sh). Clients come from the harness: BITSQL_HARNESS.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { setTimeout as sleep } from 'node:timers/promises'
import { start, binaryPath, version } from 'bitsql'

const harness = createRequire(join(process.env.BITSQL_HARNESS, 'package.json'))
const { Connection, Request } = harness('tedious')
const mssql = harness('mssql')
const cjs = createRequire(import.meta.url)('bitsql')

function query(config, sql) {
  return new Promise((resolve, reject) => {
    const connection = new Connection(config)
    connection.on('error', () => {})
    connection.connect(error => {
      if (error) return reject(error)
      const rows = []
      const request = new Request(sql, error => { connection.close(); error ? reject(error) : resolve(rows) })
      request.on('row', columns => rows.push(columns.map(c => c.value)))
      connection.execSql(request)
    })
  })
}

test('CommonJS and ESM entry points agree', () => {
  assert.equal(cjs.start, start)
  assert.equal(cjs.default.version, version)
  assert.match(binaryPath(), /bitsql-linux-[a-z0-9]+\/bin\/bitsql$/)
})

test('tedious config, TLS on, named database', async () => {
  const server = await start({ databases: ['app'] })
  try {
    assert.ok(server.port > 0)
    const rows = await query(server.tedious('app'), 'SELECT DB_NAME(), @@VERSION')
    assert.equal(rows[0][0], 'app')
    assert.match(rows[0][1], new RegExp(`mirek/bitsql@${version.replaceAll('.', '\\.')}`))
  } finally { await server.stop() }
  await server.stop()
})

test('mssql config and connection string, TLS off, auto-created database', async () => {
  const server = await start({ tls: false, autoCreateDatabases: true })
  try {
    for (const config of [server.mssql('t1'), server.connectionString('t2')]) {
      const pool = await new mssql.ConnectionPool(config).connect()
      try {
        const result = await pool.request().query('SELECT DB_NAME() AS db')
        assert.match(result.recordset[0].db, /^t[12]$/)
      } finally { await pool.close() }
    }
  } finally { await server.stop() }
})

test('a taken port fails with the server output', async () => {
  const first = await start()
  try {
    await assert.rejects(start({ port: first.port }), /bitsql: .*exited/)
  } finally { await first.stop() }
})

test("the server dies with a SIGKILLed parent", async () => {
  const parent = spawn(process.execPath, ["-e", "require('bitsql').start().then(s => { console.log(s.pid); setInterval(() => {}, 1000) })"], { stdio: ["ignore", "pipe", "inherit"] })
  const [line] = await once(parent.stdout, "data")
  const pid = Number(line.toString())
  assert.ok(pid > 0)
  parent.kill("SIGKILL")
  await once(parent, "exit")
  const alive = () => { try { process.kill(pid, 0); return true } catch { return false } }
  for (let i = 0; i < 100 && alive(); i++) await sleep(20)
  assert.equal(alive(), false)
})

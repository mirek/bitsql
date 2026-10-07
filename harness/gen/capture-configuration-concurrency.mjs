// node gen/capture-configuration-concurrency.mjs [--force]
// Verify by default. All instance mutations stay in a disposable oracle.
import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { connect, close } from '../src/client.mjs'
import { capture, query } from '../src/capture-core.mjs'
import { writeJson } from '../src/json.mjs'
import { configurationConcurrencyCases } from './configuration-concurrency-cases.mjs'

if (process.env.BITSQL_ORACLE_ADDR) throw Error('private oracle required')
process.env.BITSQL_ORACLE_NAME = 'bitsql-oracle-config-concurrency-' + randomUUID().slice(0, 8)
const { startOracle, stopOracle } = await import('../src/oracle.mjs')
const file = new URL('../fixtures/configuration-concurrency.expected.json', import.meta.url)
let a, b
try {
  const oracle = await startOracle({ port: 0, log: s => process.stderr.write(s) })
  const config = { ...oracle.config, options: { ...oracle.config.options, requestTimeout: 2000 } }
  a = await connect(config)
  b = await connect(config)
  const version = (await query(a, "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(64))")).rows[0][0]
  const cases = []
  for (const { who, sql } of configurationConcurrencyCases) {
    const result = await capture(who === 'a' ? a : b, { kind: 'batch', sql })
    if (result.errors.some(e => e.client)) throw Error('transport failure: ' + sql)
    cases.push({ who, sql, result })
    console.log(who + ': ' + sql + ' => ' + (result.errors.map(e => e.number).join(',') || 'OK'))
  }
  const doc = JSON.parse(JSON.stringify({ server: { image: oracle.image, version }, cases }))
  if (process.argv.includes('--force')) await writeJson(file, doc, { overwrite: true })
  else assert.deepEqual(doc, JSON.parse(await readFile(file, 'utf8')))
} finally {
  await close(a)
  await close(b)
  await stopOracle({ log: s => process.stderr.write(s) })
}

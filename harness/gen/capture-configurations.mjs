// node gen/capture-configurations.mjs [--verify|--force]
import { randomUUID } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { join } from 'node:path'
import assert from 'node:assert/strict'
import { connect, close } from '../src/client.mjs'
import { capture, query } from '../src/capture-core.mjs'
import { writeJson } from '../src/json.mjs'
import { harnessDir, useUtcTimeZone } from '../src/env.mjs'
import { configurationCases } from './configuration-cases.mjs'
useUtcTimeZone()
if (process.env.BITSQL_ORACLE_ADDR) throw Error('a temporary oracle is required')
process.env.BITSQL_ORACLE_NAME = 'bitsql-oracle-config-' + randomUUID().slice(0, 8)
const { startOracle, stopOracle } = await import('../src/oracle.mjs')
const file = join(harnessDir, 'fixtures', 'configurations.expected.json')
const verify = process.argv.includes('--verify'), force = process.argv.includes('--force')
if (!verify && !force) {
  try { await readFile(file); throw Error('expectations exist; use --verify or --force') }
  catch (e) { if (e.code !== 'ENOENT') throw e }
}
let conn
try {
  const oracle = await startOracle({ port: 0, log: s => process.stderr.write(s) })
  conn = await connect(oracle.config)
  const version = (await query(conn, "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(64))")).rows[0][0]
  const catalog = await capture(conn, { kind: 'batch', sql: 'SELECT * FROM sys.configurations ORDER BY configuration_id;' })
  if (catalog.errors.length) throw Error('catalog capture failed')
  const catalogTypes = await capture(conn, { kind: 'batch', sql: "SELECT configuration_id,SQL_VARIANT_PROPERTY(value,'BaseType') AS value_type,SQL_VARIANT_PROPERTY(minimum,'BaseType') AS minimum_type,SQL_VARIANT_PROPERTY(maximum,'BaseType') AS maximum_type,SQL_VARIANT_PROPERTY(value_in_use,'BaseType') AS active_type FROM sys.configurations ORDER BY configuration_id;" })
  if (catalogTypes.errors.length) throw Error('catalog type capture failed')
  const cases = []
  for (const input of configurationCases) {
    const result = await capture(conn, { kind: 'batch', sql: input.sql })
    if (result.errors.some(e => e.client)) throw Error('transport failure: ' + input.name)
    cases.push({ input, result })
    console.log(input.name + ': ' + (result.errors.map(e => e.number).join(',') || 'OK'))
  }
  const doc = JSON.parse(JSON.stringify({ server: { image: oracle.image, version }, catalog, catalogTypes, cases }))
  if (verify) { assert.deepEqual(doc, JSON.parse(await readFile(file, 'utf8'))); console.log('verified configurations') }
  else { await writeJson(file, doc, { overwrite: force }); console.log('captured configurations') }
} finally { await close(conn); await stopOracle({ log: s => process.stderr.write(s) }) }

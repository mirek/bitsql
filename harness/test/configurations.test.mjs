import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { connect, close } from '../src/client.mjs'
import { capture } from '../src/capture-core.mjs'
import { compareCase } from '../src/compare.mjs'
import { configurationCases } from '../gen/configuration-cases.mjs'
import { configurationConcurrencyCases } from '../gen/configuration-concurrency-cases.mjs'
import { server } from './support.mjs'

test('configuration changes lock catalog scans and RECONFIGURE across sessions', async t => {
  const expected = JSON.parse(await readFile(new URL('../fixtures/configuration-concurrency.expected.json', import.meta.url), 'utf8')).cases
  assert.deepEqual(expected.map(({ who, sql }) => ({ who, sql })), configurationConcurrencyCases)
  const s = await server(t)
  const a = await connect(s.config), b = await connect(s.config)
  t.after(async () => { await close(a); await close(b) })
  for (const c of expected) {
    const actual = await capture(c.who === 'a' ? a : b, { kind: 'batch', sql: c.sql })
    const difference = compareCase({ steps: [JSON.parse(JSON.stringify(actual))] }, { steps: [c.result] })
    assert.equal(difference, null, c.who + ' ' + c.sql + ': ' + JSON.stringify(difference))
  }
})

test('REST configuration changes and activation match the oracle', async t => {
  const expected = JSON.parse(await readFile(new URL('../fixtures/configurations.expected.json', import.meta.url), 'utf8'))
  const s = await server(t)
  const conn = await connect(s.config)
  t.after(() => close(conn))
  for (const c of expected.cases) {
    const actual = await capture(conn, { kind: 'batch', sql: c.input.sql })
    const difference = compareCase({ steps: [JSON.parse(JSON.stringify(actual))] }, { steps: [c.result] })
    assert.equal(difference, null, c.input.name + ': ' + JSON.stringify(difference))
  }
})

test('instance configuration defaults and variant types match the oracle', async t => {
  const expected = JSON.parse(await readFile(new URL('../fixtures/configurations.expected.json', import.meta.url), 'utf8'))
  assert.deepEqual(expected.cases.map(c => c.input), configurationCases)
  const s = await server(t)
  const conn = await connect(s.config)
  t.after(() => close(conn))
  const steps = []
  for (const sql of [
    'SELECT * FROM sys.configurations ORDER BY configuration_id;',
    "SELECT configuration_id,SQL_VARIANT_PROPERTY(value,'BaseType') AS value_type,SQL_VARIANT_PROPERTY(minimum,'BaseType') AS minimum_type,SQL_VARIANT_PROPERTY(maximum,'BaseType') AS maximum_type,SQL_VARIANT_PROPERTY(value_in_use,'BaseType') AS active_type FROM sys.configurations ORDER BY configuration_id;",
  ]) steps.push(await capture(conn, { kind: 'batch', sql }))
  assert.equal(compareCase({ steps }, { steps: [expected.catalog, expected.catalogTypes] }), null)
})

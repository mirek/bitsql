import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { connect, close } from '../src/client.mjs'
import { capture } from '../src/capture-core.mjs'
import { compareCase } from '../src/compare.mjs'
import { configurationCases } from '../gen/configuration-cases.mjs'
import { server } from './support.mjs'

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

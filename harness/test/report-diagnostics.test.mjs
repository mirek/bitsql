import { test } from 'node:test'
import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { connect, close } from '../src/client.mjs'
import { capture } from '../src/capture-core.mjs'
import { loadCorpus, readExpected } from '../src/corpus.mjs'
import { server } from './support.mjs'

test('all seven reported diagnostic views return captured metadata after workload', async t => {
  const s = await server(t)
  const c = await connect(s.config)
  const db = `report_${randomUUID().replaceAll('-', '')}`
  const run = sql => capture(c, { kind: 'batch', sql })
  t.after(async () => {
    try { await run(`USE master; DROP DATABASE IF EXISTS ${db}`) }
    finally { await close(c) }
  })
  const setup = await run(`CREATE DATABASE ${db}; USE ${db}; CREATE TABLE foo(id int NOT NULL PRIMARY KEY,category int,payload varchar(100)); INSERT foo SELECT value,value%100,REPLICATE('x',100) FROM GENERATE_SERIES(1,10000); SELECT payload FROM foo WHERE category=42 ORDER BY payload; SELECT id FROM foo WHERE id=1;`)
  assert.deepEqual(setup.errors, [])
  const [fixture] = await loadCorpus(['report-0125/view-descriptors.sql'])
  const expected = await readExpected(fixture)
  const views = [...fixture.steps[0].sql.matchAll(/FROM (sys\.\w+)/g)].map(m => m[1])
  assert.equal(views.length, 7)
  for (const [i, view] of views.entries()) {
    const actual = await run(`SELECT TOP (1) * FROM ${view}`)
    assert.deepEqual(actual.errors, [], view)
    assert.equal(actual.sets.length, 1, view)
    assert.equal(actual.sets[0].rows.length, 1, view)
    assert.deepEqual(JSON.parse(JSON.stringify(actual.sets[0].columns)), expected.steps[0].sets[i].columns, view)
  }
})

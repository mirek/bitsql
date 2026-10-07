import { test } from 'node:test'
import assert from 'node:assert/strict'
import { connect, close } from '../src/client.mjs'
import { capture, query } from '../src/capture-core.mjs'
import { spawnEmulator, emulatorConfig } from '../src/emulator.mjs'
import { embeddingFixture } from '../src/embedding-fixture.mjs'
import { embeddingConcurrencyCases } from '../gen/embedding-concurrency-cases.mjs'

// These are emulator rejection contracts, not invented SQL Server outputs.
// The SQL behavior is captured in embedding-concurrency.expected.json.
test('embedding concurrent table changes fail explicitly and preserve observer commits', { timeout: 30000 }, async () => {
  const fixture = await embeddingFixture()
  let server, conn, other
  try {
    server = await spawnEmulator({ args: ['--http-ca', fixture.cert] })
    conn = await connect(emulatorConfig(server))
    other = await connect(emulatorConfig(server))
    await query(conn, "EXEC sp_configure 'external rest endpoint enabled',1; RECONFIGURE;")
    await query(other, 'SET LOCK_TIMEOUT 200;')
    const cases = embeddingConcurrencyCases.filter(c => !['model-drop', 'model-alter', 'rest-disable'].includes(c.name)).sort((a,b) => Number(b.name === 'source-delete') - Number(a.name === 'source-delete'))
    for (const c of cases) {
      await query(conn, c.setup)
      await query(conn, `CREATE EXTERNAL MODEL m WITH(LOCATION='https://127.0.0.1:${fixture.port}/v1/embeddings',API_FORMAT='OpenAI',MODEL_TYPE=EMBEDDINGS,MODEL='fixture');`)
      fixture.setResponse({ body: { data: [{ embedding: [1,2] }] }, hold: true })
      const pending = capture(conn, { kind: 'batch', sql: c.sql })
      const started = Date.now()
      while (!fixture.requests.length && Date.now() - started < 5000) await new Promise(r => setTimeout(r, 10))
      assert.ok(fixture.requests.length, c.name + ': HTTP started')
      const update = await capture(other, { kind: 'batch', sql: c.mutation })
      assert.deepEqual(update.errors, [], c.name + ': mutation succeeded')
      const inspectSql = c.name === 'table-drop' ? "SELECT OBJECT_ID(N't') AS id;" : 'SELECT id,s FROM t ORDER BY id;'
      const before = await capture(other, { kind: 'batch', sql: inspectSql })
      fixture.release()
      const result = await pending
      assert.ok(result.errors.some(e => e.number === 50100 && e.class === 16 && e.message.includes('concurrent table changes during embedding HTTP')), c.name + ': ' + JSON.stringify(result.errors))
      const after = await capture(other, { kind: 'batch', sql: inspectSql })
      assert.deepEqual(after, before, c.name + ': observer commit retained')
      const reusable = await capture(conn, { kind: 'batch', sql: 'SELECT 1 AS reusable;' })
      assert.deepEqual(reusable.errors, [], c.name + ': connection reusable')
      await query(conn, "IF OBJECT_ID(N't') IS NOT NULL DROP TABLE t; DROP EXTERNAL MODEL m;")
    }
  } finally {
    fixture.release()
    await close(other)
    await close(conn)
    await server?.stop()
    await fixture.close()
  }
})

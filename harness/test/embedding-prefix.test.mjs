import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { connect, close } from '../src/client.mjs'
import { capture, query } from '../src/capture-core.mjs'
import { compareCase } from '../src/compare.mjs'
import { spawnEmulator, emulatorConfig } from '../src/emulator.mjs'
import { embeddingAfterSql } from '../src/embedding-normalize.mjs'
import { embeddingFixture } from '../src/embedding-fixture.mjs'

for (const [label, file] of [['batch', 'embedding-prefix'], ['RPC', 'embedding-prefix-rpc'], ['procedure RPC', 'embedding-prefix-proc'], ['cancelled RPC', 'embedding-cancellation'], ['cancelled expressions', 'embedding-cancellation-matrix'], ['model context', 'embedding-context']])
test(`embedding HTTP ${label} contracts match SQL Server`, { timeout: 30000 }, async t => {
  const expected = JSON.parse(await readFile(new URL(`../fixtures/${file}.expected.json`, import.meta.url), 'utf8'))
  const fixture = await embeddingFixture()
  let server, conn, other
  const compare = (actual, expected, name) => {
    const difference = compareCase({ steps: [JSON.parse(JSON.stringify(actual))] }, { steps: [expected] })
    assert.equal(difference, null, name + ': ' + JSON.stringify(difference))
  }
  try {
    server = await spawnEmulator({ args: ['--http-ca', fixture.cert] })
    const config = emulatorConfig(server)
    conn = await connect(config)
    other = await connect(config)
    await query(conn, "EXEC sp_configure 'external rest endpoint enabled',1; RECONFIGURE;")
    await query(other, 'SET LOCK_TIMEOUT 200;')
    const cases = expected.cases
    for (const c of cases) {
      await query(conn, "EXEC sp_configure 'external rest endpoint enabled',1; RECONFIGURE;")
      await query(conn, c.input.setup)
      await query(conn, `CREATE EXTERNAL MODEL m WITH(LOCATION='https://127.0.0.1:${fixture.port}/v1/embeddings',API_FORMAT='OpenAI',MODEL_TYPE=EMBEDDINGS,MODEL='fixture');`)
      if (c.input.prepare) await query(conn, c.input.prepare)
      fixture.setResponse({ body: { data: [{ embedding: [1,2] }] }, hold: true })
      const serverRows = []
      const pending = capture(conn, { kind: c.input.kind ?? 'batch', sql: c.input.sql, params: c.input.params }, { onTokenRow: row => serverRows.push(row) })
      const started = Date.now()
      while (!fixture.requests.length && Date.now() - started < 5000) await new Promise(r => setTimeout(r, 10))
      if (!fixture.requests.length) assert.fail(c.input.name + ': HTTP request did not start: ' + JSON.stringify(await pending))
      const update = await capture(other, { kind: 'batch', sql: c.input.mutation })
      if (c.input.cancel) {
        conn.cancel()
        let timer
        const beforeRelease = await Promise.race([
          pending.then(() => true),
          new Promise(r => { timer = setTimeout(() => r(false), 500) }),
        ])
        clearTimeout(timer)
        assert.equal(beforeRelease, c.beforeRelease, c.input.name + ': cancellation before HTTP release')
      }
      fixture.release()
      const result = await pending
      if (c.serverRows) assert.deepEqual(serverRows, c.serverRows, c.input.name + ': cancelled wire rows')
      compare(update, c.update, c.input.name + ': observer')
      compare(result, c.result, c.input.name + ': inference')
      if (c.input.after) compare(await capture(conn, { kind: 'batch', sql: embeddingAfterSql(c.input, result) }), c.after, c.input.name + ': after module')
      assert.deepEqual(fixture.requests, c.requests, c.input.name + ': HTTP requests')
      if (c.input.cleanup) await query(conn, c.input.cleanup)
      await query(conn, "DROP TABLE t; IF EXISTS(SELECT 1 FROM sys.external_models WHERE name=N'm') DROP EXTERNAL MODEL m;")
    }
    t.diagnostic(`${cases.length} oracle cases matched`)
  } finally {
    await close(other)
    await close(conn)
    await server?.stop()
    await fixture.close()
  }
})

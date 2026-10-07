import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { connect, close } from '../src/client.mjs'
import { capture, query } from '../src/capture-core.mjs'
import { compareCase } from '../src/compare.mjs'
import { spawnEmulator, emulatorConfig } from '../src/emulator.mjs'
import { embeddingAfterSql } from '../src/embedding-normalize.mjs'
import { embeddingFixture } from '../src/embedding-fixture.mjs'

for (const [label, file] of [['batch', 'embedding-prefix'], ['RPC', 'embedding-prefix-rpc'], ['procedure RPC', 'embedding-prefix-proc']])
test(`completed ${label} statements remain visible during embedding HTTP waits`, { timeout: 30000 }, async t => {
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
    for (const c of expected.cases) {
      await query(conn, c.input.setup)
      await query(conn, `CREATE EXTERNAL MODEL m WITH(LOCATION='https://127.0.0.1:${fixture.port}/v1/embeddings',API_FORMAT='OpenAI',MODEL_TYPE=EMBEDDINGS,MODEL='fixture');`)
      if (c.input.prepare) await query(conn, c.input.prepare)
      fixture.setResponse({ body: { data: [{ embedding: [1,2] }] }, hold: true })
      const pending = capture(conn, { kind: c.input.kind ?? 'batch', sql: c.input.sql, params: c.input.params })
      const started = Date.now()
      while (!fixture.requests.length && Date.now() - started < 5000) await new Promise(r => setTimeout(r, 10))
      assert.ok(fixture.requests.length, c.input.name + ': HTTP request did not start')
      const update = await capture(other, { kind: 'batch', sql: c.input.mutation })
      fixture.release()
      const result = await pending
      compare(update, c.update, c.input.name + ': observer')
      compare(result, c.result, c.input.name + ': inference')
      if (c.input.after) compare(await capture(conn, { kind: 'batch', sql: embeddingAfterSql(c.input, result) }), c.after, c.input.name + ': after module')
      assert.deepEqual(fixture.requests, c.requests, c.input.name + ': HTTP requests')
      if (c.input.cleanup) await query(conn, c.input.cleanup)
      await query(conn, 'DROP TABLE t; DROP EXTERNAL MODEL m;')
    }
    t.diagnostic(`${expected.cases.length} committed-prefix oracle cases matched`)
  } finally {
    await close(other)
    await close(conn)
    await server?.stop()
    await fixture.close()
  }
})

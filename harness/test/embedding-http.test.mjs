import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { connect, close } from '../src/client.mjs'
import { capture, query } from '../src/capture-core.mjs'
import { compareCase } from '../src/compare.mjs'
import { spawnEmulator, emulatorConfig } from '../src/emulator.mjs'
import { embeddingFixture } from '../src/embedding-fixture.mjs'

test('SQL embedding execution matches captured HTTPS exchanges', { timeout: 120000 }, async t => {
  const expected = JSON.parse(await readFile(new URL('../fixtures/embeddings.expected.json', import.meta.url), 'utf8'))
  const fixture = await embeddingFixture()
  let server, conn
  try {
    server = await spawnEmulator({ args: ['--http-ca', fixture.cert] })
    const config = emulatorConfig(server)
    conn = await connect(config)
    await query(conn, "EXEC sp_configure 'external rest endpoint enabled',1; RECONFIGURE;")
    const quote = s => "N'" + s.replaceAll("'", "''") + "'"
    const endpoint = `https://127.0.0.1:${fixture.port}/v1/embeddings`
    for (const c of expected.cases) {
      const input = c.input
      const parameters = input.parameters === undefined ? '' : `,PARAMETERS=${quote(JSON.stringify(input.parameters))}`
      await query(conn, `CREATE EXTERNAL MODEL m WITH(LOCATION=${quote(endpoint)},API_FORMAT=${quote(input.api)},MODEL_TYPE=EMBEDDINGS,MODEL=${quote(input.model ?? 'fixture')}${parameters});`)
      fixture.setResponse(input.response)
      const actual = JSON.parse(JSON.stringify(await capture(conn, { kind: 'batch', sql: input.sql })))
      const difference = compareCase({ steps: [actual] }, { steps: [c.result] })
      assert.equal(difference, null, input.name + ': ' + JSON.stringify({ difference, actual, expected: c.result }))
      assert.deepEqual(fixture.requests, c.requests, input.name + ': HTTP requests')
      if (input.fatal) {
        await close(conn)
        conn = await connect(config)
      }
      await query(conn, 'DROP EXTERNAL MODEL m;')
    }
    t.diagnostic(`${expected.cases.length} SQL/HTTP oracle cases matched`)
  } finally {
    await close(conn)
    await server?.stop()
    await fixture.close()
  }
})

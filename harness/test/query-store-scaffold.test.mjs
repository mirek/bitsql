import { test } from 'node:test'
import assert from 'node:assert/strict'
import { connect, close } from '../src/client.mjs'
import { capture } from '../src/capture-core.mjs'
import { compareCase } from '../src/compare.mjs'
import { loadCorpus, readExpected } from '../src/corpus.mjs'
import { server } from './support.mjs'

// Populated history must retain the oracle-captured catalog descriptors.
test('Query Store descriptors remain stable after workload and configuration changes', async t => {
  const [fixture] = await loadCorpus(['query-store/view-descriptors.sql'])
  const expected = await readExpected(fixture)
  const s = await server(t)
  const conn = await connect(s.config)
  t.after(() => close(conn))
  for (const setup of [
    'CREATE DATABASE qs_scaffold; USE qs_scaffold; ALTER DATABASE CURRENT SET QUERY_STORE = ON (QUERY_CAPTURE_MODE = ALL); CREATE TABLE dbo.workload(id int); INSERT dbo.workload VALUES(1),(2); SELECT id FROM dbo.workload; EXEC sys.sp_query_store_flush_db;',
    'ALTER DATABASE CURRENT SET QUERY_STORE (OPERATION_MODE = READ_ONLY); ALTER DATABASE CURRENT SET QUERY_STORE = OFF; ALTER DATABASE CURRENT SET QUERY_STORE = ON; ALTER DATABASE CURRENT SET QUERY_STORE CLEAR ALL;',
  ]) {
    const result = await capture(conn, { kind: 'batch', sql: setup })
    assert.deepEqual(result.errors, [])
    for (let i = 1; i < fixture.steps.length; i++) {
      const sql = fixture.steps[i].sql
      const actual = JSON.parse(JSON.stringify(await capture(conn, { kind: 'batch', sql })))
      assert.equal(compareCase({ steps: [actual] }, { steps: [expected.steps[i]] }), null, sql)
    }
  }
})

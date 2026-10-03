// Dumps seed rows for the catalog views (sys.objects system rows, sys.types,
// sys.databases) from a fresh oracle database into scripts/sysviews-seed.json.
// Usage (in harness/): node src/dump-sysviews-seed.mjs ../scripts/sysviews-seed.json
import { writeFileSync } from 'node:fs'
import { startOracle } from './oracle.mjs'
import { connect, close, withDatabase } from './client.mjs'
import { capture } from './capture-core.mjs'

const { config } = await startOracle()
let c = await connect(config)
const db = 'bitsql_seed'
await capture(c, { kind: 'batch', sql: `IF DB_ID('${db}') IS NOT NULL BEGIN ALTER DATABASE ${db} SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE ${db}; END; CREATE DATABASE ${db}` })
await close(c)
c = await connect(withDatabase(config, db))
const queries = {
  system_objects: `SELECT name, object_id, principal_id, schema_id, parent_object_id, type, type_desc, CONVERT(varchar(30), create_date, 126) AS create_date, CONVERT(varchar(30), modify_date, 126) AS modify_date FROM sys.objects WHERE is_ms_shipped = 1 ORDER BY object_id`,
  schemas: `SELECT name, schema_id, principal_id FROM sys.schemas ORDER BY schema_id`,
  types: `SELECT * FROM sys.types ORDER BY user_type_id`,
  databases: `SELECT * FROM sys.databases WHERE database_id <= 4 OR name = DB_NAME() ORDER BY database_id`,
}
const out = {}
for (const [k, sql] of Object.entries(queries)) {
  const r = await capture(c, { kind: 'batch', sql })
  if (r.errors.length) throw new Error(JSON.stringify(r.errors))
  out[k] = { columns: r.sets[0].columns.map(x => x.name), rows: r.sets[0].rows }
}
writeFileSync(process.argv[2], JSON.stringify(out, null, 1))
await capture(c, { kind: 'batch', sql: 'SELECT 1' })
await close(c)

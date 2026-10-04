// Dumps the rows of SQL Server's system objects (sys.system_objects), their
// columns (sys.system_columns) and the built-in server principals
// (sys.server_principals) from a fresh oracle database into compact TSV files
// read by scripts/gen-sysviews.py.
// Usage (in harness/): node src/dump-system-catalog.mjs ../scripts/system-catalog
//
// Only the columns that vary are dumped; the generator documents the
// constant ones (verified by the queries below, which fail if they vary).
import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { startOracle } from './oracle.mjs'
import { connect, close, withDatabase } from './client.mjs'
import { capture } from './capture-core.mjs'

const outDir = process.argv[2]
mkdirSync(outDir, { recursive: true })
const { config } = await startOracle()
let c = await connect(config)
const db = 'bitsql_seed'
await capture(c, { kind: 'batch', sql: `IF DB_ID('${db}') IS NOT NULL BEGIN ALTER DATABASE ${db} SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE ${db}; END; CREATE DATABASE ${db}` })
await close(c)
c = await connect(withDatabase(config, db))

async function rows(sql) {
  const r = await capture(c, { kind: 'batch', sql })
  if (r.errors.length) throw new Error(JSON.stringify(r.errors))
  return r.sets[0].rows
}

// Constant columns must stay constant (else the generator is wrong).
const checks = {
  system_objects: `SELECT COUNT(*) FROM sys.system_objects WHERE principal_id IS NOT NULL OR parent_object_id <> 0 OR is_ms_shipped <> 1 OR is_published <> 0 OR is_schema_published <> 0`,
  system_columns: `SELECT COUNT(*) FROM sys.system_columns WHERE is_rowguidcol <> 0 OR is_identity <> 0 OR is_computed <> 0 OR is_filestream <> 0 OR is_replicated <> 0 OR is_non_sql_subscribed <> 0 OR is_merge_published <> 0 OR is_dts_replicated <> 0 OR is_xml_document <> 0 OR xml_collection_id <> 0 OR default_object_id <> 0 OR rule_object_id <> 0 OR is_sparse <> 0 OR is_column_set <> 0 OR generated_always_type <> 0 OR generated_always_type_desc <> N'NOT_APPLICABLE' OR encryption_type IS NOT NULL OR encryption_type_desc IS NOT NULL OR encryption_algorithm_name IS NOT NULL OR column_encryption_key_id IS NOT NULL OR column_encryption_key_database_name IS NOT NULL OR is_hidden <> 0 OR is_masked <> 0 OR graph_type IS NOT NULL OR graph_type_desc IS NOT NULL OR is_data_deletion_filter_column <> 0 OR ledger_view_column_type IS NOT NULL OR ledger_view_column_type_desc IS NOT NULL OR is_dropped_ledger_column <> 0 OR vector_dimensions IS NOT NULL OR vector_base_type IS NOT NULL OR vector_base_type_desc IS NOT NULL`,
}
for (const [k, sql] of Object.entries(checks)) {
  const n = (await rows(sql))[0][0]
  if (n !== 0) throw new Error(`${k}: ${n} rows with non-constant columns`)
}

const esc = v => v === null ? '\\N' : String(v).replace(/\\/g, '\\\\').replace(/\t/g, '\\t').replace(/\n/g, '\\n')
const dt = d => d.value.replace('Z', '')
const tsv = (header, rs) => header.join('\t') + '\n' + rs.map(r => r.map(esc).join('\t')).join('\n') + '\n'

const objs = await rows(`SELECT name, object_id, schema_id, RTRIM(type), type_desc, CONVERT(varchar(30), create_date, 126), CONVERT(varchar(30), modify_date, 126) FROM sys.system_objects ORDER BY object_id`)
writeFileSync(join(outDir, 'system_objects.tsv'), tsv(['name', 'object_id', 'schema_id', 'type', 'type_desc', 'create_date', 'modify_date'], objs))

const cols = await rows(`SELECT object_id, name, column_id, system_type_id, user_type_id, max_length, precision, scale, collation_name, CAST(is_nullable AS int), CAST(is_ansi_padded AS int) FROM sys.system_columns ORDER BY object_id, column_id`)
writeFileSync(join(outDir, 'system_columns.tsv'), tsv(['object_id', 'name', 'column_id', 'system_type_id', 'user_type_id', 'max_length', 'precision', 'scale', 'collation_name', 'is_nullable', 'is_ansi_padded'], cols))

const princ = await rows(`SELECT name, principal_id, CONVERT(varchar(200), sid, 2), type, type_desc, CAST(is_disabled AS int), CONVERT(varchar(30), create_date, 126), CONVERT(varchar(30), modify_date, 126), default_database_name, default_language_name, credential_id, owning_principal_id, CAST(is_fixed_role AS int), CONVERT(varchar(36), tenant_id) FROM sys.server_principals ORDER BY principal_id`)
writeFileSync(join(outDir, 'server_principals.tsv'), tsv(['name', 'principal_id', 'sid', 'type', 'type_desc', 'is_disabled', 'create_date', 'modify_date', 'default_database_name', 'default_language_name', 'credential_id', 'owning_principal_id', 'is_fixed_role', 'tenant_id'], princ))
console.log(`system_objects ${objs.length}, system_columns ${cols.length}, server_principals ${princ.length}`)
await close(c)

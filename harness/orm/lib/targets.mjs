// Targets for the ORM suite: the SQL Server oracle (docker container
// bitsql-oracle, see ../../src/oracle.mjs) and the bitsql emulator (BITSQL_ADDR,
// BITSQL_BIN or a fresh `moon build`, see ../../src/emulator.mjs).
//
// Every workload gets its own database on each target (`bitsql_orm_<orm>`),
// dropped and recreated before the run, so ORM runs never collide with each
// other nor with corpus captures (bitsql_case_*).
import { startOracle } from '../../src/oracle.mjs'
import { emulatorBinary, fixedAddress, probe, spawnEmulator } from '../../src/emulator.mjs'
import { connect, close } from '../../src/client.mjs'
import { Request } from 'tedious'

function exec(connection, sql) {
  return new Promise((resolve, reject) => {
    const rows = []
    const request = new Request(sql, error => error ? reject(error) : resolve(rows))
    request.on('row', columns => rows.push(columns.map(c => c.value)))
    connection.execSqlBatch(request)
  })
}

function adminConfig(t) {
  return {
    server: t.host,
    authentication: { type: 'default', options: { userName: t.user, password: t.password } },
    options: { port: t.port, database: 'master', encrypt: t.encrypt, trustServerCertificate: true, connectTimeout: 30000, requestTimeout: 120000 },
  }
}

async function withAdmin(t, fn) {
  let last
  for (let attempt = 0; attempt < 3; attempt++) {
    let connection
    try {
      connection = await connect(adminConfig(t))
      return await fn(connection)
    } catch (error) {
      last = error
      if (!/timeout|ETIMEOUT|ESOCKET/i.test(`${error.code} ${error.message}`)) throw error
    } finally { await close(connection) }
  }
  throw last
}

// Fresh, empty database `name` on target `t` (dropped first if it exists).
export async function freshDatabase(t, name) {
  await withAdmin(t, async c => {
    await exec(c, `IF DB_ID(N'${name}') IS NOT NULL BEGIN ALTER DATABASE [${name}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [${name}]; END`)
    await exec(c, `CREATE DATABASE [${name}]`)
  })
}

export async function dropDatabase(t, name) {
  try {
    await withAdmin(t, c => exec(c, `IF DB_ID(N'${name}') IS NOT NULL BEGIN ALTER DATABASE [${name}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [${name}]; END`))
  } catch { /* best effort */ }
}

export async function oracle({ log = () => {} } = {}) {
  const { config } = await startOracle({ log })
  return {
    name: 'oracle',
    host: config.server,
    port: config.options.port,
    user: config.authentication.options.userName,
    password: config.authentication.options.password,
    encrypt: true,
    stop: async () => {},
  }
}

export async function emulator({ log = () => {} } = {}) {
  const fixed = fixedAddress()
  if (fixed) {
    const error = await probe(fixed)
    if (error) throw error
    return { name: 'emulator', ...fixed, user: 'sa', password: 'bitsql', encrypt: true, stop: async () => {} }
  }
  const bin = emulatorBinary({ log })
  const server = await spawnEmulator({ bin })
  const error = await probe(server)
  if (error) { await server.stop(); throw error }
  return { name: 'emulator', host: server.host, port: server.port, user: 'sa', password: 'bitsql', encrypt: true, stop: server.stop, logs: server.logs }
}

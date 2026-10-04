// tedious connection helpers shared by the oracle and emulator targets.
import { Connection } from 'tedious'

export async function connect(config) {
  const connection = new Connection(config)
  // An 'error' without a listener would crash the process (socket resets etc.).
  connection.on('error', () => {})
  try {
    await new Promise((resolve, reject) => connection.connect(error => error ? reject(error) : resolve()))
    return connection
  } catch (error) { connection.close(); throw error }
}

export function close(connection) {
  if (!connection || connection.closed) return Promise.resolve()
  return new Promise(resolve => {
    const timer = setTimeout(resolve, 2000)
    connection.once('end', () => { clearTimeout(timer); resolve() })
    connection.close()
  })
}

// A tedious config for a target address. `tls` is tedious's encrypt option:
// true (its default, used for both the oracle and the emulator) sends
// ENCRYPT_ON in PRELOGIN; false sends ENCRYPT_NOT_SUP (plaintext session).
export function tediousConfig({ host, port, user = 'sa', password = 'bitsql', database = 'master', tls = true, requestTimeout = 30000, connectTimeout = 15000 }) {
  return {
    server: host,
    authentication: { type: 'default', options: { userName: user, password } },
    options: {
      port, database, encrypt: tls, trustServerCertificate: true,
      connectTimeout, requestTimeout,
      useColumnNames: false, rowCollectionOnRequestCompletion: false, rowCollectionOnDone: false,
    },
  }
}

export function withDatabase(config, database) {
  return { ...config, options: { ...config.options, database } }
}

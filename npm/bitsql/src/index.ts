// bitsql for Node: the SQL Server emulator's engine as WebAssembly, served
// over TDS on a local port from inside the calling process.
import { launch } from './launch'

/** Options for {@link start}. */
export interface StartOptions {
  /** Interface to listen on. Default `127.0.0.1`. */
  host?: string
  /** TCP port. Default `0`: the OS picks a free port (read it from {@link BitsqlServer.port}). */
  port?: number
  /** Databases created at start, besides master, tempdb, model and msdb. */
  databases?: string[]
  /** Logins to unknown databases create them instead of failing with error 4060 (not SQL Server behavior). */
  autoCreateDatabases?: boolean
  /**
   * TLS. Default `true`: a built-in self-signed localhost certificate whose
   * private key is public (tests only). `false` refuses encryption; clients
   * then need `encrypt: false`. `{ key, cert }`: PEM contents.
   */
  tls?: boolean | { key: string | Uint8Array; cert: string | Uint8Array }
  /** PEM trust roots for outbound HTTPS (embedding calls). Default: Node's bundled roots. */
  httpCa?: string | Uint8Array
  /** Work units per request before it fails with error 50108 (runaway protection). */
  maxRequestWork?: number
  /** Append every engine event to this file, for the `replay` tool. */
  record?: string
  /** User name placed in the returned client configs. Any name is accepted. Default `sa`. */
  user?: string
  /** Password placed in the returned client configs. Any password is accepted. Default `bitsql`. */
  password?: string
  /** Receives the server's log lines (such as TLS failures). Default: discarded. */
  onLog?: (line: string) => void
}

/** A `tedious` `ConnectionConfiguration`. */
export interface TediousConfig {
  server: string
  authentication: { type: 'default'; options: { userName: string; password: string } }
  options: { port: number; database: string; encrypt: boolean; trustServerCertificate: true }
}

/** An `mssql` `config` object. */
export interface MssqlConfig {
  server: string
  port: number
  database: string
  user: string
  password: string
  options: { encrypt: boolean; trustServerCertificate: true }
}

/** A running server. All data lives in memory and is gone after {@link stop}. */
export interface BitsqlServer {
  /** Address clients connect to (`127.0.0.1` when listening on `0.0.0.0`). */
  readonly host: string
  readonly port: number
  /** Stops listening and drops all connections and data. Safe to call more than once. */
  stop(): Promise<void>
  /** ADO.NET-style connection string, e.g. for `mssql.connect(string)`. */
  connectionString(database?: string): string
  /** Configuration for `new Connection(config)` from `tedious`. */
  tedious(database?: string): TediousConfig
  /** Configuration for `mssql.connect(config)` / `new ConnectionPool(config)`. */
  mssql(database?: string): MssqlConfig
}

const pem = (v: string | Uint8Array) => (typeof v === 'string' ? v : Buffer.from(v))

/** Version of this package, equal to the engine's release (`SELECT @@VERSION` names it). */
export const version: string = require('../package.json').version

/**
 * Starts a server in a worker thread of this process and resolves once it
 * accepts connections. It never keeps the process alive: a forgotten
 * `stop()` doesn't hang a test runner.
 */
export async function start(options: StartOptions = {}): Promise<BitsqlServer> {
  const address = await launch({
    host: options.host ?? '127.0.0.1',
    port: options.port ?? 0,
    databases: options.databases ?? [],
    autoCreateDatabases: options.autoCreateDatabases ?? false,
    maxRequestWork: options.maxRequestWork === undefined ? -1n : BigInt(options.maxRequestWork),
    tls: typeof options.tls === 'object' ? { key: pem(options.tls.key), cert: pem(options.tls.cert) } : options.tls === false ? false : undefined,
    httpCa: options.httpCa === undefined ? undefined : Buffer.from(options.httpCa),
    record: options.record,
  }, options.onLog ?? (() => {}), false)
  const server = address.host === '0.0.0.0' || address.host === '::' ? '127.0.0.1' : address.host
  const { port } = address
  const user = options.user ?? 'sa'
  const password = options.password ?? 'bitsql'
  const encrypt = options.tls !== false
  return {
    host: server,
    port,
    stop: address.stop,
    connectionString: (database = 'master') =>
      `Server=${server},${port};Database=${database};User Id=${user};Password=${password};` +
      `Encrypt=${encrypt};TrustServerCertificate=true`,
    tedious: (database = 'master') => ({
      server,
      authentication: { type: 'default', options: { userName: user, password } },
      options: { port, database, encrypt, trustServerCertificate: true },
    }),
    mssql: (database = 'master') => ({
      server,
      port,
      database,
      user,
      password,
      options: { encrypt, trustServerCertificate: true },
    }),
  }
}

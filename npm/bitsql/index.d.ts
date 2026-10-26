/** Options for {@link start}. Each maps to a server command-line flag. */
export interface StartOptions {
  /** Interface to listen on. Default `127.0.0.1`. */
  host?: string
  /** TCP port. Default `0`: the OS picks a free port (read it from {@link BitsqlServer.port}). */
  port?: number
  /** Databases created at startup (`--database`), besides master, tempdb, model and msdb. */
  databases?: string[]
  /** Logins to unknown databases create them instead of failing with error 4060 (not SQL Server behavior). */
  autoCreateDatabases?: boolean
  /**
   * TLS. Default `true`: a built-in self-signed localhost certificate whose
   * private key is public (tests only). `false` refuses encryption
   * (`--no-tls`); clients then need `encrypt: false`. `{ cert, key }` are PEM
   * file paths.
   */
  tls?: boolean | { cert: string; key: string }
  /** PEM trust roots for outbound HTTPS (`--http-ca`). Default: system roots. */
  httpCa?: string
  /** Work units per request before it fails with error 50108 (`--max-request-work`). */
  maxRequestWork?: number
  /** Microseconds to poll for the next request before sleeping (`--spin-us`, default 100; 0 sleeps at once). */
  spinUs?: number
  /** Append every engine event to this file for `replay` (`--record`). */
  record?: string
  /** Extra command-line arguments, appended last. */
  args?: string[]
  /** User name placed in the returned client configs. Any name is accepted. Default `sa`. */
  user?: string
  /** Password placed in the returned client configs. Any password is accepted. Default `bitsql`. */
  password?: string
  /** Executable to run. Default: `BITSQL_BIN`, else the platform package's binary. */
  binary?: string
  /** Milliseconds to wait for the server to listen. Default 10000. */
  timeout?: number
  /** Receives the server's stderr output as it arrives. */
  onLog?: (chunk: string) => void
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

/** A running server. All data lives in its memory and is gone after {@link stop}. */
export interface BitsqlServer {
  /** Address clients connect to (`127.0.0.1` when listening on `0.0.0.0`). */
  readonly host: string
  readonly port: number
  readonly pid: number | undefined
  /** Terminates the server and resolves once it has exited. Safe to call more than once. */
  stop(): Promise<void>
  /** Server stderr so far (the last 64 KiB). */
  logs(): string
  /** ADO.NET-style connection string, e.g. for `mssql.connect(string)`. */
  connectionString(database?: string): string
  /** Configuration for `new Connection(config)` from `tedious`. */
  tedious(database?: string): TediousConfig
  /** Configuration for `mssql.connect(config)` / `new ConnectionPool(config)`. */
  mssql(database?: string): MssqlConfig
}

/**
 * Starts a bitsql server as a child process and resolves once it accepts
 * connections (typically well under 100 ms). The process is killed when the
 * calling Node process exits, and does not keep it alive.
 */
export function start(options?: StartOptions): Promise<BitsqlServer>

/** Path of the native executable: `BITSQL_BIN`, else the binary of the installed platform package. */
export function binaryPath(): string

/** Version of this package, equal to the server's version. */
export const version: string

declare const bitsql: {
  start: typeof start
  binaryPath: typeof binaryPath
  version: typeof version
}
export default bitsql

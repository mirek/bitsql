# bitsql

A memory-only SQL Server emulator that `tedious` / `mssql` clients reach over
TDS. Start it from your test setup instead of running the
`mcr.microsoft.com/mssql/server` container: it is ready in well under 100 ms
and idles at a few MB of RAM. No Docker, no EULA, no password rules.

Behavior is checked against captures from real SQL Server 2025. A feature the
emulator doesn't support fails with an `Emulator: …` error (50100–50199)
instead of returning a guess. See the
[project README](https://github.com/mirek/bitsql#readme) for coverage and
benchmarks.

```bash
npm install --save-dev bitsql
```

Platforms: Linux x64 (glibc 2.34+). Elsewhere, point `BITSQL_BIN` at a bitsql
executable, or use the `mirek/bitsql` Docker image.

## Jest / Vitest / node:test

```ts
import { start, type BitsqlServer } from 'bitsql'
import { Connection } from 'tedious'

let server: BitsqlServer

beforeAll(async () => {
  server = await start({ databases: ['app'] })
})
afterAll(() => server.stop())

test('query', async () => {
  const connection = new Connection(server.tedious('app'))
  // …
})
```

Each `start()` is an independent server on a free port, so parallel test files
(Jest workers) never share data. With `mssql`:

```ts
import mssql from 'mssql'

const pool = await new mssql.ConnectionPool(server.mssql('app')).connect()
// or: await mssql.connect(server.connectionString('app'))
```

One server for the whole run, via Jest `globalSetup` / `globalTeardown`:

```js
// jest.global-setup.js
const { start } = require('bitsql')
module.exports = async () => {
  globalThis.bitsql = await start({ autoCreateDatabases: true })
  process.env.DB_PORT = String(globalThis.bitsql.port) // read by the tests' config
}
// jest.global-teardown.js
module.exports = () => globalThis.bitsql.stop()
```

For fast isolation between tests, seed once, run
`EXEC emulator.snapshot 'seed'`, then `EXEC emulator.restore 'seed'` in
`beforeEach`.

## API

`start(options?) → Promise<BitsqlServer>`. All options are optional:

| Option | Default | |
| --- | --- | --- |
| `port` | `0` (free port) | TCP port |
| `host` | `127.0.0.1` | interface to listen on |
| `databases` | `[]` | databases created at start (master, tempdb, model, msdb always exist) |
| `autoCreateDatabases` | `false` | logins to unknown databases create them instead of failing with 4060 |
| `tls` | `true` | built-in self-signed certificate (tests only); `false` refuses encryption; `{ cert, key }` PEM paths |
| `user`, `password` | `sa`, `bitsql` | placed in the returned configs; any credentials are accepted |
| `maxRequestWork` | | work units per request before error 50108 |
| `timeout` | `10000` | ms to wait for the server to listen |
| `onLog` | | receives server stderr |
| `binary` | `BITSQL_BIN`, else the platform package | executable to run |
| `args` | `[]` | extra server arguments |

`BitsqlServer`: `host`, `port`, `pid`, `stop()`, `tedious(database?)`,
`mssql(database?)`, `connectionString(database?)`, `logs()`. The server is
killed when the Node process exits and never keeps it alive, so a forgotten
`stop()` doesn't hang the test runner.

`npx bitsql [--listen 127.0.0.1:1433] [--database app] …` runs the server in
the foreground.

## License

CC0-1.0 (public domain). Third-party notices are included in the package.

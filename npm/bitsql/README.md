# bitsql

A memory-only SQL Server emulator that `tedious` / `mssql` clients reach over
TDS, compiled to WebAssembly. Start it inside your test process, with no
Docker, native binaries, EULA or password rules. It's ready in about 70 ms
and runs on any OS with Node 22+.

Behavior is checked against captures from real SQL Server 2025. A feature the
emulator doesn't support fails with an `Emulator: …` error (50100–50199)
instead of returning a guess. See the
[project README](https://github.com/mirek/bitsql#readme) for coverage.

```bash
npm install --save-dev bitsql
```

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

One server for the whole run, via Jest `globalSetup` / `globalTeardown`
(the server runs in Jest's main process; workers connect over TCP):

```js
// jest.global-setup.js
const { start } = require('bitsql')
module.exports = async () => {
  globalThis.bitsql = await start({ port: 14330, autoCreateDatabases: true })
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
| `tls` | `true` | built-in self-signed certificate (tests only); `false` refuses encryption; `{ key, cert }` PEM |
| `user`, `password` | `sa`, `bitsql` | placed in the returned configs; any credentials are accepted |
| `maxRequestWork` | | work units per request before error 50108 |
| `httpCa` | Node's roots | PEM trust roots for outbound HTTPS (embedding calls) |
| `onLog` | discarded | receives server log lines |
| `record` | | event log file for the `replay` tool |

`BitsqlServer`: `host`, `port`, `stop()`, `tedious(database?)`,
`mssql(database?)`, `connectionString(database?)`. The server never keeps
the Node process alive, so a forgotten `stop()` doesn't hang the test runner.

The engine runs on the calling thread: a long query blocks that thread's
event loop until it finishes, just as a synchronous function would.

`npx bitsql [--listen 127.0.0.1:1433] [--database app] …` runs a server in
the foreground, with the same options as the `mirek/bitsql` image.

## License

CC0-1.0 (public domain). Third-party notices are included in the package.

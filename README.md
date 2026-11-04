# bitsql

A memory-only SQL Server emulator written in [MoonBit](https://www.moonbitlang.com).
Real `tedious` / `mssql` clients connect to it over TDS, so test suites can drop
the ~1.6 GB `mssql/server` container in favor of a 35 MB image that starts in
about 0.13 s and idles at about 5 MB of RAM ([benchmarks](#benchmarks)).

Ready to try in application CI as a lightweight replacement for the SQL Server
2025 container. [Try SQL in your browser](https://mirek.github.io/bitsql/) or
follow the container swap below. See [SQL Server 2025 coverage](#sql-server-2025-coverage)
for the release boundary and [the roadmap](docs/design/roadmap.md) for ongoing work.

Behavior is checked against captures from real SQL Server. A feature the
emulator doesn't support fails with an `Emulator: …` error (numbers
50100–50199) instead of returning a guess. The deliberate exception is
[Query Store and diagnostic history](docs/design/query-store.md) record native
statement executions and index usage. Optional
[query diagnostics](docs/design/query-diagnostics.md) inspect execution on demand.

Some core arithmetic is formally verified, not only tested: on every gate run
`moon prove` checks with SMT solvers that the TDS packet reader's bounds check
never overflows or accepts a truncated packet, that date ↔ day-number
conversion stays inside 0001–9999, that `datetime2`/`time` scale rounding is
exact half-up and never leaves the day, and that legacy `datetime` 1/300 s
rounding round-trips and carries midnight into the next day. Writing these
specs exposed two bugs, both fixed: a packet that could crash the server and a
`GETDATE()` that could return 24:00. See
[formal proofs](docs/design/verification.md#formal-proofs-moon-prove).

```bash
docker run --rm -p 1433:1433 mirek/bitsql --auto-create-databases
```

Published image: `mirek/bitsql` (tags `X.Y.Z`, `X.Y`, `latest`). Release 0.1.31
publishes native-validated amd64; inspect the tag’s manifest for availability.
Other architectures require validation and publication on their native hosts.
`SELECT @@VERSION` returns `mirek/bitsql@X.Y.Z`, so you can tell which release
you're connected to, and the image has `org.opencontainers.image.version` and
`revision` labels.

## Drop-in replacement for `mcr.microsoft.com/mssql/server`

Change the image name. Connection settings stay the same:

- **Credentials:** any user name and password are accepted, so the existing
  `sa` / `MSSQL_SA_PASSWORD` values keep working. `ACCEPT_EULA`,
  `MSSQL_SA_PASSWORD`, `MSSQL_PID` and other `MSSQL_*` variables are ignored.
- **Port:** 1433 inside the container.
- **TLS:** works with tedious / mssql defaults (`encrypt: true` plus
  `trustServerCertificate: true`, as for SQL Server's self-signed
  certificate), and with `encrypt: false`. Prisma URLs work with
  `encrypt=true` or `encrypt=false`. The built-in certificate's private key
  is public (it's in the source), so the default TLS protects nothing. It is
  for tests only. Pass `--tls-cert`/`--tls-key` for anything else.
- **Databases:** `master`, `tempdb`, `model` and `msdb` exist at start.
  `CREATE DATABASE` works. If the tests connect straight to a database that
  nothing creates, start the server with `--database NAME` (repeatable) or
  `--auto-create-databases`. Otherwise the login fails with error 4060, as it
  does on SQL Server.
- **Memory only:** all data is lost when the container stops, so volumes
  under `/var/opt/mssql` have no effect and can be removed.
- **Health checks:** the image is minimal and hardened, so it has no shell
  and no `sqlcmd`. Replace `sqlcmd` health checks with a TCP or login probe. Since
  the server is ready about 0.1 s after start, most suites can drop the wait
  entirely.

docker compose:

```yaml
services:
  db:
    image: mirek/bitsql:0.1              # was mcr.microsoft.com/mssql/server:2025-latest
    command: ["--auto-create-databases"]
    ports: ["1433:1433"]
    environment:                         # optional; kept for SQL Server parity, ignored
      ACCEPT_EULA: "Y"
      MSSQL_SA_PASSWORD: "Your_password123"
```

GitHub Actions: `services:` can't pass server arguments. Either create the
database in test setup, or start the container in a step:

```yaml
steps:
  - run: docker run -d --name db -p 1433:1433 mirek/bitsql:0.1 --database app
  - run: npm test   # Server=localhost,1433; Database=app; User Id=sa; Password=anything
```

Testcontainers (Node). The `MSSQLServerContainer` module waits for SQL
Server's log lines, so use a generic container:

```js
import { GenericContainer, Wait } from 'testcontainers'

const db = await new GenericContainer('mirek/bitsql:0.1')
  .withCommand(['--auto-create-databases'])
  .withExposedPorts(1433)
  .withWaitStrategy(Wait.forListeningPorts())
  .start()
const config = {
  server: db.getHost(),
  authentication: { type: 'default', options: { userName: 'sa', password: 'x' } },
  options: { port: db.getMappedPort(1433), database: 'app', trustServerCertificate: true },
}
```

For fast test isolation, seed once, run `EXEC emulator.snapshot 'seed'`, then
run `EXEC emulator.restore 'seed'` before each test.

Clients checked by the harness: tedious and mssql (Node), plus knex,
Sequelize, TypeORM and Prisma through `harness/orm`.

Server options (append them after the image name): `--version`, `--listen HOST:PORT`, `--database NAME`
(repeatable), `--auto-create-databases`, `--tls-cert FILE --tls-key FILE`
(PEM; default a built-in self-signed localhost certificate), `--no-tls`,
`--http-ca FILE` (PEM trust roots for outbound HTTPS; default system roots),
`--max-request-work N` (runaway-request budget; a request past it fails with
Emulator error 50108), `--record FILE` (event log for `replay`), `--spin-us N`
(after a request, poll N µs for the next one before sleeping, as SQL Server's
schedulers do: lower latency for back-to-back requests at the cost of CPU
while they run; default 100, `0` sleeps at once).

## Node tests without Docker (npm)

The `bitsql` npm package runs the same engine compiled to WebAssembly, with
a thin TypeScript host for sockets, TLS and timers. It starts from test setup
on any OS with Node 22+, with TypeScript typings included. There's no
container, no native binary and no EULA:

```bash
npm install --save-dev bitsql
```

```ts
import { start, type BitsqlServer } from "bitsql"
import { Connection } from "tedious"

let server: BitsqlServer
beforeAll(async () => { server = await start({ databases: ["app"] }) })
afterAll(() => server.stop())

test("query", () => {
  const connection = new Connection(server.tedious("app")) // or server.mssql("app"), server.connectionString("app")
  // …
})
```

Each `start()` runs its own server in a worker thread on a free port, so
parallel Jest workers never share data, and a forgotten `stop()` doesn't
keep the runner alive. Startup takes about 0.1 s. Queries run about 1.5–2.5×
slower than the native image, which is still fast for tests. Every release
passes the same client suite as the image. Options and a Jest `globalSetup`
example: [npm/bitsql/README.md](npm/bitsql/README.md).

## Row ordering compatibility

Queries without `ORDER BY` can return a different row order from SQL Server.
In particular, bitsql scans can retain insertion order where SQL Server chooses
an ordered clustered or covering unique-index scan. Add `ORDER BY` on the
required keys to table listings and other order-sensitive queries.

`MERGE` can also expose a different order through a trigger's `inserted` table,
changing identity assignment in an audit table. Compare audit events by business
keys and contents, rather than assuming identity order follows the source rows.
Captured examples and the SQL Server version differences are recorded in
[the compatibility findings](docs/reference/compatibility-2026-10-05.md).

## SQL Server 2025 coverage

bitsql targets SQL Server 2025 (17.x), using oracle
captures from 17.0.5005.3. Coverage is aimed at application CI: tested SQL,
metadata, TDS and ORM behavior. It does not imply complete server equivalence.
See the [feature audit](docs/design/sql2025-audit.md) and
[deferred work](docs/design/sql2025-future-work.md) for the release boundary.
Operational backup/replica features, optimizer internals and advanced inference
concurrency remain outside this release. Concurrent table changes during an
embedding HTTP wait raise an explicit unsupported error.

Native execution history now populates Query Store under `QUERY_CAPTURE_MODE=ALL`,
with real counts, host-measured durations/CPU, numeric modeled logical reads,
zero physical reads, linked runtime intervals and
flush/clear/reset/remove behavior. Diagnostic views expose query and index usage,
partition statistics, host facts and scoped missing-index advice. Monitoring is
not complete SQL Server equivalence: AUTO/CUSTOM admission, nested statement
profiling, Showplan, forcing, retention quotas and SQL Server resource accounting
remain outside this implementation. See the [supported boundary](docs/design/query-store.md).

## Query diagnostics

Inspect bitsql's logical plan without executing, or execute once with counters:

```sql
EXEC emulator.explain @sql = N'SELECT id FROM orders WHERE id = 42';
EXEC emulator.profile @sql = N'SELECT TOP 10 id FROM orders ORDER BY total DESC';
```

Explain returns `plan_text` and versioned `report_json`. Profile first returns the
query's ordinary result, then the same report with storage access counters,
returned rows, work units and observed join/sort/Top-N choices. Collection is
**off by default**: only `emulator.profile` instruments execution, and it retains
no history. These are bitsql plans, not SQL Server cost estimates or Showplan.
See [usage, counter definitions and limitations](docs/design/query-diagnostics.md).

## Benchmarks

The 0.1.31 native amd64 release image, `mirek/bitsql:0.1.31` (a
profile-guided build on the hardened Wolfi base), vs
`mcr.microsoft.com/mssql/server:2025-latest` (Developer edition, default
settings), linux/amd64, AMD Ryzen 9 7950X3D, Docker 29.1.3, 2026-11-04. Both
containers ran one after the other on this shared host; the client is
tedious over loopback with TLS. All metrics are lower-is-better. Query/DML
shapes are medians of five checked runs after one warm-up; the total sums
those medians. Point SELECTs are the median of five 1000-query batches after
warm-up. Compressed download sizes come from the published amd64 registry
manifests (SQL Server's from the 0.1.28 run of the same image digest).

|  | bitsql | SQL Server | % of SQL Server | Factor |
| --- | ---: | ---: | ---: | ---: |
| Image download (compressed) | 13.0 MiB | 604.5 MiB | 2.2% | 46× better |
| Image size on disk | 33.5 MiB | 1.64 GiB | 2.0% | 50× better |
| Cold start: `docker run` → first query (median) | 129 ms | 2.71 s | 4.7% | 21× better |
| CPU time until ready | 21.0 ms | 3.16 s | 0.7% | 151× better |
| Memory idle after start | 4.2 MiB | 1.17 GiB | 0.4% | 283× better |
| Memory after workload | 47.8 MiB | 1.22 GiB | 3.8% | 26× better |
| Memory peak (incl. page cache) | 47.8 MiB | 1.24 GiB | 3.8% | 27× better |
| Login (new connection, TLS, median) | 1.84 ms | 48.8 ms | 3.8% | 27× better |
| `SELECT 1` round trip (median) | 0.09 ms | 0.14 ms | 60% | 1.7× better |
| Drop + create 2-table schema (median) | 0.12 ms | 6.65 ms | 1.8% | 54× better |
| 1000 parameterized INSERTs | 139 ms | 920 ms | 15% | 6.6× better |
| 1000 parameterized point SELECTs (median of 5) | 108 ms | 122 ms | 88% | 1.1× better |
| 200 transactions (INSERT + UPDATE) | 36.4 ms | 213 ms | 17% | 5.9× better |
| Join + GROUP BY report (median) | 0.68 ms | 0.80 ms | 85% | 1.2× better |
| Load 20000 + 20000 rows (GENERATE_SERIES) | 33.3 ms | 50.8 ms | 66% | 1.5× better |
| 24 query/DML shapes over 20000 rows (total) | 216 ms | 635 ms | 34% | 2.9× better |

| Shape (20000 rows) | bitsql | SQL Server | % of SQL Server | Factor |
| --- | ---: | ---: | ---: | ---: |
| GROUP BY p (997 groups) | 1.06 ms | 2.63 ms | 40% | 2.5× better |
| GROUP BY v (5003 groups) | 3.92 ms | 4.66 ms | 84% | 1.2× better |
| SELECT DISTINCT v | 3.36 ms | 4.25 ms | 79% | 1.3× better |
| COUNT(DISTINCT v) | 2.39 ms | 3.61 ms | 66% | 1.5× better |
| UNION | 5.02 ms | 7.52 ms | 67% | 1.5× better |
| EXCEPT | 5.62 ms | 6.34 ms | 89% | 1.1× better |
| INTERSECT | 2.48 ms | 4.09 ms | 61% | 1.7× better |
| IN (uncorrelated subquery) | 3.58 ms | 4.63 ms | 77% | 1.3× better |
| NOT IN (uncorrelated subquery) | 2.04 ms | 2.94 ms | 70% | 1.4× better |
| EXISTS (correlated, unindexed) | 4.31 ms | 4.66 ms | 93% | 1.1× better |
| scalar subquery (correlated) | 3.07 ms | 4.53 ms | 68% | 1.5× better |
| scalar subquery (uncorrelated) | 3.92 ms | 4.25 ms | 92% | 1.1× better |
| equi-join | 1.41 ms | 4.61 ms | 31% | 3.3× better |
| ORDER BY v | 2.00 ms | 2.45 ms | 82% | 1.2× better |
| ORDER BY v after a shared non-ASCII prefix | 3.41 ms | 3.31 ms | 103% | same |
| ORDER BY accented text | 2.41 ms | 2.96 ms | 81% | 1.2× better |
| ROW_NUMBER over v | 4.21 ms | 5.46 ms | 77% | 1.3× better |
| DELETE WHERE IN (subquery) | 11.8 ms | 97.1 ms | 12% | 8.2× better |
| UPDATE FROM join | 19.6 ms | 28.5 ms | 69% | 1.5× better |
| UPDATE all rows | 17.3 ms | 26.4 ms | 65% | 1.5× better |
| INSERT with FOREIGN KEY | 20.1 ms | 39.5 ms | 51% | 2.0× better |
| DELETE parent rows (FK checked) | 26.4 ms | 117 ms | 23% | 4.4× better |
| DELETE with ON DELETE CASCADE | 46.5 ms | 223 ms | 21% | 4.8× better |
| MERGE | 20.4 ms | 29.5 ms | 69% | 1.4× better |

Query/DML shapes: median of 5 timed runs after one warm-up; total is the sum of those medians.

images: bitsql=mirek/bitsql:0.1.31, mssql=mcr.microsoft.com/mssql/server:2025-latest@sha256:2b5b581621126574f3d1f75e78d3eebe8d05aedb59ad0cfdf9aa42cb0634d726
Point SELECTs: median of five 1000-query batches after one full warm-up batch; all executions check SQL errors.

Every row but one is better than SQL Server in this run. ORDER BY after a
shared non-ASCII prefix tied (3.41 vs 3.31 ms; 2.16 vs 2.82 ms in the 0.1.29
run). Point SELECTs won again (108 vs 122 ms), though both sides ran slower
than in the 0.1.29 run, so the host was busier. Shared-host measurements
vary between runs. These measurements include native statement-history
collection but do not isolate its overhead or benchmark Query Store capture
mode ALL. See [the measurements and methodology](docs/design/performance.md)
and the [raw samples](website/public/benchmark-0.1.31.json).

To reproduce (pulls both images; uses containers `bitsql-bench-*` on ports
47340/47341 and removes them afterwards):

```bash
cd harness && npm install
npm run bench:compare                            # prints these tables
npm run bench:compare -- --starts 5 --json out/bench-compare.json
npm run bench:compare -- --from out/bench-compare.json   # re-render tables only
BITSQL_IMAGE=bitsql:dev npm run bench:compare -- --only bitsql
```

## Website and browser playground

The [website](https://mirek.github.io/bitsql/) includes measured comparisons,
a container migration guide, and the actual SQL engine running locally in a
browser Web Worker. The site lives in [`website/`](website/README.md), uses
TypeScript and pnpm, and is published to GitHub Pages by the Pages workflow.

## Building

```bash
moon build --target native --release
docker build -t bitsql .
docker run -p 1433:1433 bitsql --database app
```

Build, test and publish the native host architecture with
`scripts/docker-publish.sh --push`. The npm package (WebAssembly, any
platform) is built, run through the harness and published with
`scripts/npm-publish.sh --push` (after `npm login`).

- Design: [docs/design/](docs/design/README.md)
- Contributing and agent guide: [CLAUDE.md](CLAUDE.md)

## License

Public domain, [CC0 1.0](LICENSE.md); see [AUTHORS.md](AUTHORS.md).
Contributions are accepted only under the same dedication: add your name to
AUTHORS.md in your first contribution. Third-party parts (the MoonBit standard
library and `moonbitlang/async` compiled into the binary, the RE2 Unicode
tables, the vendored MoonBit docs) keep their own licenses; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Microsoft and SQL Server are trademarks of the Microsoft group of companies.
bitsql is an independent project. It is not affiliated with, endorsed by or
sponsored by Microsoft.

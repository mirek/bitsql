# bitsql

A memory-only SQL Server emulator written in [MoonBit](https://www.moonbitlang.com).
Real `tedious` / `mssql` clients connect to it over TDS, so test suites can drop
the ~1.6 GB `mssql/server` container in favor of a 40 MB image that starts in
about 0.22 s and idles at about 5 MB of RAM ([benchmarks](#benchmarks)).

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

```bash
docker run --rm -p 1433:1433 mirek/bitsql --auto-create-databases
```

Published image: `mirek/bitsql` (tags `X.Y.Z`, `X.Y`, `latest`). Release 0.1.27
publishes native-validated amd64; inspect the tag’s manifest for availability.
Other architectures require validation and publication on their native hosts. `SELECT @@VERSION` returns `Microsoft SQL Server 2025
(bitsql emulator X.Y.Z)`, so you can tell which release you're connected to,
and the image has `org.opencontainers.image.version` and `revision` labels.

## Drop-in replacement for `mcr.microsoft.com/mssql/server`

Change the image name. Connection settings stay the same:

- **Credentials:** any user name and password are accepted, so the existing
  `sa` / `MSSQL_SA_PASSWORD` values keep working. `ACCEPT_EULA`,
  `MSSQL_SA_PASSWORD`, `MSSQL_PID` and other `MSSQL_*` variables are ignored.
- **Port:** 1433 inside the container.
- **TLS:** works with tedious / mssql defaults (`encrypt: true` plus
  `trustServerCertificate: true`, as for SQL Server's self-signed
  certificate), and with `encrypt: false`. Prisma URLs work with
  `encrypt=true` or `encrypt=false`.
- **Databases:** `master`, `tempdb`, `model` and `msdb` exist at start.
  `CREATE DATABASE` works. If the tests connect straight to a database that
  nothing creates, start the server with `--database NAME` (repeatable) or
  `--auto-create-databases`. Otherwise the login fails with error 4060, as it
  does on SQL Server.
- **Memory only:** all data is lost when the container stops, so volumes
  under `/var/opt/mssql` have no effect and can be removed.
- **Health checks:** the image is distroless, so it has no shell and no
  `sqlcmd`. Replace `sqlcmd` health checks with a TCP or login probe. Since
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
Emulator error 50108), `--record FILE` (event log for `replay`).

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
with real counts, host-measured durations/CPU, linked runtime intervals and
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

The 0.1.27 native amd64 release image, `mirek/bitsql:0.1.27-amd64`, vs
`mcr.microsoft.com/mssql/server:2025-latest` (Developer edition, default settings),
linux/amd64, AMD Ryzen 9 7950X3D, Docker 29.1.3, 2026-10-09. Both containers ran
one after the other on this shared host; the client is tedious over loopback
with TLS. All metrics are lower-is-better. Cold start is one successful startup
per target, not a distribution. Query/DML shapes are medians of five checked
runs after one warm-up; the total sums those medians. Point SELECTs are the
median of five 1000-query batches after warm-up. Compressed download size comes
from the published amd64 registry manifest.

|  | bitsql | SQL Server | % of SQL Server | Factor |
| --- | ---: | ---: | ---: | ---: |
| Image download (compressed) | 13.8 MiB | 604.5 MiB | 2.3% | 44× better |
| Image size on disk | 40.1 MiB | 1.64 GiB | 2.4% | 42× better |
| Cold start: `docker run` → first query (one run) | 162 ms | 2.67 s | 6.1% | 16× better |
| CPU time until ready | 37.1 ms | 2.98 s | 1.2% | 80× better |
| Memory idle after start | 5.7 MiB | 1.17 GiB | 0.5% | 211× better |
| Memory after workload | 39.5 MiB | 1.21 GiB | 3.2% | 31× better |
| Memory peak (incl. page cache) | 49.0 MiB | 1.24 GiB | 3.9% | 26× better |
| Login (new connection, TLS, median) | 2.34 ms | 48.7 ms | 4.8% | 21× better |
| `SELECT 1` round trip (median) | 0.10 ms | 0.18 ms | 59% | 1.7× better |
| Drop + create 2-table schema (median) | 0.16 ms | 6.48 ms | 2.5% | 41× better |
| 1000 parameterized INSERTs | 174 ms | 894 ms | 19% | 5.1× better |
| 1000 parameterized point SELECTs (median of 5) | 155 ms | 124 ms | 125% | 1.3× worse |
| 200 transactions (INSERT + UPDATE) | 44.5 ms | 220 ms | 20% | 4.9× better |
| Join + GROUP BY report (median) | 0.77 ms | 0.82 ms | 94% | 1.1× better |
| Load 20000 + 20000 rows (GENERATE_SERIES) | 36.4 ms | 50.0 ms | 73% | 1.4× better |
| 24 query/DML shapes over 20000 rows (total) | 234 ms | 636 ms | 37% | 2.7× better |

| Shape (20000 rows) | bitsql | SQL Server | % of SQL Server | Factor |
| --- | ---: | ---: | ---: | ---: |
| GROUP BY p (997 groups) | 1.10 ms | 2.53 ms | 43% | 2.3× better |
| GROUP BY v (5003 groups) | 4.39 ms | 4.71 ms | 93% | 1.1× better |
| SELECT DISTINCT v | 3.32 ms | 4.28 ms | 77% | 1.3× better |
| COUNT(DISTINCT v) | 2.70 ms | 3.60 ms | 75% | 1.3× better |
| UNION | 5.39 ms | 7.58 ms | 71% | 1.4× better |
| EXCEPT | 6.12 ms | 6.40 ms | 96% | same |
| INTERSECT | 2.52 ms | 3.83 ms | 66% | 1.5× better |
| IN (uncorrelated subquery) | 3.11 ms | 4.58 ms | 68% | 1.5× better |
| NOT IN (uncorrelated subquery) | 2.14 ms | 2.92 ms | 73% | 1.4× better |
| EXISTS (correlated, unindexed) | 4.01 ms | 4.57 ms | 88% | 1.1× better |
| scalar subquery (correlated) | 2.88 ms | 4.50 ms | 64% | 1.6× better |
| scalar subquery (uncorrelated) | 4.02 ms | 4.22 ms | 95% | 1.1× better |
| equi-join | 1.38 ms | 4.63 ms | 30% | 3.4× better |
| ORDER BY v | 1.73 ms | 2.45 ms | 70% | 1.4× better |
| ORDER BY v after a shared non-ASCII prefix | 2.38 ms | 2.91 ms | 82% | 1.2× better |
| ORDER BY accented text | 2.80 ms | 3.20 ms | 88% | 1.1× better |
| ROW_NUMBER over v | 4.43 ms | 5.50 ms | 81% | 1.2× better |
| DELETE WHERE IN (subquery) | 11.3 ms | 96.7 ms | 12% | 8.5× better |
| UPDATE FROM join | 20.8 ms | 29.4 ms | 71% | 1.4× better |
| UPDATE all rows | 19.6 ms | 26.4 ms | 74% | 1.3× better |
| INSERT with FOREIGN KEY | 21.5 ms | 39.2 ms | 55% | 1.8× better |
| DELETE parent rows (FK checked) | 27.5 ms | 116 ms | 24% | 4.2× better |
| DELETE with ON DELETE CASCADE | 49.0 ms | 225 ms | 22% | 4.6× better |
| MERGE | 29.6 ms | 29.8 ms | 99% | same |

Query/DML shapes: median of 5 timed runs after one warm-up; total is the sum of those medians.

images: bitsql=mirek/bitsql:0.1.27-amd64, mssql=mcr.microsoft.com/mssql/server:2025-latest@sha256:2b5b581621126574f3d1f75e78d3eebe8d05aedb59ad0cfdf9aa42cb0634d726
Point SELECTs: median of five 1000-query batches after one full warm-up batch; all executions check SQL errors.

Startup, footprint and writes are the main gains in this run; point reads are
slower than SQL Server. Shared-host measurements vary between runs. These
measurements include native statement-history collection but do not isolate its
overhead or benchmark Query Store capture mode ALL. The earlier 0.1.26 opt-in
profiling experiment applies to that release only. See [the measurements and
methodology](docs/design/performance.md) and the [raw samples](website/public/benchmark-0.1.27.json).

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
`scripts/docker-publish.sh --push`.

- Design: [docs/design/](docs/design/README.md)
- Contributing and agent guide: [CLAUDE.md](CLAUDE.md)

## License

Public domain, [CC0 1.0](LICENSE.md); see [AUTHORS.md](AUTHORS.md).

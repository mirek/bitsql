# bitsql

A memory-only SQL Server emulator written in [MoonBit](https://www.moonbitlang.com).
Real `tedious` / `mssql` clients connect to it over TDS, so test suites can drop
the ~1.6 GB `mssql/server` container in favor of a 40 MB image that starts in
about 0.14 s and idles at about 5 MB of RAM ([benchmarks](#benchmarks)).

Ready to try in application CI as a lightweight replacement for the SQL Server
2025 container. [Try SQL in your browser](https://mirek.github.io/bitsql/) or
follow the container swap below. See [SQL Server 2025 coverage](#sql-server-2025-coverage)
for the release boundary and [the roadmap](docs/design/roadmap.md) for ongoing work.

Behavior is checked against captures from real SQL Server. A feature the
emulator doesn't support fails with an `Emulator: …` error (numbers
50100–50199) instead of returning a guess.

```bash
docker run --rm -p 1433:1433 mirek/bitsql --auto-create-databases
```

Published image: `mirek/bitsql` (tags `X.Y.Z`, `X.Y`, `latest`). Each
architecture is validated on its native host and added when ready; inspect the
tag’s manifest for availability. `SELECT @@VERSION` returns `Microsoft SQL Server 2025
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

## Benchmarks

`mirek/bitsql:0.1.24-amd64` vs `mcr.microsoft.com/mssql/server:2025-latest` (Developer
edition, default settings), linux/amd64, AMD Ryzen 9 7950X3D, Docker 29.1.3,
2026-10-07 (Europe/Zurich). Both containers ran one after the other on the same host, and the
client is tedious over loopback with TLS. Every metric is lower-is-better;
"% of SQL Server" is bitsql's value relative to SQL Server's, and "Factor" is
how many times better or worse bitsql is. Cold start is one successful startup per target in this run. Two attempts
at repeated SQL Server cold starts crashed with an internal assertion; those
incomplete runs are excluded and recorded in the performance notes.
Each query/DML shape is the median of 5 checked runs after one warm-up;
the total sums those medians. Earlier tables used one timed run per shape.
Point SELECTs are the median of five 1000-query batches after one full warm-up
batch; versions before 0.1.20 measured one batch.

|  | bitsql | SQL Server | % of SQL Server | Factor |
| --- | ---: | ---: | ---: | ---: |
| Image download (compressed) | 13.7 MiB | 604.5 MiB | 2.3% | 44× better |
| Image size on disk | 39.8 MiB | 1.64 GiB | 2.4% | 42× better |
| Cold start: `docker run` → first query (one run) | 144 ms | 2.69 s | 5.4% | 19× better |
| CPU time until ready | 36.0 ms | 3.01 s | 1.2% | 83× better |
| Memory idle after start | 5.1 MiB | 1.17 GiB | 0.4% | 234× better |
| Memory after workload | 48.1 MiB | 1.21 GiB | 3.9% | 26× better |
| Memory peak (incl. page cache) | 48.2 MiB | 1.24 GiB | 3.8% | 26× better |
| Login (new connection, TLS, median) | 2.29 ms | 48.5 ms | 4.7% | 21× better |
| `SELECT 1` round trip (median) | 0.10 ms | 0.13 ms | 73% | 1.4× better |
| Drop + create 2-table schema (median) | 0.13 ms | 6.57 ms | 2.0% | 49× better |
| 1000 parameterized INSERTs | 155 ms | 920 ms | 17% | 5.9× better |
| 1000 parameterized point SELECTs (median of 5) | 126 ms | 113 ms | 112% | 1.1× worse |
| 200 transactions (INSERT + UPDATE) | 33.8 ms | 214 ms | 16% | 6.3× better |
| Join + GROUP BY report (median) | 0.72 ms | 0.82 ms | 88% | 1.1× better |
| Load 20000 + 20000 rows (GENERATE_SERIES) | 36.8 ms | 49.5 ms | 74% | 1.3× better |
| 24 query/DML shapes over 20000 rows (total) | 235 ms | 636 ms | 37% | 2.7× better |

bitsql's advantage in this run is startup, footprint, logins, schema churn
and writes. The 24 query/DML shapes total 235 ms versus SQL Server’s 636 ms.
Point SELECTs take 126 ms versus 113 ms, so this release does not claim faster
point reads. The measurements and limitations are in
[docs/design/performance.md](docs/design/performance.md). Per-shape timings:

| Shape (20000 rows) | bitsql | SQL Server | % of SQL Server | Factor |
| --- | ---: | ---: | ---: | ---: |
| GROUP BY p (997 groups) | 1.27 ms | 2.61 ms | 49% | 2.1× better |
| GROUP BY v (5003 groups) | 3.95 ms | 4.67 ms | 85% | 1.2× better |
| SELECT DISTINCT v | 3.61 ms | 4.34 ms | 83% | 1.2× better |
| COUNT(DISTINCT v) | 2.84 ms | 3.63 ms | 78% | 1.3× better |
| UNION | 5.38 ms | 7.51 ms | 72% | 1.4× better |
| EXCEPT | 5.84 ms | 6.52 ms | 90% | 1.1× better |
| INTERSECT | 2.42 ms | 3.95 ms | 61% | 1.6× better |
| IN (uncorrelated subquery) | 2.98 ms | 4.59 ms | 65% | 1.5× better |
| NOT IN (uncorrelated subquery) | 2.07 ms | 2.96 ms | 70% | 1.4× better |
| EXISTS (correlated, unindexed) | 4.04 ms | 4.51 ms | 90% | 1.1× better |
| scalar subquery (correlated) | 2.98 ms | 4.43 ms | 67% | 1.5× better |
| scalar subquery (uncorrelated) | 4.28 ms | 4.44 ms | 97% | same |
| equi-join | 1.46 ms | 4.57 ms | 32% | 3.1× better |
| ORDER BY v | 1.80 ms | 2.40 ms | 75% | 1.3× better |
| ORDER BY v after a shared non-ASCII prefix | 2.35 ms | 2.90 ms | 81% | 1.2× better |
| ORDER BY accented text | 2.87 ms | 3.00 ms | 96% | same |
| ROW_NUMBER over v | 4.39 ms | 5.45 ms | 80% | 1.2× better |
| DELETE WHERE IN (subquery) | 11.9 ms | 96.1 ms | 12% | 8.1× better |
| UPDATE FROM join | 21.9 ms | 29.4 ms | 74% | 1.3× better |
| UPDATE all rows | 20.6 ms | 26.4 ms | 78% | 1.3× better |
| INSERT with FOREIGN KEY | 21.8 ms | 39.4 ms | 55% | 1.8× better |
| DELETE parent rows (FK checked) | 27.8 ms | 116 ms | 24% | 4.2× better |
| DELETE with ON DELETE CASCADE | 47.7 ms | 225 ms | 21% | 4.7× better |
| MERGE | 28.8 ms | 31.3 ms | 92% | 1.1× better |

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

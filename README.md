# bitsql

A memory-only SQL Server emulator written in [MoonBit](https://www.moonbitlang.com).
Real `tedious` / `mssql` clients connect to it over TDS, so test suites can drop
the ~1.6 GB `mssql/server` container in favor of a 34 MB image that starts in
about 0.1 s and idles at about 5 MB of RAM ([benchmarks](#benchmarks)).

Status: early development. See [docs/design/roadmap.md](docs/design/roadmap.md).
Behavior is checked against captures from real SQL Server. A feature the
emulator doesn't support fails with an `Emulator: …` error (numbers
50100–50199) instead of returning a guess.

```bash
docker run --rm -p 1433:1433 mirek/bitsql --auto-create-databases
```

Published image (linux/amd64 + linux/arm64): `mirek/bitsql` (tags `X.Y.Z`,
`X.Y`, `latest`). `SELECT @@VERSION` returns `Microsoft SQL Server 2025
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
    image: mirek/bitsql:0.1              # was mcr.microsoft.com/mssql/server:2022-latest
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

## Benchmarks

`mirek/bitsql:0.1.16-amd64` vs `mcr.microsoft.com/mssql/server:2025-latest` (Developer
edition, default settings), linux/amd64, AMD Ryzen 9 7950X3D, Docker 29.1.3,
2026-10-06 (Europe/Zurich). Both containers ran one after the other on the same host, and the
client is tedious over loopback with TLS. Every metric is lower-is-better;
"% of SQL Server" is bitsql's value relative to SQL Server's, and "Factor" is
how many times better or worse bitsql is. Cold start is the median of 5.
Each query/DML shape is the median of 5 checked runs after one warm-up;
the total sums those medians. Earlier tables used one timed run per shape.

|  | bitsql | SQL Server | % of SQL Server | Factor |
| --- | ---: | ---: | ---: | ---: |
| Image download (compressed) | n/a | 604.5 MiB | n/a | n/a |
| Image size on disk | 33.9 MiB | 1.64 GiB | 2.0% | 49× better |
| Cold start: `docker run` → first query (median) | 117 ms | 2.81 s | 4.2% | 24× better |
| CPU time until ready | 35.2 ms | 3.34 s | 1.1% | 95× better |
| Memory idle after start | 4.7 MiB | 1.17 GiB | 0.4% | 257× better |
| Memory after workload | 46.8 MiB | 1.22 GiB | 3.8% | 27× better |
| Memory peak (incl. page cache) | 47.0 MiB | 1.24 GiB | 3.7% | 27× better |
| Login (new connection, TLS, median) | 2.31 ms | 49.9 ms | 4.6% | 22× better |
| `SELECT 1` round trip (median) | 0.09 ms | 0.15 ms | 64% | 1.6× better |
| Drop + create 2-table schema (median) | 0.12 ms | 6.55 ms | 1.9% | 53× better |
| 1000 parameterized INSERTs | 151 ms | 907 ms | 17% | 6.0× better |
| 1000 parameterized point SELECTs | 139 ms | 150 ms | 92% | 1.1× better |
| 200 transactions (INSERT + UPDATE) | 33.1 ms | 220 ms | 15% | 6.6× better |
| Join + GROUP BY report (median) | 0.70 ms | 0.91 ms | 77% | 1.3× better |
| Load 20000 + 20000 rows (GENERATE_SERIES) | 34.7 ms | 50.6 ms | 69% | 1.5× better |
| 24 query/DML shapes over 20000 rows (total) | 234 ms | 672 ms | 35% | 2.9× better |

bitsql's advantage is startup, footprint, logins, schema churn and writes,
which is where integration test suites spend most of their time. The 24
set-heavy shapes take 35% of SQL Server's time in total. Version 0.1.16
removes unused COUNT argument intermediates and groups single-column keys
through a flat value array. COUNT DISTINCT measures 3.31 ms versus SQL
Server's 3.92 ms; UNION measures 5.93 versus 8.15 ms.
Controlled before/after measurements and the executor techniques are in
[docs/design/performance.md](docs/design/performance.md), which credits the
papers they draw from. Text GROUP BY, DISTINCT and ROW_NUMBER remain slower;
EXISTS is near parity. Per-shape timings:

| Shape (20000 rows) | bitsql | SQL Server | % of SQL Server | Factor |
| --- | ---: | ---: | ---: | ---: |
| GROUP BY p (997 groups) | 2.13 ms | 2.89 ms | 74% | 1.4× better |
| GROUP BY v (5003 groups) | 5.41 ms | 5.03 ms | 108% | 1.1× worse |
| SELECT DISTINCT v | 5.59 ms | 4.63 ms | 121% | 1.2× worse |
| COUNT(DISTINCT v) | 3.31 ms | 3.92 ms | 85% | 1.2× better |
| UNION | 5.93 ms | 8.15 ms | 73% | 1.4× better |
| EXCEPT | 5.69 ms | 6.89 ms | 83% | 1.2× better |
| INTERSECT | 2.32 ms | 4.20 ms | 55% | 1.8× better |
| IN (uncorrelated subquery) | 2.84 ms | 5.03 ms | 56% | 1.8× better |
| NOT IN (uncorrelated subquery) | 1.87 ms | 3.19 ms | 59% | 1.7× better |
| EXISTS (correlated, unindexed) | 4.94 ms | 4.91 ms | 101% | same |
| scalar subquery (correlated) | 3.39 ms | 4.86 ms | 70% | 1.4× better |
| scalar subquery (uncorrelated) | 4.26 ms | 4.66 ms | 91% | 1.1× better |
| equi-join | 1.29 ms | 5.04 ms | 26% | 3.9× better |
| ORDER BY v | 1.70 ms | 2.71 ms | 63% | 1.6× better |
| ORDER BY v after a shared non-ASCII prefix | 2.29 ms | 3.16 ms | 72% | 1.4× better |
| ORDER BY accented text | 3.10 ms | 3.27 ms | 95% | 1.1× better |
| ROW_NUMBER over v | 7.19 ms | 6.07 ms | 119% | 1.2× worse |
| DELETE WHERE IN (subquery) | 10.9 ms | 102 ms | 11% | 9.4× better |
| UPDATE FROM join | 20.0 ms | 31.1 ms | 64% | 1.6× better |
| UPDATE all rows | 18.9 ms | 27.9 ms | 68% | 1.5× better |
| INSERT with FOREIGN KEY | 21.1 ms | 41.8 ms | 50% | 2.0× better |
| DELETE parent rows (FK checked) | 27.5 ms | 124 ms | 22% | 4.5× better |
| DELETE with ON DELETE CASCADE | 45.4 ms | 235 ms | 19% | 5.2× better |
| MERGE | 26.7 ms | 31.4 ms | 85% | 1.2× better |

To reproduce (pulls both images; uses containers `bitsql-bench-*` on ports
47340/47341 and removes them afterwards):

```bash
cd harness && npm install
npm run bench:compare                            # prints these tables
npm run bench:compare -- --starts 5 --json out/bench-compare.json
npm run bench:compare -- --from out/bench-compare.json   # re-render tables only
BITSQL_IMAGE=bitsql:dev npm run bench:compare -- --only bitsql
```

## Building

```bash
moon build --target native --release
docker build -t bitsql .
docker run -p 1433:1433 bitsql --database app
```

The multi-arch release is built and pushed with
`scripts/docker-publish.sh --push`.

- Design: [docs/design/](docs/design/README.md)
- Contributing and agent guide: [CLAUDE.md](CLAUDE.md)

## License

Public domain, [CC0 1.0](LICENSE.md); see [AUTHORS.md](AUTHORS.md).

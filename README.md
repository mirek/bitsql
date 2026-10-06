# bitsql

A memory-only SQL Server emulator written in [MoonBit](https://www.moonbitlang.com).
Real `tedious` / `mssql` clients connect to it over TDS, so test suites can drop
the ~1.6 GB `mssql/server` container in favor of a 34 MB image that starts in
about 0.1 s and idles at about 4 MB of RAM ([benchmarks](#benchmarks)).

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

`mirek/bitsql:0.1.15-amd64` vs `mcr.microsoft.com/mssql/server:2025-latest` (Developer
edition, default settings), linux/amd64, AMD Ryzen 9 7950X3D, Docker 29.1.3,
2026-10-06 (Europe/Zurich). Both containers ran one after the other on the same host, and the
client is tedious over loopback with TLS. Every metric is lower-is-better;
"% of SQL Server" is bitsql's value relative to SQL Server's, and "Factor" is
how many times better or worse bitsql is. Cold start is the median of 5.
Each query/DML shape is the median of 5 checked runs after one warm-up;
the total sums those medians. Earlier tables used one timed run per shape.

|  | bitsql | SQL Server | % of SQL Server | Factor |
| --- | ---: | ---: | ---: | ---: |
| Image download (compressed) | 12.5 MiB | 604.5 MiB | 2.1% | 48.4× smaller |
| Image size on disk | 33.9 MiB | 1.64 GiB | 2.0% | 49× better |
| Cold start: `docker run` → first query (median) | 130 ms | 2.94 s | 4.4% | 23× better |
| CPU time until ready | 36.0 ms | 2.93 s | 1.2% | 81× better |
| Memory idle after start | 3.8 MiB | 1.17 GiB | 0.3% | 319× better |
| Memory after workload | 46.9 MiB | 1.22 GiB | 3.8% | 27× better |
| Memory peak (incl. page cache) | 46.9 MiB | 1.24 GiB | 3.7% | 27× better |
| Login (new connection, TLS, median) | 2.30 ms | 49.8 ms | 4.6% | 22× better |
| `SELECT 1` round trip (median) | 0.09 ms | 0.15 ms | 62% | 1.6× better |
| Drop + create 2-table schema (median) | 0.12 ms | 6.69 ms | 1.9% | 53× better |
| 1000 parameterized INSERTs | 154 ms | 907 ms | 17% | 5.9× better |
| 1000 parameterized point SELECTs | 138 ms | 146 ms | 95% | 1.1× better |
| 200 transactions (INSERT + UPDATE) | 32.7 ms | 216 ms | 15% | 6.6× better |
| Join + GROUP BY report (median) | 0.68 ms | 0.86 ms | 78% | 1.3× better |
| Load 20000 + 20000 rows (GENERATE_SERIES) | 35.0 ms | 50.4 ms | 69% | 1.4× better |
| 24 query/DML shapes over 20000 rows (total) | 243 ms | 669 ms | 36% | 2.7× better |

bitsql's advantage is startup, footprint, logins, schema churn and writes,
which is where integration test suites spend most of their time. The 24
set-heavy shapes take 36% of SQL Server's time in total. Version 0.1.15
reuses normalized ROW_NUMBER partition keys and adaptively caches repeated
text grouping keys. UNION measures 6.76 ms versus SQL Server's 7.96 ms;
ROW_NUMBER improves but remains slower at 7.03 versus 5.97 ms.
Controlled before/after measurements and the executor techniques are in
[docs/design/performance.md](docs/design/performance.md), which credits the
papers they draw from. Text grouping and ROW_NUMBER remain clearly slower;
EXISTS is slightly slower. Per-shape timings:

| Shape (20000 rows) | bitsql | SQL Server | % of SQL Server | Factor |
| --- | ---: | ---: | ---: | ---: |
| GROUP BY p (997 groups) | 2.20 ms | 2.83 ms | 78% | 1.3× better |
| GROUP BY v (5003 groups) | 5.56 ms | 5.05 ms | 110% | 1.1× worse |
| SELECT DISTINCT v | 5.71 ms | 4.54 ms | 126% | 1.3× worse |
| COUNT(DISTINCT v) | 4.30 ms | 3.89 ms | 110% | 1.1× worse |
| UNION | 6.76 ms | 7.96 ms | 85% | 1.2× better |
| EXCEPT | 6.01 ms | 6.82 ms | 88% | 1.1× better |
| INTERSECT | 2.39 ms | 4.17 ms | 57% | 1.7× better |
| IN (uncorrelated subquery) | 2.83 ms | 5.05 ms | 56% | 1.8× better |
| NOT IN (uncorrelated subquery) | 1.83 ms | 3.18 ms | 58% | 1.7× better |
| EXISTS (correlated, unindexed) | 5.12 ms | 4.93 ms | 104% | same |
| scalar subquery (correlated) | 3.18 ms | 4.83 ms | 66% | 1.5× better |
| scalar subquery (uncorrelated) | 4.19 ms | 4.62 ms | 91% | 1.1× better |
| equi-join | 1.28 ms | 5.00 ms | 26% | 3.9× better |
| ORDER BY v | 1.94 ms | 2.73 ms | 71% | 1.4× better |
| ORDER BY v after a shared non-ASCII prefix | 2.29 ms | 3.20 ms | 72% | 1.4× better |
| ORDER BY accented text | 3.27 ms | 3.30 ms | 99% | same |
| ROW_NUMBER over v | 7.03 ms | 5.97 ms | 118% | 1.2× worse |
| DELETE WHERE IN (subquery) | 11.1 ms | 102 ms | 11% | 9.2× better |
| UPDATE FROM join | 21.1 ms | 31.3 ms | 67% | 1.5× better |
| UPDATE all rows | 20.2 ms | 28.2 ms | 72% | 1.4× better |
| INSERT with FOREIGN KEY | 21.6 ms | 41.6 ms | 52% | 1.9× better |
| DELETE parent rows (FK checked) | 27.5 ms | 123 ms | 22% | 4.5× better |
| DELETE with ON DELETE CASCADE | 48.0 ms | 234 ms | 21% | 4.9× better |
| MERGE | 28.0 ms | 31.7 ms | 88% | 1.1× better |

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

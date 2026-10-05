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

## Benchmarks

`mirek/bitsql:0.1.6` vs `mcr.microsoft.com/mssql/server:2025-latest` (Developer
edition, default settings), linux/amd64, AMD Ryzen 9 7950X3D, Docker 29.1.3,
2026-10-05. Both containers ran one after the other on the same host, and the
client is tedious over loopback with TLS. Every metric is lower-is-better;
"% of SQL Server" is bitsql's value relative to SQL Server's, and "Factor" is
how many times better or worse bitsql is. Cold start is the median of 5.

|  | bitsql | SQL Server | % of SQL Server | Factor |
| --- | ---: | ---: | ---: | ---: |
| Image download (compressed) | 12.5 MiB | 604.5 MiB | 2.1% | 48× better |
| Image size on disk | 33.9 MiB | 1.64 GiB | 2.0% | 49× better |
| Cold start: `docker run` → first query (median) | 135 ms | 2.74 s | 4.9% | 20× better |
| CPU time until ready | 35.9 ms | 3.13 s | 1.1% | 87× better |
| Memory idle after start | 4.8 MiB | 1.17 GiB | 0.4% | 248× better |
| Memory after workload | 46.8 MiB | 1.22 GiB | 3.7% | 27× better |
| Memory peak (incl. page cache) | 46.8 MiB | 1.24 GiB | 3.7% | 27× better |
| Login (new connection, TLS, median) | 2.36 ms | 50.1 ms | 4.7% | 21× better |
| `SELECT 1` round trip (median) | 0.10 ms | 0.18 ms | 55% | 1.8× better |
| Drop + create 2-table schema (median) | 0.15 ms | 6.64 ms | 2.2% | 46× better |
| 1000 parameterized INSERTs | 160 ms | 920 ms | 17% | 5.8× better |
| 1000 parameterized point SELECTs | 149 ms | 142 ms | 105% | same |
| 200 transactions (INSERT + UPDATE) | 33.7 ms | 223 ms | 15% | 6.6× better |
| Join + GROUP BY report (median) | 0.86 ms | 0.88 ms | 97% | same |
| Load 20000 + 20000 rows (GENERATE_SERIES) | 38.7 ms | 49.9 ms | 77% | 1.3× better |
| 24 query/DML shapes over 20000 rows (total) | 272 ms | 696 ms | 39% | 2.6× better |

bitsql's advantage is startup, footprint, logins, schema churn and writes,
which is where integration test suites spend most of their time. Since 0.1.6
(executor work in [docs/design/performance.md](docs/design/performance.md),
which credits the papers it draws from) the 24 set-heavy shapes below take
39% of SQL Server's time in total (0.1.4: 73%, 0.1.3: 157%), joins, ORDER BY,
correlated subqueries, UPDATE/DELETE/MERGE and bulk loads included. SQL
Server is still faster where a query returns thousands of rows of
nvarchar data (GROUP BY/DISTINCT over 5003 distinct strings, 1.6–1.9×),
on accented-text sorting (2.3×) and on ROW_NUMBER partitioned by a string
(1.3×). Per-shape timings for the `npm run bench` shapes:

| Shape (20000 rows) | bitsql | SQL Server | % of SQL Server | Factor |
| --- | ---: | ---: | ---: | ---: |
| GROUP BY p (997 groups) | 2.06 ms | 2.81 ms | 73% | 1.4× better |
| GROUP BY v (5003 groups) | 8.19 ms | 5.20 ms | 157% | 1.6× worse |
| SELECT DISTINCT v | 7.98 ms | 4.81 ms | 166% | 1.7× worse |
| COUNT(DISTINCT v) | 7.40 ms | 3.88 ms | 191% | 1.9× worse |
| UNION | 10.0 ms | 8.15 ms | 123% | 1.2× worse |
| EXCEPT | 6.12 ms | 7.09 ms | 86% | 1.2× better |
| INTERSECT | 5.52 ms | 4.26 ms | 130% | 1.3× worse |
| IN (uncorrelated subquery) | 4.70 ms | 5.09 ms | 92% | 1.1× better |
| NOT IN (uncorrelated subquery) | 2.87 ms | 3.28 ms | 88% | 1.1× better |
| EXISTS (correlated, unindexed) | 5.56 ms | 5.03 ms | 111% | 1.1× worse |
| scalar subquery (correlated) | 3.70 ms | 4.96 ms | 75% | 1.3× better |
| scalar subquery (uncorrelated) | 5.07 ms | 4.59 ms | 111% | 1.1× worse |
| equi-join | 1.33 ms | 5.09 ms | 26% | 3.8× better |
| ORDER BY v | 1.85 ms | 2.89 ms | 64% | 1.6× better |
| ORDER BY v after a shared non-ASCII prefix | 2.35 ms | 3.17 ms | 74% | 1.3× better |
| ORDER BY accented text | 7.50 ms | 3.27 ms | 229% | 2.3× worse |
| ROW_NUMBER over v | 8.41 ms | 6.64 ms | 127% | 1.3× worse |
| DELETE WHERE IN (subquery) | 14.7 ms | 101 ms | 15% | 6.9× better |
| UPDATE FROM join | 20.4 ms | 31.6 ms | 65% | 1.5× better |
| UPDATE all rows | 20.1 ms | 27.8 ms | 72% | 1.4× better |
| INSERT with FOREIGN KEY | 22.0 ms | 48.1 ms | 46% | 2.2× better |
| DELETE parent rows (FK checked) | 29.7 ms | 122 ms | 24% | 4.1× better |
| DELETE with ON DELETE CASCADE | 47.3 ms | 235 ms | 20% | 5.0× better |
| MERGE | 27.1 ms | 50.1 ms | 54% | 1.9× better |

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

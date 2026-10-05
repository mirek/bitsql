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

Locally built `mirek/bitsql:0.1.10-amd64` (publication pending) vs `mcr.microsoft.com/mssql/server:2025-latest` (Developer
edition, default settings), linux/amd64, AMD Ryzen 9 7950X3D, Docker 29.1.3,
2026-10-06 (Europe/Zurich). Both containers ran one after the other on the same host, and the
client is tedious over loopback with TLS. Every metric is lower-is-better;
"% of SQL Server" is bitsql's value relative to SQL Server's, and "Factor" is
how many times better or worse bitsql is. Cold start is the median of 5.

|  | bitsql | SQL Server | % of SQL Server | Factor |
| --- | ---: | ---: | ---: | ---: |
| Image download (compressed) | n/a | 604.5 MiB | n/a | n/a |
| Image size on disk | 33.9 MiB | 1.64 GiB | 2.0% | 49× better |
| Cold start: `docker run` → first query (median) | 125 ms | 3.00 s | 4.2% | 24× better |
| CPU time until ready | 35.6 ms | 3.16 s | 1.1% | 89× better |
| Memory idle after start | 4.8 MiB | 1.17 GiB | 0.4% | 249× better |
| Memory after workload | 36.6 MiB | 1.22 GiB | 2.9% | 34× better |
| Memory peak (incl. page cache) | 46.5 MiB | 1.24 GiB | 3.7% | 27× better |
| Login (new connection, TLS, median) | 2.26 ms | 49.4 ms | 4.6% | 22× better |
| `SELECT 1` round trip (median) | 0.09 ms | 0.17 ms | 54% | 1.9× better |
| Drop + create 2-table schema (median) | 0.14 ms | 6.44 ms | 2.1% | 47× better |
| 1000 parameterized INSERTs | 144 ms | 902 ms | 16% | 6.3× better |
| 1000 parameterized point SELECTs | 131 ms | 145 ms | 90% | 1.1× better |
| 200 transactions (INSERT + UPDATE) | 32.8 ms | 217 ms | 15% | 6.6× better |
| Join + GROUP BY report (median) | 0.76 ms | 0.86 ms | 88% | 1.1× better |
| Load 20000 + 20000 rows (GENERATE_SERIES) | 35.1 ms | 50.9 ms | 69% | 1.4× better |
| 24 query/DML shapes over 20000 rows (total) | 257 ms | 696 ms | 37% | 2.7× better |

bitsql's advantage is startup, footprint, logins, schema churn and writes,
which is where integration test suites spend most of their time. The 24
set-heavy shapes take 37% of SQL Server's time in total. Version 0.1.10
specializes integer set membership; INTERSECT measures 2.55 ms versus SQL
Server's 4.16 ms. Controlled before/after measurements and the executor
techniques are documented in
[docs/design/performance.md](docs/design/performance.md), which credits the
papers they draw from. Remaining gaps include text grouping and UNION,
ROW_NUMBER, and some subqueries; accented-text sorting is near parity.
Per-shape timings for the `npm run bench` shapes:

| Shape (20000 rows) | bitsql | SQL Server | % of SQL Server | Factor |
| --- | ---: | ---: | ---: | ---: |
| GROUP BY p (997 groups) | 2.17 ms | 2.95 ms | 74% | 1.4× better |
| GROUP BY v (5003 groups) | 7.81 ms | 5.22 ms | 150% | 1.5× worse |
| SELECT DISTINCT v | 7.18 ms | 4.98 ms | 144% | 1.4× worse |
| COUNT(DISTINCT v) | 5.14 ms | 3.93 ms | 131% | 1.3× worse |
| UNION | 12.1 ms | 7.92 ms | 152% | 1.5× worse |
| EXCEPT | 6.43 ms | 7.01 ms | 92% | 1.1× better |
| INTERSECT | 2.55 ms | 4.16 ms | 61% | 1.6× better |
| IN (uncorrelated subquery) | 4.34 ms | 4.96 ms | 87% | 1.1× better |
| NOT IN (uncorrelated subquery) | 2.77 ms | 3.16 ms | 88% | 1.1× better |
| EXISTS (correlated, unindexed) | 5.39 ms | 4.90 ms | 110% | 1.1× worse |
| scalar subquery (correlated) | 3.59 ms | 4.79 ms | 75% | 1.3× better |
| scalar subquery (uncorrelated) | 4.95 ms | 4.68 ms | 106% | 1.1× worse |
| equi-join | 1.27 ms | 5.20 ms | 24% | 4.1× better |
| ORDER BY v | 1.64 ms | 2.74 ms | 60% | 1.7× better |
| ORDER BY v after a shared non-ASCII prefix | 2.39 ms | 3.19 ms | 75% | 1.3× better |
| ORDER BY accented text | 3.36 ms | 3.32 ms | 101% | same |
| ROW_NUMBER over v | 8.19 ms | 5.94 ms | 138% | 1.4× worse |
| DELETE WHERE IN (subquery) | 15.0 ms | 101 ms | 15% | 6.8× better |
| UPDATE FROM join | 19.8 ms | 31.2 ms | 63% | 1.6× better |
| UPDATE all rows | 18.5 ms | 28.0 ms | 66% | 1.5× better |
| INSERT with FOREIGN KEY | 21.4 ms | 47.9 ms | 45% | 2.2× better |
| DELETE parent rows (FK checked) | 28.3 ms | 122 ms | 23% | 4.3× better |
| DELETE with ON DELETE CASCADE | 45.8 ms | 236 ms | 19% | 5.1× better |
| MERGE | 26.9 ms | 50.5 ms | 53% | 1.9× better |

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

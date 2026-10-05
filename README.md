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

Locally built `mirek/bitsql:0.1.12-amd64` (publication pending) vs `mcr.microsoft.com/mssql/server:2025-latest` (Developer
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
| Cold start: `docker run` → first query (median) | 121 ms | 2.94 s | 4.1% | 24× better |
| CPU time until ready | 35.4 ms | 3.30 s | 1.1% | 93× better |
| Memory idle after start | 5.0 MiB | 1.17 GiB | 0.4% | 239× better |
| Memory after workload | 47.0 MiB | 1.22 GiB | 3.8% | 26× better |
| Memory peak (incl. page cache) | 47.2 MiB | 1.24 GiB | 3.7% | 27× better |
| Login (new connection, TLS, median) | 2.31 ms | 49.6 ms | 4.7% | 21× better |
| `SELECT 1` round trip (median) | 0.09 ms | 0.17 ms | 55% | 1.8× better |
| Drop + create 2-table schema (median) | 0.13 ms | 6.83 ms | 1.9% | 53× better |
| 1000 parameterized INSERTs | 171 ms | 948 ms | 18% | 5.5× better |
| 1000 parameterized point SELECTs | 187 ms | 159 ms | 118% | 1.2× worse |
| 200 transactions (INSERT + UPDATE) | 33.0 ms | 229 ms | 14% | 6.9× better |
| Join + GROUP BY report (median) | 0.70 ms | 0.89 ms | 78% | 1.3× better |
| Load 20000 + 20000 rows (GENERATE_SERIES) | 36.2 ms | 61.6 ms | 59% | 1.7× better |
| 24 query/DML shapes over 20000 rows (total) | 247 ms | 669 ms | 37% | 2.7× better |

bitsql's advantage is startup, footprint, logins, schema churn and writes,
which is where integration test suites spend most of their time. The 24
set-heavy shapes take 37% of SQL Server's time in total. Version 0.1.12
adds integer hashing for memoized IN/NOT IN membership, retaining the
conversion-aware comparison for other probes. IN measures 3.11 ms versus
SQL Server's 4.88 ms; NOT IN measures 2.39 versus 3.12 ms.
Controlled before/after measurements and the executor techniques are in
[docs/design/performance.md](docs/design/performance.md), which credits the
papers they draw from. Remaining gaps include text grouping, ROW_NUMBER,
and some subqueries. The point-select workload was slower in this container
run; repeated native baseline/candidate batches did not confirm a persistent
regression (details in the performance notes). Per-shape timings:

| Shape (20000 rows) | bitsql | SQL Server | % of SQL Server | Factor |
| --- | ---: | ---: | ---: | ---: |
| GROUP BY p (997 groups) | 1.90 ms | 3.02 ms | 63% | 1.6× better |
| GROUP BY v (5003 groups) | 6.18 ms | 5.69 ms | 109% | 1.1× worse |
| SELECT DISTINCT v | 5.97 ms | 4.86 ms | 123% | 1.2× worse |
| COUNT(DISTINCT v) | 4.32 ms | 3.86 ms | 112% | 1.1× worse |
| UNION | 7.28 ms | 8.36 ms | 87% | 1.1× better |
| EXCEPT | 5.67 ms | 6.72 ms | 84% | 1.2× better |
| INTERSECT | 2.37 ms | 4.11 ms | 58% | 1.7× better |
| IN (uncorrelated subquery) | 3.11 ms | 4.88 ms | 64% | 1.6× better |
| NOT IN (uncorrelated subquery) | 2.39 ms | 3.12 ms | 77% | 1.3× better |
| EXISTS (correlated, unindexed) | 5.39 ms | 4.85 ms | 111% | 1.1× worse |
| scalar subquery (correlated) | 3.57 ms | 4.75 ms | 75% | 1.3× better |
| scalar subquery (uncorrelated) | 4.99 ms | 4.64 ms | 108% | 1.1× worse |
| equi-join | 1.27 ms | 5.02 ms | 25% | 3.9× better |
| ORDER BY v | 1.67 ms | 2.69 ms | 62% | 1.6× better |
| ORDER BY v after a shared non-ASCII prefix | 2.26 ms | 3.50 ms | 65% | 1.5× better |
| ORDER BY accented text | 2.97 ms | 3.26 ms | 91% | 1.1× better |
| ROW_NUMBER over v | 7.65 ms | 5.89 ms | 130% | 1.3× worse |
| DELETE WHERE IN (subquery) | 13.4 ms | 101 ms | 13% | 7.6× better |
| UPDATE FROM join | 20.1 ms | 30.7 ms | 65% | 1.5× better |
| UPDATE all rows | 18.9 ms | 27.7 ms | 68% | 1.5× better |
| INSERT with FOREIGN KEY | 21.5 ms | 42.0 ms | 51% | 2.0× better |
| DELETE parent rows (FK checked) | 29.8 ms | 123 ms | 24% | 4.1× better |
| DELETE with ON DELETE CASCADE | 47.2 ms | 234 ms | 20% | 5.0× better |
| MERGE | 26.6 ms | 31.6 ms | 84% | 1.2× better |

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

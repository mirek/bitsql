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

`mirek/bitsql:0.1.8` vs `mcr.microsoft.com/mssql/server:2025-latest` (Developer
edition, default settings), linux/amd64, AMD Ryzen 9 7950X3D, Docker 29.1.3,
2026-10-05. Both containers ran one after the other on the same host, and the
client is tedious over loopback with TLS. Every metric is lower-is-better;
"% of SQL Server" is bitsql's value relative to SQL Server's, and "Factor" is
how many times better or worse bitsql is. Cold start is the median of 5.

|  | bitsql | SQL Server | % of SQL Server | Factor |
| --- | ---: | ---: | ---: | ---: |
| Image download (compressed) | 12.5 MiB | 604.5 MiB | 2.1% | 48× better |
| Image size on disk | 33.9 MiB | 1.64 GiB | 2.0% | 49× better |
| Cold start: `docker run` → first query (median) | 129 ms | 2.69 s | 4.8% | 21× better |
| CPU time until ready | 34.8 ms | 3.02 s | 1.2% | 87× better |
| Memory idle after start | 5.1 MiB | 1.17 GiB | 0.4% | 234× better |
| Memory after workload | 45.8 MiB | 1.21 GiB | 3.7% | 27× better |
| Memory peak (incl. page cache) | 45.9 MiB | 1.24 GiB | 3.6% | 28× better |
| Login (new connection, TLS, median) | 2.33 ms | 48.8 ms | 4.8% | 21× better |
| `SELECT 1` round trip (median) | 0.09 ms | 0.16 ms | 58% | 1.7× better |
| Drop + create 2-table schema (median) | 0.13 ms | 6.75 ms | 1.9% | 53× better |
| 1000 parameterized INSERTs | 152 ms | 952 ms | 16% | 6.3× better |
| 1000 parameterized point SELECTs | 132 ms | 149 ms | 88% | 1.1× better |
| 200 transactions (INSERT + UPDATE) | 33.9 ms | 230 ms | 15% | 6.8× better |
| Join + GROUP BY report (median) | 0.69 ms | 0.90 ms | 77% | 1.3× better |
| Load 20000 + 20000 rows (GENERATE_SERIES) | 35.3 ms | 51.0 ms | 69% | 1.4× better |
| 24 query/DML shapes over 20000 rows (total) | 268 ms | 705 ms | 38% | 2.6× better |

bitsql's advantage is startup, footprint, logins, schema churn and writes,
which is where integration test suites spend most of their time. The 24
set-heavy shapes take 38% of SQL Server's time in total. Version 0.1.8 adds
compact hash slots for single-column grouping; interleaved before/after
measurements and the executor techniques are documented in
[docs/design/performance.md](docs/design/performance.md), which credits the
papers they draw from. SQL Server remains faster on nine individual shapes,
with the largest gap in accented-text sorting (2.3×). Per-shape timings for
the `npm run bench` shapes:

| Shape (20000 rows) | bitsql | SQL Server | % of SQL Server | Factor |
| --- | ---: | ---: | ---: | ---: |
| GROUP BY p (997 groups) | 2.59 ms | 3.01 ms | 86% | 1.2× better |
| GROUP BY v (5003 groups) | 7.80 ms | 5.56 ms | 140% | 1.4× worse |
| SELECT DISTINCT v | 7.36 ms | 4.96 ms | 149% | 1.5× worse |
| COUNT(DISTINCT v) | 5.17 ms | 3.95 ms | 131% | 1.3× worse |
| UNION | 10.5 ms | 8.09 ms | 130% | 1.3× worse |
| EXCEPT | 6.21 ms | 7.14 ms | 87% | 1.2× better |
| INTERSECT | 5.04 ms | 4.13 ms | 122% | 1.2× worse |
| IN (uncorrelated subquery) | 4.25 ms | 5.02 ms | 85% | 1.2× better |
| NOT IN (uncorrelated subquery) | 2.76 ms | 3.16 ms | 87% | 1.1× better |
| EXISTS (correlated, unindexed) | 5.35 ms | 4.89 ms | 109% | 1.1× worse |
| scalar subquery (correlated) | 3.55 ms | 5.17 ms | 69% | 1.5× better |
| scalar subquery (uncorrelated) | 4.95 ms | 4.68 ms | 106% | 1.1× worse |
| equi-join | 1.30 ms | 5.05 ms | 26% | 3.9× better |
| ORDER BY v | 1.77 ms | 2.71 ms | 65% | 1.5× better |
| ORDER BY v after a shared non-ASCII prefix | 2.30 ms | 3.16 ms | 73% | 1.4× better |
| ORDER BY accented text | 7.75 ms | 3.31 ms | 234% | 2.3× worse |
| ROW_NUMBER over v | 9.14 ms | 5.94 ms | 154% | 1.5× worse |
| DELETE WHERE IN (subquery) | 15.0 ms | 103 ms | 15% | 6.9× better |
| UPDATE FROM join | 20.4 ms | 31.4 ms | 65% | 1.5× better |
| UPDATE all rows | 19.4 ms | 28.3 ms | 68% | 1.5× better |
| INSERT with FOREIGN KEY | 21.9 ms | 48.0 ms | 46% | 2.2× better |
| DELETE parent rows (FK checked) | 29.3 ms | 123 ms | 24% | 4.2× better |
| DELETE with ON DELETE CASCADE | 48.0 ms | 239 ms | 20% | 5.0× better |
| MERGE | 26.4 ms | 51.7 ms | 51% | 2.0× better |

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

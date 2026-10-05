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
`X.Y`, `latest`).

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

Server options (append them after the image name): `--listen HOST:PORT`, `--database NAME`
(repeatable), `--auto-create-databases`, `--tls-cert FILE --tls-key FILE`
(PEM; default a built-in self-signed localhost certificate), `--no-tls`,
`--max-request-work N` (runaway-request budget; a request past it fails with
Emulator error 50108), `--record FILE` (event log for `replay`).

## Benchmarks

`mirek/bitsql:0.1.2` vs `mcr.microsoft.com/mssql/server:2025-latest` (Developer
edition, default settings), linux/amd64, AMD Ryzen 9 7950X3D, Docker 29.1.3,
2026-10-05. Both containers ran one after the other on the same host, and the
client is tedious over loopback with TLS. Every metric is lower-is-better;
"% of SQL Server" is bitsql's value relative to SQL Server's, and "Factor" is
how many times better or worse bitsql is.

|  | bitsql | SQL Server | % of SQL Server | Factor |
| --- | ---: | ---: | ---: | ---: |
| Image download (compressed) | 12.4 MiB | 604.5 MiB | 2.0% | 49× better |
| Image size on disk | 33.7 MiB | 1.64 GiB | 2.0% | 50× better |
| Cold start: `docker run` → first query (median of 5) | 116 ms | 2.66 s | 4.4% | 23× better |
| CPU time until ready | 35.0 ms | 3.04 s | 1.2% | 87× better |
| Memory idle after start | 4.5 MiB | 1.17 GiB | 0.4% | 267× better |
| Memory after workload | 41.8 MiB | 1.21 GiB | 3.4% | 30× better |
| Memory peak (incl. page cache) | 49.4 MiB | 1.24 GiB | 3.9% | 26× better |
| Login (new connection, TLS, median) | 2.34 ms | 49.1 ms | 4.8% | 21× better |
| `SELECT 1` round trip (median) | 0.10 ms | 0.15 ms | 67% | 1.5× better |
| Drop + create 2-table schema (median) | 0.14 ms | 6.91 ms | 2.1% | 48× better |
| 1000 parameterized INSERTs | 168 ms | 917 ms | 18% | 5.4× better |
| 1000 parameterized point SELECTs | 161 ms | 147 ms | 109% | 1.1× worse |
| 200 transactions (INSERT + UPDATE) | 79.1 ms | 224 ms | 35% | 2.8× better |
| Join + GROUP BY report (median) | 1.19 ms | 0.86 ms | 139% | 1.4× worse |
| Load 20000 + 20000 rows (GENERATE_SERIES) | 76.0 ms | 51.2 ms | 148% | 1.5× worse |
| 24 query/DML shapes over 20000 rows (total) | 1.10 s | 700 ms | 157% | 1.6× worse |

bitsql's advantage is startup, footprint, logins, schema churn and small
writes, which is where integration test suites spend most of their time.
SQL Server's optimizer is still faster on set-heavy queries over tens of
thousands of rows, typically 2–10× (accented-text sorting is 35×). Per-shape
timings for the `npm run bench` shapes:

| Shape (20000 rows) | bitsql | SQL Server | % of SQL Server | Factor |
| --- | ---: | ---: | ---: | ---: |
| GROUP BY p (997 groups) | 8.86 ms | 2.87 ms | 309% | 3.1× worse |
| GROUP BY v (5003 groups) | 27.6 ms | 5.25 ms | 525% | 5.3× worse |
| SELECT DISTINCT v | 28.5 ms | 4.66 ms | 612% | 6.1× worse |
| COUNT(DISTINCT v) | 23.6 ms | 3.92 ms | 600% | 6.0× worse |
| UNION | 54.1 ms | 8.12 ms | 666% | 6.7× worse |
| EXCEPT | 20.8 ms | 7.08 ms | 294% | 2.9× worse |
| INTERSECT | 9.05 ms | 4.22 ms | 215% | 2.1× worse |
| IN (uncorrelated subquery) | 7.50 ms | 4.99 ms | 150% | 1.5× worse |
| NOT IN (uncorrelated subquery) | 6.82 ms | 3.21 ms | 212% | 2.1× worse |
| EXISTS (correlated, unindexed) | 17.3 ms | 4.92 ms | 352% | 3.5× worse |
| scalar subquery (correlated) | 24.5 ms | 5.01 ms | 489% | 4.9× worse |
| scalar subquery (uncorrelated) | 12.7 ms | 4.64 ms | 275% | 2.7× worse |
| equi-join | 5.60 ms | 5.37 ms | 104% | same |
| ORDER BY v | 24.6 ms | 2.74 ms | 898% | 9.0× worse |
| ORDER BY v after a shared non-ASCII prefix | 23.8 ms | 3.21 ms | 739% | 7.4× worse |
| ORDER BY accented text | 116 ms | 3.32 ms | 3488% | 35× worse |
| ROW_NUMBER over v | 52.5 ms | 6.22 ms | 843% | 8.4× worse |
| DELETE WHERE IN (subquery) | 32.4 ms | 103 ms | 32% | 3.2× better |
| UPDATE FROM join | 137 ms | 31.4 ms | 436% | 4.4× worse |
| UPDATE all rows | 133 ms | 28.3 ms | 469% | 4.7× worse |
| INSERT with FOREIGN KEY | 39.8 ms | 48.3 ms | 82% | 1.2× better |
| DELETE parent rows (FK checked) | 68.5 ms | 123 ms | 56% | 1.8× better |
| DELETE with ON DELETE CASCADE | 147 ms | 237 ms | 62% | 1.6× better |
| MERGE | 78.0 ms | 50.3 ms | 155% | 1.6× worse |

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

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

`mirek/bitsql:0.1.4` vs `mcr.microsoft.com/mssql/server:2025-latest` (Developer
edition, default settings), linux/amd64, AMD Ryzen 9 7950X3D, Docker 29.1.3,
2026-10-05. Both containers ran one after the other on the same host, and the
client is tedious over loopback with TLS. Every metric is lower-is-better;
"% of SQL Server" is bitsql's value relative to SQL Server's, and "Factor" is
how many times better or worse bitsql is. Cold start is the median of 5.

|  | bitsql | SQL Server | % of SQL Server | Factor |
| --- | ---: | ---: | ---: | ---: |
| Image download (compressed) | 12.4 MiB | 604.5 MiB | 2.1% | 49× better |
| Image size on disk | 33.7 MiB | 1.64 GiB | 2.0% | 50× better |
| Cold start: `docker run` → first query (median) | 125 ms | 2.84 s | 4.4% | 23× better |
| CPU time until ready | 35.0 ms | 3.38 s | 1.0% | 96× better |
| Memory idle after start | 4.7 MiB | 1.17 GiB | 0.4% | 253× better |
| Memory after workload | 50.8 MiB | 1.22 GiB | 4.1% | 25× better |
| Memory peak (incl. page cache) | 50.9 MiB | 1.24 GiB | 4.0% | 25× better |
| Login (new connection, TLS, median) | 2.53 ms | 49.4 ms | 5.1% | 20× better |
| `SELECT 1` round trip (median) | 0.10 ms | 0.15 ms | 64% | 1.6× better |
| Drop + create 2-table schema (median) | 0.15 ms | 6.64 ms | 2.3% | 44× better |
| 1000 parameterized INSERTs | 159 ms | 930 ms | 17% | 5.8× better |
| 1000 parameterized point SELECTs | 158 ms | 144 ms | 109% | 1.1× worse |
| 200 transactions (INSERT + UPDATE) | 76.7 ms | 222 ms | 35% | 2.9× better |
| Join + GROUP BY report (median) | 1.14 ms | 0.89 ms | 128% | 1.3× worse |
| Load 20000 + 20000 rows (GENERATE_SERIES) | 49.8 ms | 50.1 ms | 99% | same |
| 24 query/DML shapes over 20000 rows (total) | 511 ms | 695 ms | 73% | 1.4× better |

bitsql's advantage is startup, footprint, logins, schema churn and writes,
which is where integration test suites spend most of their time. Since 0.1.4
the 24 set-heavy shapes below run faster than SQL Server in total (0.1.3 took
1.09 s, 1.6× slower), and bulk loads are on par. SQL Server's optimizer is
still faster on individual queries over tens of thousands of rows: sorting,
grouping and correlated subqueries are typically 2–5× faster there
(accented-text sorting 8×). Per-shape timings for the `npm run bench`
shapes:

| Shape (20000 rows) | bitsql | SQL Server | % of SQL Server | Factor |
| --- | ---: | ---: | ---: | ---: |
| GROUP BY p (997 groups) | 5.73 ms | 2.95 ms | 194% | 1.9× worse |
| GROUP BY v (5003 groups) | 13.6 ms | 5.66 ms | 241% | 2.4× worse |
| SELECT DISTINCT v | 10.5 ms | 4.84 ms | 216% | 2.2× worse |
| COUNT(DISTINCT v) | 7.28 ms | 3.86 ms | 189% | 1.9× worse |
| UNION | 21.8 ms | 7.96 ms | 274% | 2.7× worse |
| EXCEPT | 19.7 ms | 6.95 ms | 283% | 2.8× worse |
| INTERSECT | 8.62 ms | 4.10 ms | 210% | 2.1× worse |
| IN (uncorrelated subquery) | 7.29 ms | 4.93 ms | 148% | 1.5× worse |
| NOT IN (uncorrelated subquery) | 6.73 ms | 3.15 ms | 214% | 2.1× worse |
| EXISTS (correlated, unindexed) | 17.8 ms | 4.85 ms | 368% | 3.7× worse |
| scalar subquery (correlated) | 25.0 ms | 4.81 ms | 519% | 5.2× worse |
| scalar subquery (uncorrelated) | 13.7 ms | 4.63 ms | 295% | 3.0× worse |
| equi-join | 5.39 ms | 5.03 ms | 107% | 1.1× worse |
| ORDER BY v | 6.47 ms | 2.70 ms | 240% | 2.4× worse |
| ORDER BY v after a shared non-ASCII prefix | 13.0 ms | 3.16 ms | 413% | 4.1× worse |
| ORDER BY accented text | 26.9 ms | 3.31 ms | 814% | 8.1× worse |
| ROW_NUMBER over v | 20.5 ms | 5.97 ms | 344% | 3.4× worse |
| DELETE WHERE IN (subquery) | 18.9 ms | 102 ms | 19% | 5.4× better |
| UPDATE FROM join | 42.8 ms | 31.6 ms | 135% | 1.4× worse |
| UPDATE all rows | 39.1 ms | 27.8 ms | 141% | 1.4× worse |
| INSERT with FOREIGN KEY | 27.3 ms | 48.0 ms | 57% | 1.8× better |
| DELETE parent rows (FK checked) | 44.8 ms | 122 ms | 37% | 2.7× better |
| DELETE with ON DELETE CASCADE | 64.6 ms | 234 ms | 28% | 3.6× better |
| MERGE | 43.6 ms | 51.1 ms | 85% | 1.2× better |

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

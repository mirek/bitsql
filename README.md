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

`mirek/bitsql:0.1.3` vs `mcr.microsoft.com/mssql/server:2025-latest` (Developer
edition, default settings), linux/amd64, AMD Ryzen 9 7950X3D, Docker 29.1.3,
2026-10-05. Both containers ran one after the other on the same host, and the
client is tedious over loopback with TLS. Every metric is lower-is-better;
"% of SQL Server" is bitsql's value relative to SQL Server's, and "Factor" is
how many times better or worse bitsql is.

|  | bitsql | SQL Server | % of SQL Server | Factor |
| --- | ---: | ---: | ---: | ---: |
| Image download (compressed) | 12.4 MiB | 604.5 MiB | 2.0% | 49× better |
| Image size on disk | 33.7 MiB | 1.64 GiB | 2.0% | 50× better |
| Cold start: `docker run` → first query (median of 5) | 121 ms | 2.73 s | 4.4% | 22× better |
| CPU time until ready | 34.7 ms | 2.95 s | 1.2% | 85× better |
| Memory idle after start | 4.3 MiB | 1.17 GiB | 0.4% | 282× better |
| Memory after workload | 46.1 MiB | 1.21 GiB | 3.7% | 27× better |
| Memory peak (incl. page cache) | 48.3 MiB | 1.24 GiB | 3.8% | 26× better |
| Login (new connection, TLS, median) | 2.30 ms | 49.1 ms | 4.7% | 21× better |
| `SELECT 1` round trip (median) | 0.10 ms | 0.14 ms | 70% | 1.4× better |
| Drop + create 2-table schema (median) | 0.16 ms | 7.03 ms | 2.3% | 43× better |
| 1000 parameterized INSERTs | 161 ms | 923 ms | 17% | 5.7× better |
| 1000 parameterized point SELECTs | 154 ms | 139 ms | 111% | 1.1× worse |
| 200 transactions (INSERT + UPDATE) | 76.3 ms | 230 ms | 33% | 3.0× better |
| Join + GROUP BY report (median) | 1.17 ms | 0.85 ms | 137% | 1.4× worse |
| Load 20000 + 20000 rows (GENERATE_SERIES) | 73.8 ms | 49.3 ms | 150% | 1.5× worse |
| 24 query/DML shapes over 20000 rows (total) | 1.09 s | 674 ms | 161% | 1.6× worse |

bitsql's advantage is startup, footprint, logins, schema churn and small
writes, which is where integration test suites spend most of their time.
SQL Server's optimizer is still faster on set-heavy queries over tens of
thousands of rows, typically 2–10× (accented-text sorting is 36×). Per-shape
timings for the `npm run bench` shapes:

| Shape (20000 rows) | bitsql | SQL Server | % of SQL Server | Factor |
| --- | ---: | ---: | ---: | ---: |
| GROUP BY p (997 groups) | 8.86 ms | 2.98 ms | 298% | 3.0× worse |
| GROUP BY v (5003 groups) | 28.4 ms | 5.07 ms | 560% | 5.6× worse |
| SELECT DISTINCT v | 28.5 ms | 4.63 ms | 615% | 6.2× worse |
| COUNT(DISTINCT v) | 23.4 ms | 3.67 ms | 637% | 6.4× worse |
| UNION | 53.7 ms | 8.63 ms | 622% | 6.2× worse |
| EXCEPT | 22.6 ms | 6.75 ms | 334% | 3.3× worse |
| INTERSECT | 8.02 ms | 3.89 ms | 206% | 2.1× worse |
| IN (uncorrelated subquery) | 7.97 ms | 4.63 ms | 172% | 1.7× worse |
| NOT IN (uncorrelated subquery) | 6.61 ms | 2.94 ms | 225% | 2.2× worse |
| EXISTS (correlated, unindexed) | 18.9 ms | 4.57 ms | 414% | 4.1× worse |
| scalar subquery (correlated) | 24.5 ms | 4.51 ms | 543% | 5.4× worse |
| scalar subquery (uncorrelated) | 12.8 ms | 4.28 ms | 300% | 3.0× worse |
| equi-join | 5.42 ms | 4.85 ms | 112% | 1.1× worse |
| ORDER BY v | 24.2 ms | 2.49 ms | 971% | 9.7× worse |
| ORDER BY v after a shared non-ASCII prefix | 23.6 ms | 2.89 ms | 816% | 8.2× worse |
| ORDER BY accented text | 109 ms | 3.02 ms | 3618% | 36× worse |
| ROW_NUMBER over v | 50.7 ms | 5.56 ms | 912% | 9.1× worse |
| DELETE WHERE IN (subquery) | 34.5 ms | 97.5 ms | 35% | 2.8× better |
| UPDATE FROM join | 132 ms | 30.8 ms | 428% | 4.3× worse |
| UPDATE all rows | 132 ms | 27.1 ms | 488% | 4.9× worse |
| INSERT with FOREIGN KEY | 38.4 ms | 48.0 ms | 80% | 1.2× better |
| DELETE parent rows (FK checked) | 69.6 ms | 119 ms | 59% | 1.7× better |
| DELETE with ON DELETE CASCADE | 146 ms | 228 ms | 64% | 1.6× better |
| MERGE | 79.0 ms | 48.8 ms | 162% | 1.6× worse |

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

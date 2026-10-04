# bitsql

A memory-only SQL Server emulator written in [MoonBit](https://www.moonbitlang.com).
Real `tedious` / `mssql` clients connect to it over TDS, so test suites can drop
the ~1.5 GB `mssql/server` container in favor of a tiny native binary.

Status: early development. See [docs/design/roadmap.md](docs/design/roadmap.md).

```bash
moon build --target native --release
docker build -t bitsql .          # ~35 MB image, ~5 MB RAM idle
docker run -p 1433:1433 bitsql --database app
```

Published image (linux/amd64 + linux/arm64): `mirek/bitsql`, built and pushed
with `scripts/docker-publish.sh --push`.

Connect with tedious / mssql defaults (`encrypt: true` plus
`trustServerCertificate: true`, as for SQL Server's self-signed certificate) or
with `encrypt: false`; Prisma URLs work with `encrypt=true` or `encrypt=false`.
For fast
test isolation, seed once, run `EXEC emulator.snapshot 'seed'`, then run
`EXEC emulator.restore 'seed'` before each test.

Host options: `--listen HOST:PORT`, `--database NAME` (repeatable),
`--auto-create-databases`, `--tls-cert FILE --tls-key FILE` (PEM; default a
built-in self-signed localhost certificate), `--no-tls`, `--max-request-work N` (runaway-request budget;
a request past it fails with Emulator error 50108), `--record FILE` (event log
for `replay`).

- Design: [docs/design/](docs/design/README.md)
- Contributing and agent guide: [CLAUDE.md](CLAUDE.md)

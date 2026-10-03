# bitsql

A memory-only SQL Server emulator written in [MoonBit](https://www.moonbitlang.com).
Real `tedious` / `mssql` clients connect to it over TDS, so test suites can drop
the ~1.5 GB `mssql/server` container in favor of a tiny native binary.

Status: early development. See [docs/design/roadmap.md](docs/design/roadmap.md).

```bash
moon build --target native --release
docker build -t bitsql .          # ~26 MB image, < 1 MB RAM idle
docker run -p 1433:1433 bitsql --database app
```

Connect with tedious / mssql using `encrypt: false` (no TLS in v1). For fast
test isolation, seed once, run `EXEC emulator.snapshot 'seed'`, then run
`EXEC emulator.restore 'seed'` before each test.

- Design: [docs/design/](docs/design/README.md)
- Contributing and agent guide: [CLAUDE.md](CLAUDE.md)

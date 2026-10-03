# bitsql

A memory-only SQL Server emulator written in [MoonBit](https://www.moonbitlang.com).
Real `tedious` / `mssql` clients connect to it over TDS, so test suites can drop
the ~1.5 GB `mssql/server` container in favor of a tiny native binary.

Status: early development. See [docs/design/roadmap.md](docs/design/roadmap.md).

- Design: [docs/design/](docs/design/README.md)
- Contributing and agent guide: [CLAUDE.md](CLAUDE.md)

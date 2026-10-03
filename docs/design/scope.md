# Scope

## Context and goals

The pain is image size and RAM. Startup time and cost are secondary. The project
is also a learning vehicle (DB internals, MoonBit) and a potential open-source
product, so the design favors clean, reusable abstractions over a throwaway
fake.

Success criteria:

- **Drop-in:** the existing test suite runs unchanged except for the connection
  string (`encrypt: false`).
- **Faithful:** every test that passes on the emulator passes on real SQL
  Server. A false green is worse than slow CI.
- **Small:** container image in the tens of MB and idle RAM well under 100 MB.
- **Extensible:** adding a second dialect (MySQL) costs a parser plus a
  semantics provider plus a wire adapter, not an engine rewrite.

## v1 scope

v1 targets exactly the surface the current suite uses: Node `tedious`/`mssql`,
custom SQL migration scripts, procs, RCSI with locking hints.

| Area | In v1 | Out of v1 |
| --- | --- | --- |
| Protocol | PRELOGIN, LOGIN7, SQLBatch, RPC (`sp_executesql`, proc calls), ATTENTION | TLS, bulk load, TVPs, MARS |
| DDL | Tables, PKs, indexes, FKs, CHECK, defaults, computed columns, views, triggers | Sequences, user-defined types, partitioning |
| DML | CRUD, joins, subqueries, CTEs, `OUTPUT`, `MERGE` | Updatable views beyond simple cases |
| Procedural | Procs, dynamic SQL, cursors (`STATIC`, `FAST_FORWARD`, `LOCAL`), `TRY/CATCH`, `THROW`, `RAISERROR` | `DYNAMIC`/`KEYSET` cursors, CLR, `WAITFOR` |
| Isolation | RCSI; `UPDLOCK`, `HOLDLOCK`, explicit `SERIALIZABLE` via key-range locks | Locking read committed, `REPEATABLE READ`, page locks, escalation |
| Types | `int` family, `decimal`, `bit`, `(n)varchar`, `datetime2`, `datetimeoffset`, `uniqueidentifier`, `rowversion` | Spatial, `hierarchyid`, `xml`, `sql_variant` |
| Functions | Common scalar and aggregate functions, `OPENJSON`, `JSON_VALUE`, `JSON_QUERY`, `ISJSON`, `FOR JSON` | Full-text search |
| Catalog | Exactly the `sys.*`, `INFORMATION_SCHEMA` and metadata functions the migration scripts touch | Everything else |
| Storage | Memory only, snapshot/restore for test isolation | Persistence, backup/restore |

## Unsupported-feature policy

Every out-of-scope feature raises a distinct error naming itself (e.g.
`Emulator: DYNAMIC cursors are not supported`). Silent approximation is never
allowed, because it produces false greens. Concretely:

- Use the dedicated emulator error number range (see `fidelity-traps.md`,
  "Emulator errors") with severity 16, so clients see a normal SQL error.
- The message always starts with `Emulator:` and names the feature.
- An unknown *syntax* in the parser is a parse error (102-style). A known but
  unimplemented feature is an emulator error, never a parse error.

## Parser ahead of execution

The parser must accept the entire target codebase early, including proc and
trigger bodies created by migrations. SQL Server parses bodies at `CREATE` but
resolves names at run time, so execution coverage can lag.

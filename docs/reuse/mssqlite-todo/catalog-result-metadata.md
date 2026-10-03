# Catalog result metadata

## Evidence

The `select into type preservation` differential case queries `sys.columns`
and `TYPE_NAME()` after creating a table. Values agree, but SQL Server returns:

- `sys.columns.name` and `TYPE_NAME(...)` as sysname / `nvarchar(128)`, exposed
  by tedious with `dataLength = 256`
- `sys.columns.max_length` as non-null fixed `smallint`

mssqlite currently returns both names as `nvarchar(max)` (`dataLength =
65535`) and `max_length` as nullable `IntN(4)`. This contradicts the catalog
contracts recorded in `.agents/skills/sys/SKILL.md`.

## Work

Attach declared SQL Server types to catalog backing tables/views and catalog
function projections rather than inferring from SQLite TEXT/INTEGER storage.
Start with the reproduced fields, then audit the other implemented `sys.*` and
INFORMATION_SCHEMA columns so a narrow repair does not leave adjacent fields
with the same defect.

Likely boundaries are `packages/catalog` schema descriptors,
`packages/engine/src/metadata.ts`, and catalog-function projection hints.

## Acceptance

- All five declared differences in the live case become stale and are removed.
- Empty and populated catalog queries expose identical metadata.
- Focused tests cover sysname, smallint, tinyint, bit, nullable catalog fields,
  and `TYPE_NAME()`.
- `pnpm test` and `pnpm test:differential` pass.

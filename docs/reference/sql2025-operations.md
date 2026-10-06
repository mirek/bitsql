# SQL Server 2025 operational audit

## Tempdb space governance (2026-10-06)

Microsoft documents workload-group limits via GROUP_MAX_TEMPDB_DATA_MB or
GROUP_MAX_TEMPDB_DATA_PERCENT; a fixed limit wins if both are set. Enforcement
uses allocated 8-KB data pages and aborts requests with 1138, severity 17.
Percentage limits can be stored but inactive when file configuration does not
qualify, with warning 10989. Current/peak consumption and violation counters
are separate from configured limits. See [Microsoft's specification](https://learn.microsoft.com/en-us/sql/relational-databases/resource-governor/tempdb-space-resource-governance?view=sql-server-ver17).

`sql2025/tempdb-governance-catalog.sql` captures default limits and column
descriptors read-only from the pinned oracle. It is investigative, not proof
of enforcement. Configuration/classifier tests must use an isolated oracle
instance so they cannot reclassify or limit concurrent harness sessions.
Required implementation evidence includes classification, configured versus
effective state, allocation/deallocation accounting, errors/rollback, and
shared temp-table ownership. Runtime accounting belongs in pure state; host
resource measurements must remain at the host boundary.

The catalog capture reproduces on a second oracle run. The emulator baseline
returns its explicit unsupported-catalog error for
`sys.resource_governor_workload_groups`; configuration and enforcement cannot
be claimed from the existing system-view descriptors.

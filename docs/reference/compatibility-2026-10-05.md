# Compatibility report follow-up (2026-10-06)

The external report tested bitsql 0.1.7 against SQL Server 2022. Local follow-up
reproduced the reported gaps against bitsql 0.1.13 and captured expectations
from SQL Server 2025 (17.0.5005.3). The application's browser suite is not
available in this repository; these are generic engine reproductions.

## JSON serialization (0.1.14)

`harness/corpus/json3/serialization-compat.sql` covers all datetimeoffset scales
0–7 at zero, positive and negative offsets; SWITCHOFFSET/TODATETIMEOFFSET;
JSON_VALUE/OPENJSON round trips; a FOR JSON AUTO trigger snapshot; sql_variant;
smalldatetime, datetime and datetime2; binary/base64 and ordinary string slashes.
All oracle steps completed without errors. The 0.1.13 baseline fails at the
first UTC timestamp (`+00:00` instead of `Z`).

The fix changes only JSON serialization: preserve nonzero datetimeoffset fraction
precision and use `Z` for zero offset; omit all-zero temporal fractions (including smalldatetime);
leave base64 slashes literal while retaining slash escaping in character data.
CONVERT styles remain unchanged. Style 127 cannot replace JSON's date formatter:
it converts other offsets to UTC. Style 126 supplies the observed fraction rule.

## Unordered scans

`harness/corpus/traps/unordered-index-scans.sql` captures clustered string and
integer keys, update/delete/reinsert, a range predicate, a covering UNIQUE
index and explicit ORDER BY controls. SQL Server 2025 chose ascending key scans;
bitsql 0.1.13 returned insertion order. This remains a documented compatibility
gap. No clustered or covering-index scan order is promised for an unordered
query. Consumers that require sorted results must specify ORDER BY, including
a tie-breaker where the visible sort keys are not unique.

## MERGE trigger order

`harness/corpus/traps/merge-trigger-unordered.sql` captures four source orders
with an AFTER INSERT trigger copying `inserted.name` into an identity audit
table. Both oracle capture and a second oracle run agreed. The two-row sources
`b,a` and `a,b` both produced `b,a` on the local SQL Server 2025 oracle. The
four-row sources `c,a,d,b` and `d,c,b,a` both produced `b,c,d,a`, differing from
the external SQL Server 2022 report (`b,d,a,c` and `a,b,c,d`, respectively).
The local fixture reuses its table across steps, so server version and plan
history are both possible influences; this does not establish a version rule.

The emulator retains its existing behavior. A special case for two source rows
would not reproduce the general plan-dependent behavior. Audit tests should
compare event membership and contents by business key; sorting by an identity
only preserves the assignment that happened, not a source-order contract.
The two ordering probes intentionally remain outside the passing allowlist,
so `npm run diff -- traps/unordered-index-scans.sql traps/merge-trigger-unordered.sql`
continues to expose the differences. Use `--target oracle` to recheck captures.

The reported system-test setup race, screenshot differences and report-archive
failure do not provide evidence for an engine change and are outside this fix.

## Release validation

0.1.14's exact amd64 binary passed `scripts/check.sh`: 275 MoonBit tests,
20702 existing client/corpus passes, three skips and no failures. The new
50-step JSON case passed separately through the corpus client test after its
allowlist selector was corrected to include `.sql`; subsequent full gates
include it. The exact arm64 binary passed the 571-case standard QEMU smoke
and the new JSON case separately (572 cases total). Expectations were also
rechecked on the SQL Server oracle. Browser tests still need an application
rerun. No performance experiment is included in this compatibility release.

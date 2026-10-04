-- ODBCSCALE(type_id, scale) is an undocumented built-in that Prisma's
-- schema engine calls while introspecting sys.columns (`prisma db pull`,
-- `db push`, `migrate diff`). Both arguments convert to tinyint.
-- @step batch
SELECT t.system_type_id, t.name, ODBCSCALE(t.system_type_id, 0) AS s0, ODBCSCALE(t.system_type_id, 3) AS s3,
  ODBCSCALE(t.system_type_id, t.scale) AS sd, ODBCSCALE(t.system_type_id, NULL) AS sn
FROM sys.types t WHERE t.is_user_defined = 0 AND t.name NOT IN (N'vector', N'json')
ORDER BY t.system_type_id, t.user_type_id;
SELECT ODBCSCALE(N'106', 2) AS a, ODBCSCALE(1.5, 2) AS b, ODBCSCALE(CAST(42 AS bigint), CAST(5 AS bigint)) AS c;
-- @step batch
SELECT ODBCSCALE(999, 2) AS a;
-- @step batch
SELECT ODBCSCALE(106, 300) AS a;
-- @step batch
SELECT ODBCSCALE(106, 'x') AS a;
-- @step batch
SELECT ODBCSCALE(106) AS a;

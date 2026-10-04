-- A NULL constant column of a CTE does not type a UNION ALL as int: the
-- other branch's type wins (nvarchar(max) from OPENJSON), also inside an
-- inline table-valued function (reported by an external compatibility
-- test: a JSON diff function failed with 245 converting 'foo' to int, and
-- a three-branch variant returned the wrong column type).
-- @step setup
CREATE FUNCTION dbo.foo(@lhs nvarchar(max), @rhs nvarchar(max))
RETURNS TABLE AS RETURN(
  WITH l AS (SELECT * FROM OPENJSON(@lhs)),
       r AS (SELECT * FROM OPENJSON(@rhs)),
       i AS (SELECT r.[key], NULL AS old_value, r.[value] AS new_value FROM r),
       u AS (SELECT l.[key], l.[value] AS old_value, r.[value] AS new_value
             FROM l JOIN r ON l.[key] = r.[key])
  SELECT * FROM i WHERE @lhs IS NULL
  UNION ALL SELECT * FROM u WHERE @lhs IS NOT NULL
);
-- @step setup
CREATE FUNCTION dbo.foo3(@lhs nvarchar(max), @rhs nvarchar(max))
RETURNS TABLE AS RETURN(
  WITH l AS (SELECT * FROM OPENJSON(@lhs)),
       r AS (SELECT * FROM OPENJSON(@rhs)),
       i AS (SELECT r.[key], NULL AS old_value, r.[value] AS new_value FROM r
             WHERE NOT EXISTS (SELECT 1 FROM l WHERE l.[key] = r.[key])),
       d AS (SELECT l.[key], l.[value] AS old_value, NULL AS new_value FROM l
             WHERE NOT EXISTS (SELECT 1 FROM r WHERE l.[key] = r.[key])),
       u AS (SELECT l.[key], l.[value] AS old_value, r.[value] AS new_value
             FROM l JOIN r ON l.[key] = r.[key] WHERE l.[value] <> r.[value])
  SELECT * FROM i
  UNION ALL SELECT * FROM d
  UNION ALL SELECT * FROM u
);
-- @step batch
SELECT * FROM dbo.foo(N'{"a":"foo"}', N'{"a":"bar"}');
-- @step batch
SELECT * FROM dbo.foo(NULL, N'{"a":"bar","b":1}');
-- @step batch
SELECT * FROM dbo.foo3(N'{"a":"foo","c":2}', N'{"a":"bar","b":1}') ORDER BY [key];
-- @step batch
SELECT name, system_type_name, max_length, is_nullable
FROM sys.dm_exec_describe_first_result_set(N'SELECT * FROM dbo.foo3(N''{}'', N''{}'')', NULL, 0);
-- @step batch
WITH i AS (SELECT N'k' AS k, NULL AS v), u AS (SELECT N'k' AS k, N'abc' AS v)
SELECT * FROM i UNION ALL SELECT * FROM u;
-- @step batch
WITH i AS (SELECT N'k' AS k, NULL AS v), u AS (SELECT N'k' AS k, N'abc' AS v)
SELECT * FROM u UNION SELECT * FROM i;
-- @step batch
SELECT v FROM (SELECT NULL AS v) i EXCEPT SELECT N'abc';

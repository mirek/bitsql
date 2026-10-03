-- Conversions into and out of sql_variant: types a variant cannot hold
-- (529 explicit, 206 assignment), no implicit conversion out of a variant
-- (257), CAST/CONVERT/TRY_CAST out of a variant use the base type (529
-- state 3 at run time, or at compile time for constants).
-- @step batch
SELECT CAST(CAST('x' AS varchar(max)) AS sql_variant);
-- @step batch
SELECT CAST(CAST(N'x' AS nvarchar(max)) AS sql_variant);
-- @step batch
SELECT CAST(CAST(0x01 AS varbinary(max)) AS sql_variant);
-- @step setup
CREATE TABLE dbo.ts (id int NULL, ts timestamp);
INSERT INTO dbo.ts (id) VALUES (1);
-- @step batch
SELECT CAST(ts AS sql_variant) FROM dbo.ts;
-- @step batch
CREATE TABLE #v (v sql_variant);
INSERT INTO #v VALUES (CAST('x' AS varchar(max)));
-- @step batch
DECLARE @v sql_variant = CAST(N'x' AS nvarchar(max));
-- @step batch
DECLARE @i int = CAST(1 AS sql_variant);
-- @step batch
DECLARE @i int;
SET @i = CAST(1 AS sql_variant);
-- @step batch
CREATE TABLE #i (i int);
INSERT INTO #i VALUES (CAST(1 AS sql_variant));
-- @step batch
CREATE TABLE #j (i int);
INSERT INTO #j SELECT CAST(1 AS sql_variant) WHERE 1 = 0;
-- @step batch
DECLARE @v sql_variant = N'a';
PRINT @v;
-- @step batch
SELECT CAST(CAST(N'abc' AS sql_variant) AS int);
-- @step batch
SELECT CAST(CAST('abc' AS sql_variant) AS int);
-- @step batch
SELECT CAST(CAST(1 AS sql_variant) AS date);
-- @step batch
SELECT TRY_CAST(CAST(1 AS sql_variant) AS date);
-- @step batch
SELECT CAST(1.5e0 AS sql_variant) AS f, CAST(CAST(CAST('2024-01-02 03:04:05' AS datetime) AS sql_variant) AS nvarchar(30)) AS dt,
       CONVERT(nvarchar(30), CAST(CAST('2024-01-02 03:04:05' AS datetime) AS sql_variant), 121) AS dt121,
       CAST(CAST(1.50 AS sql_variant) AS int) AS d, CAST(CAST(N'12' AS sql_variant) AS int) AS e,
       CAST(CAST(1 AS sql_variant) AS varbinary(4)) AS f2, CAST(CAST(N'abc' AS sql_variant) AS varchar(2)) AS g,
       CAST(CAST(N'abc' AS sql_variant) AS nvarchar(max)) AS h, CAST(CAST(0x01 AS sql_variant) AS varbinary(max)) AS i,
       CAST(CAST(2.5 AS sql_variant) AS bit) AS j, CAST(CAST(N'2024-01-02' AS sql_variant) AS date) AS k,
       CAST(CAST(CAST('2024-01-01 10:00' AS datetime) AS sql_variant) AS time) AS l,
       CONVERT(nvarchar(30), CAST(1.5 AS sql_variant), 1) AS m,
       CONVERT(varchar(30), CAST(CAST('2024-01-02' AS date) AS sql_variant), 103) AS n,
       CAST(CAST(1.5e0 AS sql_variant) AS nvarchar(30)) AS o;
-- @step batch
CREATE TABLE #c (id int, v sql_variant);
INSERT INTO #c VALUES (1, CAST(1 AS sql_variant));
INSERT INTO #c VALUES (2, CAST(N'x' AS sql_variant));
SELECT id, TRY_CAST(v AS int) AS t FROM #c ORDER BY id;
SELECT id, TRY_CONVERT(int, v) AS t FROM #c ORDER BY id;
SELECT CAST(v AS date) FROM #c;
-- @step batch
DECLARE @v sql_variant = 1;
SELECT CAST(@v AS date);
-- @step batch
CREATE TABLE #d (id int, v sql_variant);
INSERT INTO #d VALUES (1, CAST(N'x' AS sql_variant));
SELECT CAST(v AS int) FROM #d;

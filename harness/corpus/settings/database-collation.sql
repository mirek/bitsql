-- ALTER DATABASE COLLATE: the database default collation types literals,
-- variables, parameters, new columns and the database's catalog views;
-- temp tables take tempdb's collation; existing columns keep theirs.
-- @step batch
CREATE TABLE before_alter (a varchar(10), b nvarchar(10));
-- @step batch
ALTER DATABASE CURRENT COLLATE Latin1_General_100_CS_AS
-- @step batch
SELECT DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS c, DATABASEPROPERTYEX(DB_NAME(), 'SQLSortOrder') AS so, DATABASEPROPERTYEX(DB_NAME(), 'ComparisonStyle') AS cs, DATABASEPROPERTYEX(DB_NAME(), 'LCID') AS l, collation_name FROM sys.databases WHERE name = DB_NAME()
-- @step batch
CREATE TABLE after_alter (a varchar(10), b nvarchar(10), c nvarchar(10) COLLATE SQL_Latin1_General_CP1_CI_AS);
CREATE TABLE #tmp (a varchar(10));
DECLARE @tv TABLE (a varchar(10));
SELECT name, collation_name FROM sys.columns WHERE object_id IN (OBJECT_ID('before_alter'), OBJECT_ID('after_alter')) ORDER BY object_id, column_id;
-- @step batch
DECLARE @v varchar(10) = 'x';
CREATE TABLE #tmp2 (a varchar(10));
DECLARE @tv TABLE (a varchar(10));
SELECT 'lit' AS l, N'n' AS n, @v AS v, (SELECT a FROM #tmp2) AS tmp, (SELECT a FROM @tv) AS tv, (SELECT a FROM after_alter) AS col, (SELECT a FROM before_alter) AS old_col
-- @step batch
SELECT CASE WHEN 'a' = 'A' THEN 1 ELSE 0 END AS lit_eq, CASE WHEN N'a' = N'A' THEN 1 ELSE 0 END AS nlit_eq
-- @step batch
DECLARE @a varchar(10) = 'a', @b varchar(10) = 'A'; SELECT CASE WHEN @a = @b THEN 1 ELSE 0 END AS var_eq
-- @step batch
INSERT after_alter (a, b, c) VALUES ('a', N'a', N'a'); INSERT before_alter VALUES ('a', N'a');
SELECT (SELECT COUNT(*) FROM after_alter WHERE a = 'A') AS new_col, (SELECT COUNT(*) FROM after_alter WHERE c = 'A') AS explicit_col, (SELECT COUNT(*) FROM before_alter WHERE a = 'A') AS old_col
-- @step batch
SELECT name FROM sys.objects WHERE name = 'AFTER_ALTER'
-- @step batch
SELECT COUNT(*) AS n FROM sys.objects WHERE name = 'after_alter'
-- @step batch
SELECT OBJECT_ID('AFTER_ALTER') AS upper_id, CASE WHEN OBJECT_ID('after_alter') IS NULL THEN 0 ELSE 1 END AS found
-- @step batch
SELECT name FROM sys.columns WHERE object_id = OBJECT_ID('after_alter') AND name = 'A'
-- @step batch
SELECT TOP 0 name, type_desc FROM sys.objects; SELECT TOP 0 TABLE_NAME FROM INFORMATION_SCHEMA.TABLES; SELECT TOP 0 name FROM sys.databases
-- @step batch
CREATE TABLE #t3 (a varchar(10)); INSERT #t3 VALUES ('a'); SELECT COUNT(*) AS n FROM #t3 WHERE a = 'A'
-- @step batch
CREATE TABLE #t4 (a varchar(10)); INSERT #t4 VALUES ('a'); SELECT COUNT(*) AS n FROM #t4 t JOIN after_alter a ON a.a = t.a
-- @step rpc
-- @param @p nvarchar(10) = "A"
SELECT CASE WHEN @p = N'a' THEN 1 ELSE 0 END AS param_eq, @p AS p
-- @step batch
ALTER DATABASE CURRENT COLLATE Latin1_General_100_BIN2
-- @step batch
SELECT CASE WHEN 'a' = 'A' THEN 1 ELSE 0 END AS lit_eq, CASE WHEN 'b' > 'C' THEN 1 ELSE 0 END AS bin_order
-- @step batch
ALTER DATABASE CURRENT COLLATE SQL_Latin1_General_CP1_CI_AS
-- @step batch
SELECT CASE WHEN 'a' = 'A' THEN 1 ELSE 0 END AS lit_eq

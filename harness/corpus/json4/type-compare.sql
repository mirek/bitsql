-- The json data type is not comparable: json = json, NULLIF, joins and
-- <> are 13636 state 1, ORDER BY / GROUP BY / window keys 13636 state 2,
-- DISTINCT 421, UNION / INTERSECT 5335, MIN/MAX 8117 state 1, COUNT 8117
-- state 2; json against another type is 402. Character data converts to
-- json implicitly (json has the highest precedence: CASE, COALESCE,
-- ISNULL, IIF, CHOOSE and UNION ALL give json), json converts to nothing
-- implicitly (257 to character types, 206 otherwise). String built-ins
-- reject it with 8116; CONCAT and PRINT report 257.
-- @step setup
CREATE TABLE dbo.tj (id int NOT NULL PRIMARY KEY, j json NULL);
INSERT dbo.tj (id, j) VALUES (1, N'{"a":1}'), (2, '[1, 2]'), (3, NULL);
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT CASE WHEN @j = @j THEN 1 END AS c
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT 1 AS c WHERE @j <> @j
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT NULLIF(@j, @j) AS c
-- @step batch
SELECT o1.id FROM dbo.tj o1 JOIN dbo.tj o2 ON o1.j = o2.j
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT CASE WHEN @j = N'{"a":1}' THEN 1 END AS c
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT 1 AS c WHERE @j > N'x'
-- @step batch
SELECT id FROM dbo.tj WHERE j IN (N'[1]')
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT CASE @j WHEN N'x' THEN 1 END AS c
-- @step batch
SELECT id FROM dbo.tj WHERE j LIKE N'%a%'
-- @step batch
SELECT id FROM dbo.tj ORDER BY j
-- @step batch
SELECT j, COUNT(*) AS n FROM dbo.tj GROUP BY j
-- @step batch
SELECT ROW_NUMBER() OVER (ORDER BY j) AS r FROM dbo.tj
-- @step batch
SELECT ROW_NUMBER() OVER (PARTITION BY j ORDER BY id) AS r FROM dbo.tj
-- @step batch
SELECT DISTINCT j FROM dbo.tj
-- @step batch
SELECT j FROM dbo.tj UNION SELECT j FROM dbo.tj
-- @step batch
SELECT j FROM dbo.tj INTERSECT SELECT j FROM dbo.tj
-- @step batch
SELECT MAX(j) AS m FROM dbo.tj
-- @step batch
SELECT MIN(j) AS m FROM dbo.tj
-- @step batch
SELECT COUNT(j) AS c FROM dbo.tj
-- @step batch
SELECT COUNT(DISTINCT j) AS c FROM dbo.tj
-- @step batch
SELECT SUM(j) AS c FROM dbo.tj
-- @step batch
SELECT STRING_AGG(j, ',') AS s FROM dbo.tj
-- @step batch
SELECT id FROM dbo.tj WHERE j IS NOT NULL ORDER BY id
-- @step batch
SELECT j FROM dbo.tj UNION ALL SELECT CAST(N'[9]' AS json) UNION ALL SELECT N'[ 10 ]'
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT @j AS j UNION ALL SELECT 1
-- @step batch
SELECT ISNULL(j, N'{ }') AS a, COALESCE(j, N'[ ]') AS b, IIF(id = 1, j, CAST(N'[]' AS json)) AS c, CHOOSE(id, j, N'[2]', N'[3]') AS d FROM dbo.tj ORDER BY id
-- @step batch
SELECT CASE WHEN id = 1 THEN j ELSE N'x' END AS a FROM dbo.tj ORDER BY id
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT COALESCE(N'[1]', @j) AS a
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT COALESCE(@j, 1) AS a
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT COALESCE(@j, CAST(1 AS sql_variant)) AS a
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT COALESCE(@j, CAST('<a/>' AS xml)) AS a
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT COALESCE(@j, SYSDATETIME()) AS a
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT COALESCE(@j, NEWID()) AS a
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT COALESCE(@j, 0x01) AS a
-- @step batch
DECLARE @j json = N'{"a":1}'; DECLARE @n nvarchar(max) = @j; SELECT @n AS n
-- @step batch
DECLARE @j json = N'{"a":1}'; DECLARE @v varchar(20) = @j; SELECT @v AS v
-- @step batch
DECLARE @j json = N'{"a":1}'; DECLARE @i int = @j
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT @j + N'x' AS c
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT @j + @j AS c
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT -@j AS c
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT CONCAT(@j, N'x') AS c
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT CONCAT_WS(',', @j, 'x') AS c
-- @step batch
DECLARE @j json = N'{"a":1}'; PRINT @j
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT LEN(@j) AS c
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT UPPER(@j) AS c
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT SUBSTRING(@j, 1, 2) AS c
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT REPLACE(@j, 'a', 'b') AS c
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT TRIM(@j) AS c
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT ISNUMERIC(@j) AS c
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT CHECKSUM(@j) AS c
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT HASHBYTES('SHA1', @j) AS c
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT GREATEST(@j, @j) AS c
-- @step batch
SELECT SQL_VARIANT_PROPERTY(j, 'BaseType') AS c FROM dbo.tj
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT CAST(@j AS nvarchar(max)) + N'x' AS a, CONVERT(varchar(max), @j) AS b
-- @step batch
CREATE INDEX ix_j ON dbo.tj (j)
-- @step batch
CREATE TABLE dbo.tj2 (j json PRIMARY KEY)

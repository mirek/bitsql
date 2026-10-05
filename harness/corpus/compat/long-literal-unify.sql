-- Literals longer than 4000 (N'') / 8000 ('') characters are typed (n)varchar(max),
-- so VALUES / UNION / CASE unification with a short literal keeps the long value
-- (bitsql 0.1.3 compat report: 4060 chars truncated to 4000).
-- @step batch
DECLARE @sql nvarchar(max) =
  N'SELECT CAST(LEN(value) AS int) AS characters, CAST(DATALENGTH(value) AS int) AS bytes
    FROM (VALUES (N''foo''), (N''' + REPLICATE(CAST(N'x' AS nvarchar(max)), 4060)
  + N''')) s(value) ORDER BY 1;';
EXEC sys.sp_executesql @sql;
-- @step batch
DECLARE @sql nvarchar(max) =
  N'SELECT CAST(LEN(value) AS int) AS characters FROM (VALUES (N''' + REPLICATE(CAST(N'x' AS nvarchar(max)), 4001)
  + N'''), (N''a'')) s(value) ORDER BY 1;';
EXEC sys.sp_executesql @sql;
-- @step batch
DECLARE @sql nvarchar(max) =
  N'SELECT CAST(LEN(value) AS int) AS characters FROM (VALUES (N''' + REPLICATE(CAST(N'x' AS nvarchar(max)), 4000)
  + N'''), (N''a'')) s(value) ORDER BY 1;';
EXEC sys.sp_executesql @sql;
-- @step batch
DECLARE @sql nvarchar(max) =
  N'SELECT CAST(LEN(v) AS int) AS characters FROM (SELECT N''foo'' AS v UNION ALL SELECT N'''
  + REPLICATE(CAST(N'x' AS nvarchar(max)), 4060) + N''') u ORDER BY 1;';
EXEC sys.sp_executesql @sql;
-- @step batch
DECLARE @sql nvarchar(max) =
  N'SELECT v FROM (SELECT N''foo'' AS v UNION ALL SELECT N''' + REPLICATE(CAST(N'x' AS nvarchar(max)), 4060)
  + N''') u WHERE 1 = 0;';
EXEC sys.sp_executesql @sql;
-- @step batch
DECLARE @sql nvarchar(max) =
  N'SELECT N''' + REPLICATE(CAST(N'x' AS nvarchar(max)), 4001) + N''' AS v WHERE 1 = 0;';
EXEC sys.sp_executesql @sql;
-- @step batch
DECLARE @sql nvarchar(max) =
  N'SELECT N''' + REPLICATE(CAST(N'x' AS nvarchar(max)), 4000) + N''' AS v WHERE 1 = 0;';
EXEC sys.sp_executesql @sql;
-- @step batch
DECLARE @sql nvarchar(max) =
  N'SELECT ''' + REPLICATE(CAST('x' AS varchar(max)), 8001) + N''' AS v WHERE 1 = 0;';
EXEC sys.sp_executesql @sql;
-- @step batch
DECLARE @sql nvarchar(max) =
  N'SELECT ''' + REPLICATE(CAST('x' AS varchar(max)), 8000) + N''' AS v WHERE 1 = 0;';
EXEC sys.sp_executesql @sql;
-- @step batch
DECLARE @sql nvarchar(max) =
  N'SELECT CAST(LEN(value) AS int) AS characters FROM (VALUES (''foo''), (''' + REPLICATE(CAST('x' AS varchar(max)), 8001)
  + N''')) s(value) ORDER BY 1;';
EXEC sys.sp_executesql @sql;
-- @step batch
DECLARE @sql nvarchar(max) =
  N'SELECT CAST(LEN(value) AS int) AS characters FROM (VALUES (N''foo''), (''' + REPLICATE(CAST('x' AS varchar(max)), 8001)
  + N''')) s(value) ORDER BY 1;';
EXEC sys.sp_executesql @sql;
-- @step batch
DECLARE @sql nvarchar(max) =
  N'SELECT CAST(LEN(value) AS int) AS characters FROM (VALUES (N''foo''), (''' + REPLICATE(CAST('x' AS varchar(max)), 5000)
  + N''')) s(value) ORDER BY 1;';
EXEC sys.sp_executesql @sql;
-- @step batch
DECLARE @sql nvarchar(max) =
  N'SELECT CAST(LEN(CASE WHEN 1 = 1 THEN N''' + REPLICATE(CAST(N'x' AS nvarchar(max)), 4060)
  + N''' ELSE N''a'' END) AS int) AS characters;';
EXEC sys.sp_executesql @sql;
-- @step batch
DECLARE @sql nvarchar(max) =
  N'SELECT v FROM (SELECT 0x' + REPLICATE(CAST('AB' AS varchar(max)), 8001) + N' AS v) b WHERE 1 = 0;';
EXEC sys.sp_executesql @sql;
-- @step batch
DECLARE @sql nvarchar(max) =
  N'SELECT CAST(DATALENGTH(v) AS int) AS bytes FROM (VALUES (0x01), (0x' + REPLICATE(CAST('AB' AS varchar(max)), 8001)
  + N')) b(v) ORDER BY 1;';
EXEC sys.sp_executesql @sql;
-- @step batch
CREATE TABLE #t (id int, v nvarchar(max));
DECLARE @sql nvarchar(max) =
  N'INSERT #t VALUES (1, N''foo''), (2, N''' + REPLICATE(CAST(N'x' AS nvarchar(max)), 4060) + N''');
  INSERT #t SELECT id + 10, value FROM (VALUES (1, N''' + REPLICATE(CAST(N'y' AS nvarchar(max)), 4060)
  + N'''), (2, N''bar'')) s(id, value);';
EXEC sys.sp_executesql @sql;
SELECT id, CAST(LEN(v) AS int) AS characters, CAST(DATALENGTH(v) AS int) AS bytes FROM #t ORDER BY id;
DROP TABLE #t;

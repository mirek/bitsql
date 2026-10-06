-- Concatenation collation resolution and propagation.
-- @step setup
CREATE TABLE dbo.cc (a varchar(10) COLLATE Latin1_General_BIN2, b varchar(10) COLLATE SQL_Latin1_General_CP1_CI_AS);
INSERT dbo.cc VALUES ('a','b');
-- @step batch
SELECT a || b AS result FROM dbo.cc;
-- @step batch
SELECT (a || b) COLLATE Latin1_General_BIN2 AS result FROM dbo.cc;
-- @step batch
SELECT a || (b COLLATE Latin1_General_BIN2) AS result FROM dbo.cc;
-- @step batch
SELECT ('a' COLLATE Latin1_General_BIN2 || 'b') || ('c' COLLATE SQL_Latin1_General_CP1_CI_AS);
-- @step batch
SELECT 'x' || CAST(1.5 AS float) AS f, 'x' || CAST(2 AS money) AS m;
-- @step batch
SELECT N'α' || N'β' AS unicode, N'α' || 'b' AS mixed;
-- @step batch
SELECT DATALENGTH(CAST(REPLICATE('a',8000) AS varbinary(8000)) || 0x01) AS capped;
-- @step batch
SELECT 'x' || (NULL || NULL) AS result;
-- @step batch
SELECT CASE WHEN 'a' || 'b' = 'ab' THEN 1 ELSE 0 END AS folded;
-- @step setup
CREATE TABLE dbo.cn (a nvarchar(10) COLLATE Latin1_General_BIN2, b varchar(10) COLLATE SQL_Latin1_General_CP1_CI_AS);
INSERT dbo.cn VALUES (N'a','b');
-- @step batch
SELECT a || b FROM dbo.cn;
-- @step batch
SELECT b || a FROM dbo.cn;
-- @step batch
SELECT (CASE WHEN 1=1 THEN a ELSE b END) || 'c' FROM dbo.cn;
-- @step batch
DECLARE @u varchar(8000) = REPLICATE('é', 4000);
SELECT DATALENGTH((@u COLLATE Latin1_General_100_BIN2_UTF8) || 'b') AS bytes, RIGHT((@u COLLATE Latin1_General_100_BIN2_UTF8) || 'b', 2) AS tail;
-- @step batch
SELECT ('a' COLLATE Latin1_General_BIN2 || N'b') COLLATE SQL_Latin1_General_CP1_CI_AS AS repaired;
-- @step batch
SELECT CASE WHEN 1=1 THEN a ELSE b END AS bare_case FROM dbo.cn;
-- @step batch
SELECT (CASE WHEN 1=1 THEN a ELSE b END) COLLATE Latin1_General_BIN2 AS repaired_case FROM dbo.cn;

-- SQL Server 2025 concatenation operator exploration.
-- @step batch
SELECT 'a' || 'b' AS chars, N'a' || 'b' AS unicode, 0x01 || 0x0203 AS binary;
-- @step batch
SELECT 'a' || NULL AS n, NULL || NULL AS both_null;
-- @step batch
SELECT 'a' || 1 AS n;
-- @step batch
SELECT 1 || 'a' AS n;
-- @step batch
SELECT 1 || 2 AS n;
-- @step batch
SELECT 0x4142 || 'C' AS mixed;
-- @step batch
SELECT N'C' || 0x4142 AS mixed;
-- @step batch
SELECT 'a' || CAST('b' AS char(3)) AS fixed;
-- @step batch
SELECT CAST('a' AS varchar(20)) || CAST('b' AS varchar(30)) AS lengths;
-- @step batch
SELECT '1' || '2' + '3' AS a, '1' + '2' || '3' AS b;
-- @step batch
SELECT '1' || 2 + 3 AS precedence;
-- @step batch
SELECT 1 + 2 || '3' AS precedence;
-- @step batch
SET CONCAT_NULL_YIELDS_NULL OFF; SELECT 'a' || CAST(NULL AS varchar(3)) AS n;
-- @step batch
SELECT CAST('x' AS text) || 'y';
-- @step batch
SELECT CAST('2020-01-01' AS date) || 'x';
-- @step batch
SELECT 'a' COLLATE Latin1_General_BIN2 || 'b' COLLATE SQL_Latin1_General_CP1_CI_AS;
-- @step batch
SELECT DATALENGTH(REPLICATE('a',8000) || 'b') AS capped, DATALENGTH(CAST(REPLICATE('a',8000) AS varchar(max)) || 'b') AS max_length;

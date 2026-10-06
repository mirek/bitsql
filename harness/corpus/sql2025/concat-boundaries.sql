-- Concatenation type combinations, NULLs, capacities and collation.
-- @step batch
SELECT NULL || 1 AS result;
-- @step batch
SELECT 1 || NULL AS result;
-- @step batch
SELECT 0x01 || NULL AS result;
-- @step batch
SELECT NULL || 0x01 AS result;
-- @step batch
SELECT CAST(NULL AS int) || 'a' AS result;
-- @step batch
SELECT CAST('a' AS sql_variant) || 'b' AS result;
-- @step batch
SELECT CAST('{"a":1}' AS json) || 'b' AS result;
-- @step batch
SELECT CAST('<a/>' AS xml) || 'b' AS result;
-- @step batch
SELECT 'a' || CAST(1.25 AS decimal(5,2)) AS result;
-- @step batch
SELECT 'a' || CAST(1 AS bit) AS result;
-- @step batch
SELECT 'a' || CAST('00112233-4455-6677-8899-AABBCCDDEEFF' AS uniqueidentifier) AS result;
-- @step batch
SELECT 'a' || N'b' AS result;
-- @step batch
SELECT CAST('a' AS char(3)) || CAST('b' AS char(3)) AS result;
-- @step batch
SELECT CAST(0x01 AS binary(3)) || CAST(0x02 AS binary(3)) AS result;
-- @step batch
SELECT CAST(0x01 AS varbinary(max)) || 0x02 AS result;
-- @step batch
SELECT 'a' || 'b' COLLATE Latin1_General_BIN2 AS result;
-- @step batch
SELECT CAST(NULL AS varchar(8000)) || CAST(NULL AS nvarchar(10)) AS result;
-- @step setup
CREATE TABLE dbo.concat_test(a varchar(10) NOT NULL, b varchar(20) NOT NULL, c int NOT NULL, d AS (a || b));
INSERT dbo.concat_test(a,b,c) VALUES ('x','y',2);
-- @step batch
SELECT a || b AS strings, a || c AS converted, d FROM dbo.concat_test;
-- @step batch
SELECT definition FROM sys.computed_columns WHERE object_id=OBJECT_ID('dbo.concat_test');
-- @step batch
SELECT DATALENGTH(REPLICATE(N'a',4000) || N'b') AS unicode_capped, DATALENGTH(REPLICATE('a',8000) || CAST('b' AS varchar(max))) AS promoted;

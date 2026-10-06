-- Regex compatibility and type contracts.
-- @step batch
ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 100;
-- @step batch
SELECT REGEXP_COUNT('abc','a') AS n;
-- @step batch
SELECT CASE WHEN REGEXP_LIKE('abc','a') THEN 1 ELSE 0 END AS n;
-- @step batch
SELECT * FROM REGEXP_MATCHES('abc','a');
-- @step batch
ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 160;
-- @step batch
SELECT REGEXP_COUNT('abc','a') AS n;
-- @step batch
SELECT CASE WHEN REGEXP_LIKE('abc','a') THEN 1 ELSE 0 END AS n;
-- @step batch
SELECT * FROM REGEXP_MATCHES('abc','a');
-- @step batch
ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 170;
-- @step batch
SELECT REGEXP_COUNT('abc','a') AS n;
-- @step batch
SELECT CASE WHEN REGEXP_LIKE('abc','a') THEN 1 ELSE 0 END AS n;
-- @step batch
SELECT * FROM REGEXP_MATCHES('abc','a');
-- @step batch
SELECT REGEXP_SUBSTR(CAST('abc' AS char(8)),'a') AS s, REGEXP_REPLACE(CAST('abc' AS char(8)),'a','x') AS r;
-- @step batch
SELECT REGEXP_SUBSTR(CAST('abc' AS nchar(8)),'a') AS s, REGEXP_REPLACE(CAST('abc' AS nchar(8)),'a','x') AS r;
-- @step batch
SELECT REGEXP_SUBSTR(CAST('abc' AS varchar(20)),'a') AS s, REGEXP_REPLACE(CAST('abc' AS varchar(20)),'a','x') AS r;
-- @step batch
SELECT REGEXP_SUBSTR(CAST('abc' AS nvarchar(20)),'a') AS s, REGEXP_REPLACE(CAST('abc' AS nvarchar(20)),'a','x') AS r;
-- @step batch
SELECT REGEXP_SUBSTR(CAST('abc' AS varchar(max)),'a') AS s, REGEXP_REPLACE(CAST('abc' AS varchar(max)),'a','x') AS r;
-- @step batch
SELECT REGEXP_SUBSTR(CAST('abc' AS nvarchar(max)),'a') AS s, REGEXP_REPLACE(CAST('abc' AS nvarchar(max)),'a','x') AS r;
-- @step batch
SELECT REGEXP_SUBSTR('abc',N'a') AS s, REGEXP_REPLACE('abc','a',N'€') AS r;
-- @step batch
SELECT REGEXP_REPLACE(N'abc','a','x') AS r;
-- @step batch
SELECT REGEXP_COUNT('abc',REPLICATE(CAST('a' AS varchar(max)),8001)) AS n;
-- @step batch
SELECT REGEXP_COUNT('abc',REPLICATE(CAST(N'a' AS nvarchar(max)),4001)) AS n;
-- @step batch
SELECT REGEXP_COUNT('abc','a',CAST(2147483648 AS bigint)) AS n;
-- @step batch
SELECT REGEXP_SUBSTR('abc','a',1,0) AS s;
-- @step batch
SELECT REGEXP_INSTR('abc','a',1,1,2) AS i;
-- @step batch
SELECT REGEXP_REPLACE('abc','a','x',1,-1) AS r;

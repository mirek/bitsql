-- Regex binding, APPLY, length and validation precedence.
-- @step batch
SELECT * FROM REGEXP_MATCHES(CAST(NULL AS varchar(9)),'a');
-- @step batch
SELECT * FROM REGEXP_MATCHES(CAST('abc' AS char(9)),'a');
-- @step batch
SELECT * FROM REGEXP_MATCHES(CAST('abc' AS nchar(9)),'a');
-- @step batch
SELECT * FROM REGEXP_MATCHES(123,'a');
-- @step batch
SELECT * FROM REGEXP_MATCHES('abc',123);
-- @step batch
SELECT * FROM REGEXP_MATCHES(CAST(NULL AS int),'a');
-- @step batch
SELECT * FROM REGEXP_MATCHES('abc',CAST('a' AS varchar(max)));
-- @step batch
SELECT * FROM REGEXP_MATCHES('abc','a',CAST('i' AS varchar(max)));
-- @step batch
SELECT * FROM REGEXP_MATCHES('abc','a','x');
-- @step batch
SELECT * FROM REGEXP_MATCHES('abc',NULL,'x');
-- @step batch
SELECT * FROM REGEXP_MATCHES(NULL,'[','x');
-- @step batch
SELECT * FROM REGEXP_MATCHES('abc','[',NULL);
-- @step batch
SELECT r.* FROM (VALUES (CAST('a' AS varchar(4)),CAST(NULL AS varchar(4))),('abc','a')) v(c,n) CROSS APPLY REGEXP_MATCHES(v.c,'a') r;
-- @step batch
SELECT r.* FROM (VALUES (CAST('a' AS varchar(4)),CAST(NULL AS varchar(4))),('abc','a')) v(c,n) CROSS APPLY REGEXP_MATCHES(v.n,'a') r;
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE(CAST(NULL AS varchar(9)),'a');
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE(CAST('abc' AS char(9)),'a');
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE(CAST('abc' AS nchar(9)),'a');
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE(123,'a');
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE('abc',123);
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE(CAST(NULL AS int),'a');
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE('abc',CAST('a' AS varchar(max)));
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE('abc','a',CAST('i' AS varchar(max)));
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE('abc','a','x');
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE('abc',NULL,'x');
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE(NULL,'[','x');
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE('abc','[',NULL);
-- @step batch
SELECT r.* FROM (VALUES (CAST('a' AS varchar(4)),CAST(NULL AS varchar(4))),('abc','a')) v(c,n) CROSS APPLY REGEXP_SPLIT_TO_TABLE(v.c,'a') r;
-- @step batch
SELECT r.* FROM (VALUES (CAST('a' AS varchar(4)),CAST(NULL AS varchar(4))),('abc','a')) v(c,n) CROSS APPLY REGEXP_SPLIT_TO_TABLE(v.n,'a') r;
-- @step batch
SELECT REGEXP_COUNT(CAST(NULL AS varchar(4)), '[') AS n;
-- @step batch
SELECT REGEXP_SUBSTR(CAST(NULL AS varchar(4)), '[') AS n;
-- @step batch
SELECT REGEXP_INSTR(CAST(NULL AS varchar(4)), '[') AS n;
-- @step batch
SELECT REGEXP_REPLACE(CAST(NULL AS varchar(4)), '[') AS n;
-- @step batch
SELECT REGEXP_REPLACE(REPLICATE('a',8000),'a','bb') AS n;
-- @step batch
SELECT REGEXP_REPLACE(REPLICATE(N'a',4000),'a','bb') AS n;
-- @step batch
SELECT REGEXP_COUNT('a',CAST('a' AS varchar(max))) AS n;
-- @step batch
SELECT REGEXP_COUNT(REPLICATE(CAST('a' AS varchar(max)),100000),'a') AS n;

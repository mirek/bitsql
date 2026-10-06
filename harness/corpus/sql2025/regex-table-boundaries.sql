-- Regex table boundary, capture and compatibility contracts.
-- @step batch
SELECT * FROM REGEXP_MATCHES('ab b','(a)?(b)');
-- @step batch
SELECT * FROM REGEXP_MATCHES('','');
-- @step batch
SELECT * FROM REGEXP_MATCHES('abc','a*');
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE('a,,b,',',');
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE(',a,',',');
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE('abc','');
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE('','');
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE('abc','a*');
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE('abc','z');
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE('abc','(b)');
-- @step batch
ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 160;
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE('abc','b');

-- Regex table function arity, types, optional controls and NULLs.
-- @step batch
SELECT * FROM REGEXP_MATCHES('abc');
-- @step batch
SELECT * FROM REGEXP_MATCHES('abc','b');
-- @step batch
SELECT * FROM REGEXP_MATCHES('abc','b','i');
-- @step batch
SELECT * FROM REGEXP_MATCHES('abc','b',2);
-- @step batch
SELECT * FROM REGEXP_MATCHES('abc','b',1,'i');
-- @step batch
SELECT * FROM REGEXP_MATCHES('abc','b',1,'i',1);
-- @step batch
SELECT * FROM REGEXP_MATCHES(NULL,'b');
-- @step batch
SELECT * FROM REGEXP_MATCHES('abc',NULL);
-- @step batch
SELECT * FROM REGEXP_MATCHES('abc','b',NULL);
-- @step batch
SELECT * FROM REGEXP_MATCHES('abc','b',0);
-- @step batch
SELECT * FROM REGEXP_MATCHES(N'abc','b');
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE('abc');
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE('abc','b');
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE('abc','b','i');
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE('abc','b',2);
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE('abc','b',1,'i');
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE('abc','b',1,'i',1);
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE(NULL,'b');
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE('abc',NULL);
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE('abc','b',NULL);
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE('abc','b',0);
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE(N'abc','b');

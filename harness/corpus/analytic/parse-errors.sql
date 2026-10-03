-- PARSE / TRY_PARSE errors: 9819 (PARSE only, run time after the column
-- metadata), 9818 unsupported cultures, 8116 for non-string input, 10761
-- for target types PARSE does not support.
-- @step batch
SELECT PARSE('(5)' AS int) a;
-- @step batch
SELECT PARSE('abc' AS int) a;
-- @step batch
SELECT PARSE('x' AS int USING 'en-US') a;
-- @step batch
SELECT PARSE('abc' AS date) a;
-- @step batch
SELECT PARSE('1.234' AS decimal(5,1)) a;
-- @step batch
SELECT PARSE('x' AS numeric(5,1)) a;
-- @step batch
SELECT PARSE('x' AS money) a;
-- @step batch
SELECT PARSE('x' AS float) a;
-- @step batch
SELECT PARSE('x' AS datetime2(3)) a;
-- @step batch
SELECT TRY_PARSE('5' AS int USING '') a;
-- @step batch
SELECT TRY_PARSE('5' AS int USING 'Invariant') a;
-- @step batch
SELECT TRY_PARSE('5' AS int USING NULL) a;
-- @step batch
SELECT PARSE(NULL AS int) a;
-- @step batch
SELECT TRY_PARSE(NULL AS int) a;
-- @step batch
SELECT PARSE(5 AS int) a;
-- @step batch
SELECT TRY_PARSE(CAST('2024-01-01' AS date) AS date) a;
-- @step batch
SELECT PARSE(N'5' AS bit) a;
-- @step batch
SELECT PARSE(N'5' AS varchar(10)) a;
-- @step batch
SELECT TRY_PARSE(N'true' AS bit) a;
-- @step batch
SELECT TRY_PARSE(N'x' AS uniqueidentifier) a;
-- @step batch
SELECT 1 AS before_error;
SELECT PARSE('x' AS int) a;
SELECT 2 AS after_error;

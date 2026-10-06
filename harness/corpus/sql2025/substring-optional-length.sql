-- SQL Server 2025 feature audit: substring-optional-length.
-- @step batch
SELECT SUBSTRING('abcdef', 3) AS tail, SUBSTRING(CAST(NULL AS varchar(10)), 3) AS null_tail;
-- @step batch
SELECT SUBSTRING('abcdef', -2) AS negative_start, SUBSTRING('abcdef', 0) AS zero_start, SUBSTRING('abcdef', 99) AS past_end, SUBSTRING(0x01020304, 2) AS binary_tail, SUBSTRING(N'abc  ', 2) AS spaces;
-- @step batch
DECLARE @s varchar(20) = 'abcdef', @i int = 3;
SELECT SUBSTRING(@s, @i) AS variable_tail, SUBSTRING(CAST(@s AS varchar(max)), @i) AS max_tail;
-- @step batch
SELECT SUBSTRING('abc', NULL) AS null_start, SUBSTRING('abc', 1, NULL) AS null_length;
-- @step batch
SELECT SUBSTRING('abc');
-- @step batch
SELECT SUBSTRING('abc', 1, 2, 3);
-- @step batch
SELECT SUBSTRING(NULL, 1);
-- @step batch
SELECT SUBSTRING(123, 1);

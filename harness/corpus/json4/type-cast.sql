-- The json data type (SQL Server 2025): CAST from character data parses and
-- normalizes the text (whitespace dropped, first of duplicate members kept,
-- numbers without exponent kept as written, others as decimal(38,10),
-- strings re-escaped); json travels as varchar(max) with collation
-- Latin1_General_100_BIN2_UTF8. Malformed text is 13609 state 9 at a UTF-8
-- byte position and ends the batch; TRY_CAST gives NULL except for 1007.
-- @step batch
SELECT CAST(N'{ "a" : 1, "b":[1, 2 ,{"c":null}] }' AS json) AS j, CAST(NULL AS json) AS n, CAST('  [ ]  ' AS json) AS e, CAST(N'{}' AS json) AS o
-- @step batch
SELECT CAST(N'[1.50, 1e2, -0, -0.0, 0.00, -1.50, 0.0000001, 12345678901234567890123, 1.5e3, 1e-5, 123e-2, 0e0, 1E+2, 1e-11]' AS json) AS j
-- @step batch
SELECT CAST(N'[1e28, 1.23456789012345e-3, 9223372036854775808, -9223372036854775809, 99999999999999999999999999999999999999]' AS json) AS j
-- @step batch
SELECT CAST(N'[0.12345678901234567890123456789012345678, 10.1234567890123456789012345678901234567, 1.00000000000000000000000000000000000000, 1.99999999999999999999999999999999999999999]' AS json) AS j
-- @step batch
SELECT CAST(REPLACE(N'{"a":"~u0041~n~/x~u00e9~t~b~f~r~"~~~u0001~u001f","b":"', N'~', NCHAR(92)) + NCHAR(127) + NCHAR(128) + NCHAR(8232) + N'/"}' AS json) AS j
-- @step batch
SELECT CAST(N'{"a":1,"b":"' + NCHAR(1) + N'"}' AS json) AS j
-- @step batch
SELECT CAST(REPLACE(N'["~ud83d~ude00", "~ud83d", "~u0000", "', N'~', NCHAR(92)) + NCHAR(55357) + REPLACE(N'", "~uDE00x", "~ud83d~u0041"]', N'~', NCHAR(92)) AS json) AS j
-- @step batch
SELECT CAST(N'{"a":1,"b":2,"a":3,"A":4}' AS json) AS j, CAST(N'{"a":{"x":1,"x":2},"b":[{"y":1,"y":[2]}]}' AS json) AS k
-- @step batch
SELECT CAST(N'[true,false,null,"x"]' AS json) AS j, CAST(N'[' + CHAR(9) + CHAR(10) + CHAR(13) + N'1]' AS json) AS k
-- @step batch
SELECT CAST('{"a":"é"}' AS json) AS j, CAST(CAST(N'{"a":1}' AS json) AS json) AS k, TRY_CONVERT(json, N'[1]') AS t
-- @step batch
SELECT CAST('abc' AS json) AS j; SELECT 'not reached' AS x
-- @step batch
SELECT CAST(N'1' AS json) AS j
-- @step batch
SELECT CAST(N'null' AS json) AS j
-- @step batch
SELECT CAST(N'"s"' AS json) AS j
-- @step batch
SELECT CAST(N'' AS json) AS j
-- @step batch
SELECT CAST(N'   ' AS json) AS j
-- @step batch
SELECT CAST(N'[] x' AS json) AS j
-- @step batch
SELECT CAST(N'["é", x]' AS json) AS j
-- @step batch
SELECT CAST(N'["' + NCHAR(55357) + NCHAR(56832) + N'", x]' AS json) AS j
-- @step batch
SELECT CAST(N'[' + NCHAR(160) + N'1]' AS json) AS j
-- @step batch
SELECT CAST(N'[' + NCHAR(55357) + N']' AS json) AS j
-- @step batch
SELECT CAST(N'["abc' AS json) AS j
-- @step batch
SELECT CAST(N'[1, "x\q"]' AS json) AS j
-- @step batch
SELECT CAST(N'[1, "x\u00"]' AS json) AS j
-- @step batch
SELECT CAST(N'["a' + NCHAR(10) + N'"]' AS json) AS j
-- @step batch
SELECT CAST(N'{"a" 1}' AS json) AS j
-- @step batch
SELECT CAST(N'{a:1}' AS json) AS j
-- @step batch
SELECT CAST(N'[1 2]' AS json) AS j
-- @step batch
SELECT CAST(N'{"a":1}}' AS json) AS j
-- @step batch
SELECT CAST(N'[tru]' AS json) AS j
-- @step batch
SELECT CAST(N'[nul' AS json) AS j
-- @step batch
SELECT CAST(N'[-]' AS json) AS j
-- @step batch
SELECT CAST(N'[1.]' AS json) AS j
-- @step batch
SELECT CAST(N'[1e]' AS json) AS j
-- @step batch
SELECT CAST(N'[.5]' AS json) AS j
-- @step batch
SELECT CAST(N'[+1]' AS json) AS j
-- @step batch
SELECT CAST(N'[01]' AS json) AS j
-- @step batch
SELECT CAST(N'[1, {"a":1,}]' AS json) AS j
-- @step batch
SELECT CAST(N'[1, {"a":1 "b":2}]' AS json) AS j
-- @step batch
SELECT CAST(N'[1, {"a":1, 2:3}]' AS json) AS j
-- @step batch
SELECT CAST(N'[1,]' AS json) AS j
-- @step batch
SELECT CAST(N'{"a":' AS json) AS j
-- @step batch
SELECT CAST(N'{"a"' AS json) AS j
-- @step batch
SELECT CAST(N'[1e300]' AS json) AS j
-- @step batch
SELECT CAST(N'[1e29]' AS json) AS j
-- @step batch
SELECT CAST(N'[999999999999999999999999999999999999999]' AS json) AS j
-- @step batch
SELECT CAST(N'[-99999999999999999999999999999999999999.9]' AS json) AS j
-- @step batch
SELECT CAST(REPLICATE(CAST(N'[' AS nvarchar(max)), 128) + REPLICATE(CAST(N']' AS nvarchar(max)), 128) AS json) AS j
-- @step batch
SELECT CAST(REPLICATE(CAST(N'[' AS nvarchar(max)), 129) + REPLICATE(CAST(N']' AS nvarchar(max)), 129) AS json) AS j
-- @step batch
SELECT TRY_CAST(N'abc' AS json) AS a, TRY_CAST(REPLICATE(CAST(N'[' AS nvarchar(max)), 129) AS json) AS b, TRY_CAST(CAST(N'{"a":1}' AS json) AS char(6)) AS c
-- @step batch
SELECT TRY_CAST(N'[1e300]' AS json) AS a
-- @step batch
SELECT CAST(CAST(N'{"a":1}' AS json) AS nvarchar(max)) AS n, CAST(CAST(N'{"a":1}' AS json) AS varchar(10)) AS v, CAST(CAST(N'{"a":1}' AS json) AS nvarchar(7)) AS n7, CAST(CAST(N'{"a":1}' AS json) AS char(9)) AS c9, CAST(CAST(N'{"a":1}' AS json) AS nchar(10)) AS nc
-- @step batch
SELECT CAST(CAST(N'{"a":1}' AS json) AS varchar) AS v, CAST(CAST(N'{"a":1}' AS json) AS nvarchar) AS n, CONVERT(nvarchar(max), CAST(N'{"a":1}' AS json), 1) AS c, CAST(CAST(N'{"a":"é"}' AS json) AS varchar(9)) AS e
-- @step batch
SELECT CAST(CAST(N'{"a":1}' AS json) AS nvarchar(6)) AS v
-- @step batch
SELECT CAST(CAST(N'{"a":1}' AS json) AS char(6)) AS v
-- @step batch
SELECT CAST(CAST(N'{"a":"' + NCHAR(55357) + NCHAR(56832) + N'"}' AS json) AS nvarchar(9)) AS v
-- @step batch
SELECT CAST(CAST(N'{"a":"' + NCHAR(55357) + NCHAR(56832) + N'"}' AS json) AS nvarchar(10)) AS v
-- @step batch
SELECT CAST(CAST(N'{"a":"' + NCHAR(55357) + NCHAR(56832) + N'"}' AS json) AS varchar(30)) AS v
-- @step batch
SELECT CAST(CAST(N'{"a":"' + NCHAR(256) + N'"}' AS json) AS varchar(30)) AS v
-- @step batch
SELECT CAST(CAST(N'{"a":1}' AS json) AS varbinary(max)) AS v
-- @step batch
SELECT CAST(CAST(N'{"a":1}' AS json) AS int) AS v
-- @step batch
SELECT CAST(CAST(N'{"a":1}' AS json) AS sql_variant) AS v
-- @step batch
SELECT CAST(CAST(N'{"a":1}' AS json) AS xml) AS v
-- @step batch
SELECT CAST(CAST(N'{"a":1}' AS json) AS ntext) AS v
-- @step batch
SELECT CAST(CAST(N'[1]' AS ntext) AS json) AS v
-- @step batch
SELECT CAST(1 AS json) AS v
-- @step batch
SELECT CAST(0x7B7D AS json) AS v
-- @step batch
DECLARE @j json(100) = N'{"a":1}'; SELECT @j AS j
-- @step batch
SELECT CAST(N'{"a":1}' AS json(10)) AS j

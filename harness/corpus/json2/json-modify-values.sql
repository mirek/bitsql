-- JSON_MODIFY new-value formatting: strings escaped, integers and decimals
-- as written (decimals keep their scale), bit true/false, float and real
-- with 16 significant digits in e-notation.
SELECT JSON_MODIFY(N'{"a":1}', '$.b', 1e0) a, JSON_MODIFY(N'{"a":1}', '$.b', 0.1e0) b, JSON_MODIFY(N'{"a":1}', '$.b', CAST(1.5 AS real)) c;
SELECT JSON_MODIFY(N'{"a":1}', '$.b', CAST(1 AS bit)) e, JSON_MODIFY(N'{"a":1}', '$.b', 2147483648) f, JSON_MODIFY(N'{"a":1}', '$.b', CAST(5 AS bigint)) h, JSON_MODIFY(N'{"a":1}', '$.b', CAST(5 AS decimal(5,2))) i, JSON_MODIFY(N'{"a":1}', '$.b', CAST(5 AS tinyint)) j, JSON_MODIFY(N'{"a":1}', '$.b', -1.50) k;
SELECT JSON_MODIFY(N'{"a":1}', '$.b', CAST('x' AS char(3))) a, JSON_MODIFY(N'{"a":1}', '$.b', CHAR(10) + N'/' + NCHAR(1) + N'é') c;
SELECT JSON_MODIFY(N'{"a":1}', '$.b', CAST(0 AS bit)) a, JSON_MODIFY(N'{"a":1}', '$.b', CAST(NULL AS int)) b, JSON_MODIFY(N'{"a":1}', '$.b', CAST(123456789012345 AS float)) c, JSON_MODIFY(N'{"a":1}', '$.b', CAST(1e-7 AS float)) d;
SELECT JSON_MODIFY(N'{"a":1}', '$.b', CAST(N'x' AS nvarchar(max))) a, JSON_MODIFY(CAST(N'{"a":1}' AS nvarchar(max)), '$.b', 1) b, JSON_MODIFY(N'{"a":1}', '$.b', CAST(5 AS smallint)) c, JSON_MODIFY(N'{"a":1}', '$.b', CAST(-3.25 AS numeric(10,3))) d;

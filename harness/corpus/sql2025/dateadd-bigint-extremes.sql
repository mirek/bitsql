-- DATEADD bigint extremes: date ranges, time wrapping, and signed minimum.
-- @step batch
SELECT DATEADD(year, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS datetime2)) AS result;
-- @step batch
SELECT DATEADD(year, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS time)) AS result;
-- @step batch
SELECT DATEADD(year, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(month, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS datetime2)) AS result;
-- @step batch
SELECT DATEADD(month, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS time)) AS result;
-- @step batch
SELECT DATEADD(month, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(day, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS datetime2)) AS result;
-- @step batch
SELECT DATEADD(day, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS time)) AS result;
-- @step batch
SELECT DATEADD(day, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(hour, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS datetime2)) AS result;
-- @step batch
SELECT DATEADD(hour, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS time)) AS result;
-- @step batch
SELECT DATEADD(hour, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(minute, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS datetime2)) AS result;
-- @step batch
SELECT DATEADD(minute, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS time)) AS result;
-- @step batch
SELECT DATEADD(minute, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(second, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS datetime2)) AS result;
-- @step batch
SELECT DATEADD(second, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS time)) AS result;
-- @step batch
SELECT DATEADD(second, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS datetime2)) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS time)) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(microsecond, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS datetime2)) AS result;
-- @step batch
SELECT DATEADD(microsecond, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS time)) AS result;
-- @step batch
SELECT DATEADD(microsecond, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(nanosecond, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS datetime2)) AS result;
-- @step batch
SELECT DATEADD(nanosecond, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS time)) AS result;
-- @step batch
SELECT DATEADD(nanosecond, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(year, CAST('2147483648' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(year, CAST('-2147483649' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(year, CAST('9223372036854775807' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(month, CAST('2147483648' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(month, CAST('-2147483649' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(month, CAST('9223372036854775807' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(day, CAST('2147483648' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(day, CAST('-2147483649' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(day, CAST('9223372036854775807' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(hour, CAST('2147483648' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(hour, CAST('-2147483649' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(hour, CAST('9223372036854775807' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(minute, CAST('2147483648' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(minute, CAST('-2147483649' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(minute, CAST('9223372036854775807' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(second, CAST('2147483648' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(second, CAST('-2147483649' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(second, CAST('9223372036854775807' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('2147483648' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('-2147483649' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('9223372036854775807' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;

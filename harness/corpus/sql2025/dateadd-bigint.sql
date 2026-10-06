-- SQL Server 2025 feature audit: dateadd-bigint.
-- @step batch
SELECT DATEADD(second, CAST(2147483648 AS bigint), CAST('2000-01-01' AS datetime2)) AS future;
-- @step batch
SELECT DATEADD(second, CAST('-2147483649' AS bigint), CAST('2000-01-01' AS datetime2)) AS result;
-- @step batch
SELECT DATEADD(second, CAST('-2147483649' AS bigint), CAST('2000-01-01' AS datetime)) AS result;
-- @step batch
SELECT DATEADD(second, CAST('-2147483649' AS bigint), CAST('12:00:00' AS time)) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('2147483648' AS bigint), CAST('2000-01-01' AS datetime2)) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('2147483648' AS bigint), CAST('2000-01-01' AS datetime)) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('2147483648' AS bigint), CAST('12:00:00' AS time)) AS result;
-- @step batch
SELECT DATEADD(microsecond, CAST('2147483648' AS bigint), CAST('2000-01-01' AS datetime2)) AS result;
-- @step batch
SELECT DATEADD(microsecond, CAST('2147483648' AS bigint), CAST('2000-01-01' AS datetime)) AS result;
-- @step batch
SELECT DATEADD(microsecond, CAST('2147483648' AS bigint), CAST('12:00:00' AS time)) AS result;
-- @step batch
SELECT DATEADD(nanosecond, CAST('9223372036854775807' AS bigint), CAST('2000-01-01' AS datetime2)) AS result;
-- @step batch
SELECT DATEADD(nanosecond, CAST('9223372036854775807' AS bigint), CAST('2000-01-01' AS datetime)) AS result;
-- @step batch
SELECT DATEADD(nanosecond, CAST('9223372036854775807' AS bigint), CAST('12:00:00' AS time)) AS result;
-- @step batch
SELECT DATEADD(nanosecond, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS datetime2)) AS result;
-- @step batch
SELECT DATEADD(nanosecond, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS datetime)) AS result;
-- @step batch
SELECT DATEADD(nanosecond, CAST('-9223372036854775808' AS bigint), CAST('12:00:00' AS time)) AS result;
-- @step batch
SELECT DATEADD(day, CAST('2147483648' AS bigint), CAST('2000-01-01' AS datetime2)) AS result;
-- @step batch
SELECT DATEADD(day, CAST('2147483648' AS bigint), CAST('2000-01-01' AS datetime)) AS result;
-- @step batch
SELECT DATEADD(day, CAST('2147483648' AS bigint), CAST('12:00:00' AS time)) AS result;
-- @step batch
SELECT DATEADD(year, CAST('9223372036854775807' AS bigint), CAST('2000-01-01' AS datetime2)) AS result;
-- @step batch
SELECT DATEADD(year, CAST('9223372036854775807' AS bigint), CAST('2000-01-01' AS datetime)) AS result;
-- @step batch
SELECT DATEADD(year, CAST('9223372036854775807' AS bigint), CAST('12:00:00' AS time)) AS result;
-- @step batch
SELECT DATEADD(hour, CAST('9223372036854775807' AS bigint), CAST('2000-01-01' AS datetime2)) AS result;
-- @step batch
SELECT DATEADD(hour, CAST('9223372036854775807' AS bigint), CAST('2000-01-01' AS datetime)) AS result;
-- @step batch
SELECT DATEADD(hour, CAST('9223372036854775807' AS bigint), CAST('12:00:00' AS time)) AS result;
-- @step batch
SELECT DATEADD(second, CAST('9223372036854775807' AS bigint), CAST('2000-01-01' AS datetime2)) AS result;
-- @step batch
SELECT DATEADD(second, CAST('9223372036854775807' AS bigint), CAST('2000-01-01' AS datetime)) AS result;
-- @step batch
SELECT DATEADD(second, CAST('9223372036854775807' AS bigint), CAST('12:00:00' AS time)) AS result;
-- @step batch
SELECT DATEADD(nanosecond, CAST('-9223372036854775807' AS decimal(38,0)), CAST('2000-01-01' AS datetime2)) AS result;
-- @step batch
SELECT DATEADD(nanosecond, CAST('-9223372036854775759' AS decimal(38,0)), CAST('2000-01-01' AS datetime2)) AS result;
-- @step batch
SELECT DATEADD(nanosecond, CAST('-9223372036854775758' AS decimal(38,0)), CAST('2000-01-01' AS datetime2)) AS result;
-- @step batch
SELECT DATEADD(nanosecond, CAST('-2147483649' AS decimal(38,0)), CAST('2000-01-01' AS datetime2)) AS result;
-- @step batch
SELECT DATEADD(nanosecond, CAST('2147483648' AS decimal(38,0)), CAST('2000-01-01' AS datetime2)) AS result;
-- @step batch
SELECT DATEADD(nanosecond, CAST('9223372036854775808' AS decimal(38,0)), CAST('2000-01-01' AS datetime2)) AS result;
-- @step batch
SELECT DATEADD(nanosecond, CAST('-9223372036854775809' AS decimal(38,0)), CAST('2000-01-01' AS datetime2)) AS result;
-- @step batch
SELECT DATEADD(second, CAST('2147483648' AS bigint), CAST('2000-01-01' AS datetime2)) AS result;
-- @step batch
SELECT DATEADD(second, CAST('2147483648' AS decimal(38,0)), CAST('2000-01-01' AS datetime2)) AS result;
-- @step batch
SELECT DATEADD(second, CAST('2147483648' AS float), CAST('2000-01-01' AS datetime2)) AS result;
-- @step batch
SELECT DATEADD(second, CAST('2147483648' AS bigint), CAST('2000-01-01' AS date)) AS result;
-- @step batch
SELECT DATEADD(month, CAST('9223372036854775807' AS bigint), CAST('2000-01-01' AS date)) AS result;
-- @step batch
SELECT DATEADD(nanosecond, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS date)) AS result;
-- @step batch
SELECT DATEADD(second, CAST('2147483648' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(month, CAST('9223372036854775807' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(nanosecond, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(second, CAST('2147483648' AS bigint), CAST('2000-01-01' AS datetimeoffset(7))) AS result;
-- @step batch
SELECT DATEADD(month, CAST('9223372036854775807' AS bigint), CAST('2000-01-01' AS datetimeoffset(7))) AS result;
-- @step batch
SELECT DATEADD(nanosecond, CAST('-9223372036854775808' AS bigint), CAST('2000-01-01' AS datetimeoffset(7))) AS result;

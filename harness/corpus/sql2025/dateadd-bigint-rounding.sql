-- DATEADD widened arithmetic: scales, offsets and legacy rounding.
-- @step batch
SELECT DATEADD(millisecond, CAST('2147483648' AS bigint), CAST('2000-01-01T12:34:56.789' AS datetime)) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('-2147483649' AS bigint), CAST('2000-01-01T12:34:56.789' AS datetime)) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('2147483650' AS bigint), CAST('2000-01-01T12:34:56.789' AS datetime)) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('-2147483650' AS bigint), CAST('2000-01-01T12:34:56.789' AS datetime)) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('2147483648' AS bigint), CAST('2000-01-01T12:34:56.789' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('-2147483649' AS bigint), CAST('2000-01-01T12:34:56.789' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('2147483650' AS bigint), CAST('2000-01-01T12:34:56.789' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('-2147483650' AS bigint), CAST('2000-01-01T12:34:56.789' AS smalldatetime)) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('2147483648' AS bigint), CAST('2000-01-01T12:34:56.789' AS datetime2(0))) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('-2147483649' AS bigint), CAST('2000-01-01T12:34:56.789' AS datetime2(0))) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('2147483650' AS bigint), CAST('2000-01-01T12:34:56.789' AS datetime2(0))) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('-2147483650' AS bigint), CAST('2000-01-01T12:34:56.789' AS datetime2(0))) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('2147483648' AS bigint), CAST('2000-01-01T12:34:56.789' AS datetime2(3))) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('-2147483649' AS bigint), CAST('2000-01-01T12:34:56.789' AS datetime2(3))) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('2147483650' AS bigint), CAST('2000-01-01T12:34:56.789' AS datetime2(3))) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('-2147483650' AS bigint), CAST('2000-01-01T12:34:56.789' AS datetime2(3))) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('2147483648' AS bigint), CAST('2000-01-01T12:34:56.789' AS datetime2(7))) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('-2147483649' AS bigint), CAST('2000-01-01T12:34:56.789' AS datetime2(7))) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('2147483650' AS bigint), CAST('2000-01-01T12:34:56.789' AS datetime2(7))) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('-2147483650' AS bigint), CAST('2000-01-01T12:34:56.789' AS datetime2(7))) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('2147483648' AS bigint), CAST('2000-01-01T12:34:56.789' AS datetimeoffset(3))) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('-2147483649' AS bigint), CAST('2000-01-01T12:34:56.789' AS datetimeoffset(3))) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('2147483650' AS bigint), CAST('2000-01-01T12:34:56.789' AS datetimeoffset(3))) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('-2147483650' AS bigint), CAST('2000-01-01T12:34:56.789' AS datetimeoffset(3))) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('2147483648' AS bigint), CAST('12:34:56.789' AS time(0))) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('-2147483649' AS bigint), CAST('12:34:56.789' AS time(0))) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('2147483650' AS bigint), CAST('12:34:56.789' AS time(0))) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('-2147483650' AS bigint), CAST('12:34:56.789' AS time(0))) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('2147483648' AS bigint), CAST('12:34:56.789' AS time(3))) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('-2147483649' AS bigint), CAST('12:34:56.789' AS time(3))) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('2147483650' AS bigint), CAST('12:34:56.789' AS time(3))) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('-2147483650' AS bigint), CAST('12:34:56.789' AS time(3))) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('2147483648' AS bigint), CAST('12:34:56.789' AS time(7))) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('-2147483649' AS bigint), CAST('12:34:56.789' AS time(7))) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('2147483650' AS bigint), CAST('12:34:56.789' AS time(7))) AS result;
-- @step batch
SELECT DATEADD(millisecond, CAST('-2147483650' AS bigint), CAST('12:34:56.789' AS time(7))) AS result;
-- @step batch
SELECT DATEADD(nanosecond, CAST('2147483648' AS bigint), CAST('0001-01-01T00:00:00' AS datetime2(7))) AS result;
-- @step batch
SELECT DATEADD(nanosecond, CAST('-2147483649' AS bigint), CAST('0001-01-01T00:00:00' AS datetime2(7))) AS result;
-- @step batch
SELECT DATEADD(nanosecond, CAST('2147483648' AS bigint), CAST('9999-12-31T23:59:59.9999999' AS datetime2(7))) AS result;
-- @step batch
SELECT DATEADD(nanosecond, CAST('-2147483649' AS bigint), CAST('9999-12-31T23:59:59.9999999' AS datetime2(7))) AS result;
-- @step batch
SELECT DATEADD(nanosecond, CAST('2147483648' AS bigint), CAST('0001-01-01T00:00:00' AS datetimeoffset(7))) AS result;
-- @step batch
SELECT DATEADD(nanosecond, CAST('-2147483649' AS bigint), CAST('0001-01-01T00:00:00' AS datetimeoffset(7))) AS result;
-- @step batch
SELECT DATEADD(nanosecond, CAST('2147483648' AS bigint), CAST('9999-12-31T23:59:59.9999999' AS datetimeoffset(7))) AS result;
-- @step batch
SELECT DATEADD(nanosecond, CAST('-2147483649' AS bigint), CAST('9999-12-31T23:59:59.9999999' AS datetimeoffset(7))) AS result;

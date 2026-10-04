-- CONVERT of date, time, datetime2 and datetimeoffset to binary: their
-- storage bytes (scale byte, time in 10^-scale s units, date as days since
-- 0001-01-01, offset minutes; all little-endian). Cutting a scale-prefixed
-- value is 8152 state 17.
-- @step batch
SELECT CONVERT(varbinary(20), CAST('2024-03-01' AS date)) AS d, CONVERT(varbinary(20), CAST('12:34:56.1234567' AS time(7))) AS t7, CONVERT(varbinary(20), CAST('12:34:56.12' AS time(2))) AS t2, CONVERT(varbinary(20), CAST('12:34:56.12345' AS time(5))) AS t5, CONVERT(binary(8), CAST('12:34:56' AS time(0))) AS b8, CONVERT(binary(6), CAST('2024-03-01' AS date)) AS b6, CONVERT(varbinary(20), CAST('2024-03-01 01:02:03.1234567 +05:30' AS datetimeoffset(7))) AS dto7, CAST(CAST('12:34:56' AS time(0)) AS varbinary(10)) AS castt, CONVERT(varbinary(20), CAST('2024-03-01 01:02:03.1234567 +05:30' AS datetimeoffset(2))) AS dto2, CONVERT(varbinary(20), CAST('0001-01-01 00:00:00' AS datetime2(4))) AS dt2min, CONVERT(varbinary(20), CAST('9999-12-31 23:59:59.9999999' AS datetime2(7))) AS dt2max
-- @step batch
SELECT CONVERT(binary(3), CAST('12:34:56' AS time(0))) AS b3
-- @step batch
SELECT CONVERT(varbinary(4), CAST('12:34:56' AS time(0))) AS v4, CONVERT(varbinary(3), CAST('2024-03-01' AS date)) AS v3, CONVERT(varbinary(8), CAST('2024-03-01 10:00' AS datetime2(3))) AS v8

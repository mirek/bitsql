-- DATE_BUCKET(part, width, date [, origin]): default origin 1900-01-01
-- (a Monday), fixed-length parts counted from the origin with floor
-- division, month/quarter/year stepping like DATEADD from the origin,
-- datetimeoffset bucketed in UTC keeping its offset, time wrapping at
-- midnight, result precision the larger of date and origin.
-- @step batch
DECLARE @d datetime2 = '2024-05-17 13:47:29.1234567';
SELECT DATE_BUCKET(year, 1, @d) y, DATE_BUCKET(quarter, 1, @d) q, DATE_BUCKET(month, 1, @d) m, DATE_BUCKET(week, 1, @d) w, DATE_BUCKET(day, 1, @d) d, DATE_BUCKET(hour, 1, @d) h, DATE_BUCKET(minute, 1, @d) mi, DATE_BUCKET(second, 1, @d) s, DATE_BUCKET(millisecond, 1, @d) ms;
-- @step batch
DECLARE @d datetime2 = '2024-05-17 13:47:29.1234567';
SELECT CAST(DATE_BUCKET(year, 3, @d) AS nvarchar(40)) y, CAST(DATE_BUCKET(month, 5, @d) AS nvarchar(40)) m, CAST(DATE_BUCKET(week, 2, @d) AS nvarchar(40)) w, CAST(DATE_BUCKET(day, 10, @d) AS nvarchar(40)) d, CAST(DATE_BUCKET(hour, 7, @d) AS nvarchar(40)) h, CAST(DATE_BUCKET(minute, 15, @d) AS nvarchar(40)) mi, CAST(DATE_BUCKET(second, 45, @d) AS nvarchar(40)) s, CAST(DATE_BUCKET(millisecond, 250, @d) AS nvarchar(40)) ms;
-- @step batch
DECLARE @d datetime2 = '2024-05-17 13:47:29.1234567', @o datetime2 = '2024-01-03 05:00:00';
SELECT CAST(DATE_BUCKET(day, 7, @d, @o) AS nvarchar(40)) a, CAST(DATE_BUCKET(month, 2, @d, @o) AS nvarchar(40)) b, CAST(DATE_BUCKET(hour, 5, @d, @o) AS nvarchar(40)) c, CAST(DATE_BUCKET(year, 1, @d, @o) AS nvarchar(40)) d;
-- @step batch
DECLARE @d datetime2 = '2023-12-31 23:00', @o datetime2 = '2024-01-03 05:00:00';
SELECT CAST(DATE_BUCKET(day, 7, @d, @o) AS nvarchar(40)) a, CAST(DATE_BUCKET(month, 2, @d, @o) AS nvarchar(40)) b, CAST(DATE_BUCKET(year, 1, @d, @o) AS nvarchar(40)) c, CAST(DATE_BUCKET(month, 1, CAST('2024-03-31' AS datetime2), CAST('2024-01-31' AS datetime2)) AS nvarchar(40)) d;
-- @step batch
SELECT CAST(DATE_BUCKET(month, 1, CAST('2024-02-29' AS datetime2), CAST('2024-01-31' AS datetime2)) AS nvarchar(40)) a, CAST(DATE_BUCKET(month, 1, CAST('2024-02-28' AS datetime2), CAST('2024-01-31' AS datetime2)) AS nvarchar(40)) b, CAST(DATE_BUCKET(month, 1, CAST('2024-03-30' AS datetime2), CAST('2024-01-31' AS datetime2)) AS nvarchar(40)) c, CAST(DATE_BUCKET(month, 2, CAST('2024-04-30' AS datetime2), CAST('2023-12-31' AS datetime2)) AS nvarchar(40)) d;
-- @step batch
SELECT CAST(DATE_BUCKET(month, 1, CAST('2024-03-31 10:00' AS datetime2), CAST('2024-01-31 12:00' AS datetime2)) AS nvarchar(40)) a, CAST(DATE_BUCKET(month, 1, CAST('2024-02-29 13:00' AS datetime2), CAST('2024-01-31 12:00' AS datetime2)) AS nvarchar(40)) b, CAST(DATE_BUCKET(year, 1, CAST('2025-02-28' AS datetime2), CAST('2024-02-29' AS datetime2)) AS nvarchar(40)) c, CAST(DATE_BUCKET(quarter, 2, CAST('2024-08-15' AS datetime2), CAST('2024-02-10' AS datetime2)) AS nvarchar(40)) d;
-- @step batch
SELECT DATE_BUCKET(day, 1, CAST('2024-05-17' AS date)) a, DATE_BUCKET(week, 1, CAST('2024-05-17' AS date)) b, DATE_BUCKET(month, 1, CAST('2024-05-17 10:11:12.347' AS datetime)) c, DATE_BUCKET(minute, 1, CAST('2024-05-17 10:11:42' AS smalldatetime)) d, DATE_BUCKET(hour, 1, CAST('10:11:42.1234' AS time(4))) e, DATE_BUCKET(hour, 2, CAST('2024-05-17 10:11:42 +05:30' AS datetimeoffset(3))) f;
-- @step batch
SELECT CAST(DATE_BUCKET(hour, 2, CAST('2024-05-17 10:11:42 +05:30' AS datetimeoffset(3))) AS nvarchar(40)) f, CAST(DATE_BUCKET(day, 1, CAST('2024-05-17 01:11:42 +05:30' AS datetimeoffset(3))) AS nvarchar(40)) g, CAST(DATE_BUCKET(hour, 1, CAST('10:11:42.1234' AS time(4))) AS nvarchar(40)) h, CAST(DATE_BUCKET(minute, 25, CAST('10:11:42.1234' AS time(4))) AS nvarchar(40)) i;
-- @step batch
SELECT CAST(DATE_BUCKET(day, 1, CAST('2024-05-17 00:00 +02:00' AS datetimeoffset(3)), CAST('2024-01-01 00:00 +05:00' AS datetimeoffset(7))) AS nvarchar(50)) b, CAST(DATE_BUCKET(week, 1, CAST('2024-05-17 00:00 +02:00' AS datetimeoffset(3))) AS nvarchar(50)) a, CAST(DATE_BUCKET(month, 1, CAST('2024-05-01 01:00 +05:00' AS datetimeoffset(3))) AS nvarchar(50)) c, CAST(DATE_BUCKET(year, 1, CAST('2024-01-01 01:00 +05:00' AS datetimeoffset(3))) AS nvarchar(50)) d;
-- @step batch
SELECT CAST(DATE_BUCKET(hour, 1, CAST('23:59:59.9999999' AS time(7)), CAST('00:30' AS time(0))) AS nvarchar(30)) a, CAST(DATE_BUCKET(hour, 1, CAST('00:10' AS time(7)), CAST('00:30' AS time(0))) AS nvarchar(30)) b, DATE_BUCKET(second, 7, CAST('2024-05-17 00:00:20' AS datetime2(0)), CAST('2024-05-17 00:00:00.5' AS datetime2(1))) c, DATE_BUCKET(second, 7, CAST('2024-05-17 00:00:20' AS datetime2(3)), CAST('2024-05-17 00:00:00.5' AS datetime2(1))) d;
-- @step batch
SELECT DATE_BUCKET(dd, 2, CAST('2024-05-17' AS date)) a, DATE_BUCKET(wk, 1, CAST('2024-05-17' AS date)) b, DATE_BUCKET(yy, 1, CAST('2024-05-17' AS date)) c, DATE_BUCKET(qq, 1, CAST('2024-05-17' AS date)) d, DATE_BUCKET(m, 1, CAST('2024-05-17' AS date)) e, DATE_BUCKET(day, 1.5, CAST('2024-05-17' AS date)) f, DATE_BUCKET(day, CAST(2 AS bigint), CAST('2024-05-17' AS date)) g, DATE_BUCKET(day, 2e0, CAST('2024-05-17' AS date)) h;
-- @step batch
SELECT DATE_BUCKET(day, 2147483647, CAST('2024-05-17' AS date)) a, CAST(DATE_BUCKET(year, 1, CAST('0001-06-01' AS datetime2), CAST('9999-01-01' AS datetime2)) AS nvarchar(40)) b, CAST(DATE_BUCKET(day, 1, CAST('1899-06-01' AS datetime2)) AS nvarchar(40)) c, CAST(DATE_BUCKET(week, 1, CAST('1899-06-01' AS datetime2)) AS nvarchar(40)) d, CAST(DATE_BUCKET(month, 7, CAST('1899-06-01' AS datetime2)) AS nvarchar(40)) e;
-- @step batch
SELECT DATE_BUCKET(day, 3, CAST('1900-01-02' AS datetime)) a, DATE_BUCKET(day, 3, CAST('1900-01-01' AS datetime)) b, DATE_BUCKET(day, 3, CAST('1899-12-31' AS datetime2)) c, DATE_BUCKET(minute, 7, CAST('2024-05-17 10:11:42' AS smalldatetime)) d, CAST(DATE_BUCKET(millisecond, 3, CAST('2024-05-17 00:00:00.0105' AS datetime2(4))) AS nvarchar(40)) e;
-- @step batch
SELECT CAST(DATE_BUCKET(millisecond, 1, CAST('2024-05-17 10:00:00.007' AS datetime)) AS nvarchar(40)) a, CAST(DATE_BUCKET(millisecond, 10, CAST('2024-05-17 10:00:00.997' AS datetime)) AS nvarchar(40)) b, CAST(DATE_BUCKET(second, 1, CAST('2024-05-17 10:00:00.997' AS datetime)) AS nvarchar(40)) c, CAST(DATE_BUCKET(hour, 1, CAST('2024-05-17 10:59:59.997' AS datetime), CAST('2024-01-01 00:00:00.003' AS datetime)) AS nvarchar(40)) d;
-- @step batch
DECLARE @x int = 3, @n int = NULL;
SELECT DATE_BUCKET(day, @x, CAST('2024-05-17' AS date)) a, DATE_BUCKET(day, @n, CAST('2024-05-17' AS date)) b, DATE_BUCKET(day, 1, CAST(NULL AS date)) c, DATE_BUCKET(day, 1, CAST('2024-05-17' AS date), CAST(NULL AS date)) d, DATE_BUCKET(day, 1, CAST('2024-05-17' AS date), NULL) e, DATE_BUCKET(day, 1, CAST('2024-05-17' AS datetime2(3)), CAST('2024-01-01' AS datetime2(7))) f;
-- @step batch
SELECT id, d, DATE_BUCKET(week, 1, d) wk, DATE_BUCKET(month, 3, d, CAST('2024-02-01' AS date)) m3 FROM (VALUES (1, CAST('2024-01-01' AS date)), (2, CAST('2024-02-29' AS date)), (3, CAST('2024-12-31' AS date)), (4, CAST(NULL AS date))) t(id, d) ORDER BY id;

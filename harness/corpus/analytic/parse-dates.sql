-- PARSE / TRY_PARSE to date/time types (.NET DateTime.Parse, en-US): ISO
-- dates with - / . separators, M/d/yyyy and two-digit years, month and day
-- names, times with fractions and AM/PM, datetimeoffset offsets, rounding
-- per target type. Clock-dependent shapes (time-only text for date targets,
-- dates without a year) are not used here.
-- @step batch
SELECT TRY_PARSE('2024-01-15' AS date) a, TRY_PARSE('01/15/2024' AS date) b, TRY_PARSE('15/01/2024' AS date) c, TRY_PARSE('Monday, January 15, 2024' AS date) d, TRY_PARSE('Jan 15 2024' AS date) e, TRY_PARSE('15 Jan 2024' AS date) f, TRY_PARSE('2024-01-15 10:00' AS date) g, TRY_PARSE('1/2/24' AS date) h;
-- @step batch
SELECT TRY_PARSE('2024-13-01' AS date) a, TRY_PARSE('2024-02-30' AS date) b, TRY_PARSE('1752-01-01' AS datetime) c, TRY_PARSE('0001-01-01' AS date) d, TRY_PARSE('2024/01/15' AS date) e, TRY_PARSE('20240115' AS date) f, TRY_PARSE('2024.01.15' AS date) g, TRY_PARSE('1.15.2024' AS date) h;
-- @step batch
SELECT TRY_PARSE('January 15, 2024' AS date) a, TRY_PARSE('Jan 15, 2024' AS date) b, TRY_PARSE('15-Jan-2024' AS date) c, TRY_PARSE('jan 15 2024' AS date) d, TRY_PARSE('Tuesday, January 15, 2024' AS date) f, TRY_PARSE('2024 Jan 15' AS date) g, TRY_PARSE('January 2024' AS date) h, TRY_PARSE('2024-01' AS date) i;
-- @step batch
SELECT TRY_PARSE('15' AS date) c, TRY_PARSE('2024' AS date) d, TRY_PARSE('abc' AS date) e, TRY_PARSE('' AS date) f, TRY_PARSE(' 2024-01-15 ' AS date) g, TRY_PARSE('12/31/99' AS date) h, TRY_PARSE('12/31/29' AS date) i, TRY_PARSE('12/31/30' AS date) j, TRY_PARSE('12/31/49' AS date) k, TRY_PARSE('12/31/50' AS date) l;
-- @step batch
SELECT CAST(TRY_PARSE('2024-01-15 13:45:30.1234567' AS datetime2) AS nvarchar(40)) a, CAST(TRY_PARSE('2024-01-15 13:45:30.1234567' AS datetime2(2)) AS nvarchar(40)) b, CAST(TRY_PARSE('2024-01-15 13:45:30.1239' AS datetime) AS nvarchar(40)) c, CAST(TRY_PARSE('2024-01-15T13:45:30' AS datetime2(0)) AS nvarchar(40)) d;
-- @step batch
SELECT CAST(TRY_PARSE('1/15/2024 13:00' AS datetime2) AS nvarchar(40)) a, CAST(TRY_PARSE('1/15/2024 1:00:05 AM' AS datetime2) AS nvarchar(40)) b, CAST(TRY_PARSE('1/15/2024 12:00 AM' AS datetime2) AS nvarchar(40)) c, CAST(TRY_PARSE('1/15/2024 12:00 PM' AS datetime2) AS nvarchar(40)) d, CAST(TRY_PARSE('2024-01-15 1 PM' AS datetime2) AS nvarchar(40)) e, CAST(TRY_PARSE('1/15/2024 13:00 PM' AS datetime2) AS nvarchar(40)) f;
-- @step batch
SELECT TRY_PARSE('2024-01-15 24:00' AS datetime2) c, TRY_PARSE('2024-01-15 10:60' AS datetime2) d, TRY_PARSE('2024-01-15 10:00:60' AS datetime2) e, CAST(TRY_PARSE('2024-01-15 10:00:00.12345678' AS datetime2) AS nvarchar(40)) f, CAST(TRY_PARSE('2024-01-15 10:00:00.99999999' AS datetime2) AS nvarchar(40)) g, CAST(TRY_PARSE('2024-01-15 10:00:00.9995' AS datetime) AS nvarchar(40)) h;
-- @step batch
SELECT CAST(TRY_PARSE('10:15' AS time) AS nvarchar(30)) a, CAST(TRY_PARSE('10:15:30.1234567' AS time) AS nvarchar(30)) b, CAST(TRY_PARSE('2024-01-01 10:15' AS time) AS nvarchar(30)) c, CAST(TRY_PARSE('1:15 PM' AS time(0)) AS nvarchar(30)) d;
-- @step batch
SELECT CAST(TRY_PARSE('2024-01-01 10:15 +02:00' AS datetimeoffset) AS nvarchar(50)) a, CAST(TRY_PARSE('2024-01-01 10:15' AS datetimeoffset) AS nvarchar(50)) b, CAST(TRY_PARSE('2024-01-01T10:15:00Z' AS datetimeoffset) AS nvarchar(50)) c, CAST(TRY_PARSE('2024-01-01 10:15:29.999' AS smalldatetime) AS nvarchar(50)) d, CAST(TRY_PARSE('2024-01-01 10:15:30' AS smalldatetime) AS nvarchar(50)) e, CAST(TRY_PARSE('2024-01-01 10:15 -05:30' AS datetimeoffset(0)) AS nvarchar(50)) f;
-- @step batch
SELECT TRY_PARSE('2024-01-15' AS datetime2) a, TRY_PARSE('2024-01-15' AS datetime) b, TRY_PARSE('2024-01-15' AS smalldatetime) c, TRY_PARSE('2024-01-15' AS datetimeoffset) d, TRY_PARSE('2024-01-15' AS time) e, TRY_PARSE('2079-06-07' AS smalldatetime) f;
-- @step batch
SELECT CAST(TRY_PARSE('15/01/2024' AS date USING 'iv') AS nvarchar(30)) a, CAST(TRY_PARSE('01/15/2024 10:00 PM' AS datetime2 USING 'iv') AS nvarchar(30)) b, CAST(TRY_PARSE('2024-01-15' AS date USING 'iv') AS nvarchar(30)) c;
-- @step batch
SELECT PARSE('2024-02-30' AS date) a;

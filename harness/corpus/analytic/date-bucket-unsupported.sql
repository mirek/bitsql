-- DATE_BUCKET with a month/quarter/year width whose month count overflows
-- int32 and a date before the origin: SQL Server returns a wrapped bucket
-- (1901-01-01 here); bitsql raises emulator error 50170.
SELECT DATE_BUCKET(year, 2147483647, CAST('1800-01-01' AS date)) a;

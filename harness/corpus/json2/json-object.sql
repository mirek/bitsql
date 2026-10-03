-- JSON_OBJECT (SQL Server 2022 syntax): key:value pairs, NULL ON NULL by
-- default, ABSENT ON NULL, value formatting per type, nested JSON values
-- (JSON_OBJECT/JSON_ARRAY/JSON_QUERY) embedded raw, strings escaped.
-- @step batch
SELECT JSON_OBJECT() a, JSON_OBJECT('a':1) b, JSON_OBJECT('a':1, 'b':N'x', 'c':NULL, 'd':1.50, 'e':CAST(1 AS bit), 'f':1e0, 'g':CAST('2024-01-02' AS date)) c;
SELECT JSON_OBJECT('a':NULL ABSENT ON NULL) a, JSON_OBJECT('a':NULL NULL ON NULL) b, JSON_OBJECT('a':NULL, 'b':2 ABSENT ON NULL) c;
SELECT JSON_OBJECT('a':JSON_OBJECT('b':2), 'c':JSON_ARRAY(1,2)) a, JSON_OBJECT('a':'{"x":1}') b, JSON_OBJECT('a':JSON_QUERY('{"x":1}')) c;
-- @step batch
SELECT JSON_OBJECT('a"b':'c"d\e/f' + CHAR(10) + CHAR(9)) a, JSON_OBJECT(N'ü':N'é😀') b, JSON_OBJECT('a':CAST(1 AS money), 'b':CAST(2.5 AS real), 'c':CAST(0x0102 AS varbinary(2))) c;
SELECT JSON_OBJECT('a':CAST('2024-01-02 03:04:05.123' AS datetime), 'b':CAST('2024-01-02 03:04:05.1234567' AS datetime2), 'c':CAST('03:04:05' AS time), 'd':CAST('2024-01-02 03:04:05 +01:00' AS datetimeoffset)) a;
SELECT JSON_OBJECT('a':1, 'a':2) a, JSON_OBJECT(1:1) b;
DECLARE @k nvarchar(10) = N'key'; SELECT JSON_OBJECT(@k:@k) a;
-- @step batch
SELECT JSON_OBJECT('a':CAST(1e308 AS float), 'b':CAST(0.1 AS float), 'c':CAST(123456789.123 AS float), 'e':CAST(1.5 AS decimal(10,4))) a;
SELECT JSON_OBJECT('a':CAST(N'x' AS nvarchar(max))) a, JSON_OBJECT('a':CAST(1 AS sql_variant)) b;
SELECT id, JSON_OBJECT('id':id, 'n':n) FROM (VALUES (1, N'a'), (2, NULL)) t(id, n) ORDER BY id;
SELECT JSON_OBJECT('a':CAST(9223372036854775807 AS bigint), 'b':CAST(255 AS tinyint), 'c':CAST(-1 AS smallint)) a;
SELECT JSON_OBJECT('a':CAST('x' AS char(3)), 'b':CAST(N'y' AS nchar(2)), 'c':CAST(0x41 AS binary(3))) a;
SELECT JSON_OBJECT('t':CAST('03:04:05.1200' AS time(4)), 'd2':CAST('2024-01-02 03:04:05' AS datetime2(0)), 'o':CAST('2024-01-02 03:04:05.5 -07:30' AS datetimeoffset(2)), 's':CAST('2024-01-02 03:04' AS smalldatetime), 'dt':CAST('2024-01-02 03:04:05' AS datetime), 't0':CAST('03:04:05' AS time(0))) a;
-- @step batch
SELECT JSON_OBJECT(NULL:1) a;
-- @step batch
SELECT JSON_OBJECT('a', 1) a;

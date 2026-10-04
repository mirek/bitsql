-- PERSISTED computed columns must be deterministic (4936): clock, random,
-- metadata/security/session/error functions, @@ globals, FORMAT, DATENAME,
-- ISDATE, PARSE, AT TIME ZONE, DATEPART week/weekday, sql_variant sources
-- and character <-> date/time conversions without a deterministic style
-- (explicit or implicit, also inside date functions). Generated from three
-- probe lists; each step is one CREATE TABLE.
-- @step batch
CREATE TABLE dbo.p0 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(date, s) PERSISTED);
-- @step batch
CREATE TABLE dbo.p1 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(date, s, 126) PERSISTED);
-- @step batch
CREATE TABLE dbo.p2 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(date, s, 23) PERSISTED);
-- @step batch
CREATE TABLE dbo.p3 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(date, s, 101) PERSISTED);
-- @step batch
CREATE TABLE dbo.p4 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(date, s, 103) PERSISTED);
-- @step batch
CREATE TABLE dbo.p5 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(date, s, 112) PERSISTED);
-- @step batch
CREATE TABLE dbo.p6 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(date, s, 120) PERSISTED);
-- @step batch
CREATE TABLE dbo.p7 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(date, s, 121) PERSISTED);
-- @step batch
CREATE TABLE dbo.p8 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(date, s, 20) PERSISTED);
-- @step batch
CREATE TABLE dbo.p9 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(date, s, 21) PERSISTED);
-- @step batch
CREATE TABLE dbo.p10 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(date, s, 1) PERSISTED);
-- @step batch
CREATE TABLE dbo.p11 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(date, s, 106) PERSISTED);
-- @step batch
CREATE TABLE dbo.p12 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(date, s, 107) PERSISTED);
-- @step batch
CREATE TABLE dbo.p13 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(date, s, 109) PERSISTED);
-- @step batch
CREATE TABLE dbo.p14 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(date, s, 113) PERSISTED);
-- @step batch
CREATE TABLE dbo.p15 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(date, s, 127) PERSISTED);
-- @step batch
CREATE TABLE dbo.p16 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(date, s, 130) PERSISTED);
-- @step batch
CREATE TABLE dbo.p17 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(date, s, 0) PERSISTED);
-- @step batch
CREATE TABLE dbo.p18 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CAST(s AS date) PERSISTED);
-- @step batch
CREATE TABLE dbo.p19 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CAST(s AS datetime2) PERSISTED);
-- @step batch
CREATE TABLE dbo.p20 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CAST(s AS time) PERSISTED);
-- @step batch
CREATE TABLE dbo.p21 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CAST(s AS datetimeoffset) PERSISTED);
-- @step batch
CREATE TABLE dbo.p22 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CAST(s AS datetime) PERSISTED);
-- @step batch
CREATE TABLE dbo.p23 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CAST(s AS smalldatetime) PERSISTED);
-- @step batch
CREATE TABLE dbo.p24 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(datetime, s, 126) PERSISTED);
-- @step batch
CREATE TABLE dbo.p25 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(datetime, s, 120) PERSISTED);
-- @step batch
CREATE TABLE dbo.p26 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(datetime, s, 101) PERSISTED);
-- @step batch
CREATE TABLE dbo.p27 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CAST(d AS nvarchar(30)) PERSISTED);
-- @step batch
CREATE TABLE dbo.p28 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(nvarchar(30), d, 126) PERSISTED);
-- @step batch
CREATE TABLE dbo.p29 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(nvarchar(30), d, 101) PERSISTED);
-- @step batch
CREATE TABLE dbo.p30 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CAST(dt AS nvarchar(30)) PERSISTED);
-- @step batch
CREATE TABLE dbo.p31 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(nvarchar(30), dt, 126) PERSISTED);
-- @step batch
CREATE TABLE dbo.p32 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(nvarchar(30), dt, 101) PERSISTED);
-- @step batch
CREATE TABLE dbo.p33 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(nvarchar(30), dt, 0) PERSISTED);
-- @step batch
CREATE TABLE dbo.p34 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CAST(v AS int) PERSISTED);
-- @step batch
CREATE TABLE dbo.p35 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CAST(i AS sql_variant) PERSISTED);
-- @step batch
CREATE TABLE dbo.p36 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CAST(dt AS sql_variant) PERSISTED);
-- @step batch
CREATE TABLE dbo.p37 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CAST(dt AS date) PERSISTED);
-- @step batch
CREATE TABLE dbo.p38 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CAST(d AS datetime) PERSISTED);
-- @step batch
CREATE TABLE dbo.p39 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CAST(i AS datetime) PERSISTED);
-- @step batch
CREATE TABLE dbo.p40 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CAST(dt AS int) PERSISTED);
-- @step batch
CREATE TABLE dbo.p41 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CAST(s AS int) PERSISTED);
-- @step batch
CREATE TABLE dbo.p42 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CAST(s AS float) PERSISTED);
-- @step batch
CREATE TABLE dbo.p43 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CAST(s AS money) PERSISTED);
-- @step batch
CREATE TABLE dbo.p44 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CAST(s AS decimal(10,2)) PERSISTED);
-- @step batch
CREATE TABLE dbo.p45 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CAST(s AS uniqueidentifier) PERSISTED);
-- @step batch
CREATE TABLE dbo.p46 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CAST(s AS bit) PERSISTED);
-- @step batch
CREATE TABLE dbo.p47 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS TRY_CONVERT(date, s) PERSISTED);
-- @step batch
CREATE TABLE dbo.p48 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS TRY_CONVERT(date, s, 126) PERSISTED);
-- @step batch
CREATE TABLE dbo.p49 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS TRY_CAST(s AS date) PERSISTED);
-- @step batch
CREATE TABLE dbo.p50 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS PARSE(s AS date) PERSISTED);
-- @step batch
CREATE TABLE dbo.p51 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS TRY_PARSE(s AS date) PERSISTED);
-- @step batch
CREATE TABLE dbo.p52 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(date, JSON_VALUE(s, N'$.a')) PERSISTED);
-- @step batch
CREATE TABLE dbo.p53 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(date, JSON_VALUE(s, N'$.a'), 126) PERSISTED);
-- @step batch
CREATE TABLE dbo.p54 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(date, vs) PERSISTED);
-- @step batch
CREATE TABLE dbo.p55 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(date, vs, 126) PERSISTED);
-- @step batch
CREATE TABLE dbo.p56 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CAST(s AS xml) PERSISTED);
-- @step batch
CREATE TABLE dbo.p57 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CAST(N'2020-01-01' AS date) PERSISTED);
-- @step batch
CREATE TABLE dbo.p58 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(date, N'2020-01-01') PERSISTED);
-- @step batch
CREATE TABLE dbo.p59 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS DATEADD(day, 1, s) PERSISTED);
-- @step batch
CREATE TABLE dbo.p60 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS YEAR(s) PERSISTED);
-- @step batch
CREATE TABLE dbo.p61 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS DATEPART(year, s) PERSISTED);
-- @step batch
CREATE TABLE dbo.p62 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS DATEDIFF(day, s, d) PERSISTED);
-- @step batch
CREATE TABLE dbo.p63 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS ISDATE(s) PERSISTED);
-- @step batch
CREATE TABLE dbo.p64 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS FORMAT(d, 'yyyy') PERSISTED);
-- @step batch
CREATE TABLE dbo.p65 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS DATENAME(month, d) PERSISTED);
-- @step batch
CREATE TABLE dbo.p66 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS DATEPART(weekday, d) PERSISTED);
-- @step batch
CREATE TABLE dbo.p67 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS DATEPART(year, d) PERSISTED);
-- @step batch
CREATE TABLE dbo.p68 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CHECKSUM(s) PERSISTED);
-- @step batch
CREATE TABLE dbo.p69 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS BINARY_CHECKSUM(s) PERSISTED);
-- @step batch
CREATE TABLE dbo.p70 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS HASHBYTES('SHA2_256', s) PERSISTED);
-- @step batch
CREATE TABLE dbo.p71 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(datetime2, s, 126) PERSISTED);
-- @step batch
CREATE TABLE dbo.p72 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(datetimeoffset, s, 127) PERSISTED);
-- @step batch
CREATE TABLE dbo.p73 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(time, s, 114) PERSISTED);
-- @step batch
CREATE TABLE dbo.p74 (s nvarchar(100), vs varchar(100), d date, dt datetime, v sql_variant, i int, c AS CONVERT(time, s, 108) PERSISTED);
-- @step batch
CREATE TABLE dbo.p75 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS DATEPART(week, d) PERSISTED);
-- @step batch
CREATE TABLE dbo.p76 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS DATEPART(wk, d) PERSISTED);
-- @step batch
CREATE TABLE dbo.p77 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS DATEPART(dw, d) PERSISTED);
-- @step batch
CREATE TABLE dbo.p78 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS DATEPART(iso_week, d) PERSISTED);
-- @step batch
CREATE TABLE dbo.p79 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS DATEPART(tzoffset, o) PERSISTED);
-- @step batch
CREATE TABLE dbo.p80 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS DATEPART(dayofyear, d) PERSISTED);
-- @step batch
CREATE TABLE dbo.p81 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS DATEDIFF(week, d, d) PERSISTED);
-- @step batch
CREATE TABLE dbo.p82 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS DATETRUNC(week, d) PERSISTED);
-- @step batch
CREATE TABLE dbo.p83 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS DATE_BUCKET(week, 1, d) PERSISTED);
-- @step batch
CREATE TABLE dbo.p84 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS DATEADD(week, 1, d) PERSISTED);
-- @step batch
CREATE TABLE dbo.p85 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS EOMONTH(d) PERSISTED);
-- @step batch
CREATE TABLE dbo.p86 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS DATEFROMPARTS(i,1,1) PERSISTED);
-- @step batch
CREATE TABLE dbo.p87 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS PARSE(s AS int) PERSISTED);
-- @step batch
CREATE TABLE dbo.p88 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS TRY_PARSE(s AS int) PERSISTED);
-- @step batch
CREATE TABLE dbo.p89 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS ISDATE(CONVERT(nvarchar(30), d, 126)) PERSISTED);
-- @step batch
CREATE TABLE dbo.p90 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS ISNUMERIC(s) PERSISTED);
-- @step batch
CREATE TABLE dbo.p91 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS CASE WHEN d > s THEN 1 ELSE 0 END PERSISTED);
-- @step batch
CREATE TABLE dbo.p92 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS CASE WHEN d > '2020-01-01' THEN 1 ELSE 0 END PERSISTED);
-- @step batch
CREATE TABLE dbo.p93 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS CASE WHEN d > CONVERT(date, '2020-01-01', 126) THEN 1 ELSE 0 END PERSISTED);
-- @step batch
CREATE TABLE dbo.p94 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS COALESCE(d, s) PERSISTED);
-- @step batch
CREATE TABLE dbo.p95 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS ISNULL(d, s) PERSISTED);
-- @step batch
CREATE TABLE dbo.p96 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS IIF(i > 0, d, s) PERSISTED);
-- @step batch
CREATE TABLE dbo.p97 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS CONVERT(nvarchar(30), o, 127) PERSISTED);
-- @step batch
CREATE TABLE dbo.p98 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS CAST(o AS nvarchar(40)) PERSISTED);
-- @step batch
CREATE TABLE dbo.p99 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS CAST(t AS nvarchar(20)) PERSISTED);
-- @step batch
CREATE TABLE dbo.p100 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS CAST(d2 AS varchar(30)) PERSISTED);
-- @step batch
CREATE TABLE dbo.p101 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS CONVERT(varchar(30), d2, 121) PERSISTED);
-- @step batch
CREATE TABLE dbo.p102 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS CAST(d AS varbinary(10)) PERSISTED);
-- @step batch
CREATE TABLE dbo.p103 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS CONVERT(date, CAST(s AS varchar(20)), 112) PERSISTED);
-- @step batch
CREATE TABLE dbo.p104 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS CAST(CAST(s AS varchar(10)) AS date) PERSISTED);
-- @step batch
CREATE TABLE dbo.p105 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS UPPER(s) PERSISTED);
-- @step batch
CREATE TABLE dbo.p106 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS LOWER(s) PERSISTED);
-- @step batch
CREATE TABLE dbo.p107 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS CONCAT(s, d) PERSISTED);
-- @step batch
CREATE TABLE dbo.p108 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS s + CAST(d AS nvarchar(30)) PERSISTED);
-- @step batch
CREATE TABLE dbo.p109 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS SWITCHOFFSET(o, '+01:00') PERSISTED);
-- @step batch
CREATE TABLE dbo.p110 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS TODATETIMEOFFSET(d2, '+01:00') PERSISTED);
-- @step batch
CREATE TABLE dbo.p111 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS o AT TIME ZONE 'UTC' PERSISTED);
-- @step batch
CREATE TABLE dbo.p112 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS CAST(f AS nvarchar(30)) PERSISTED);
-- @step batch
CREATE TABLE dbo.p113 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS CAST(s AS real) PERSISTED);
-- @step batch
CREATE TABLE dbo.p114 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS STR(f) PERSISTED);
-- @step batch
CREATE TABLE dbo.p115 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS CAST(m AS nvarchar(30)) PERSISTED);
-- @step batch
CREATE TABLE dbo.p116 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS CAST(i AS nvarchar(30)) PERSISTED);
-- @step batch
CREATE TABLE dbo.p117 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS JSON_VALUE(s, N'$.a') PERSISTED);
-- @step batch
CREATE TABLE dbo.p118 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS JSON_QUERY(s, N'$.a') PERSISTED);
-- @step batch
CREATE TABLE dbo.p119 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS ISJSON(s) PERSISTED);
-- @step batch
CREATE TABLE dbo.p120 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS CHARINDEX(N'a', s) PERSISTED);
-- @step batch
CREATE TABLE dbo.p121 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS SOUNDEX(s) PERSISTED);
-- @step batch
CREATE TABLE dbo.p122 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS NCHAR(i) PERSISTED);
-- @step batch
CREATE TABLE dbo.p123 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS CHAR(i) PERSISTED);
-- @step batch
CREATE TABLE dbo.p124 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS STRING_ESCAPE(s, 'json') PERSISTED);
-- @step batch
CREATE TABLE dbo.p125 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS OBJECT_ID(s) PERSISTED);
-- @step batch
CREATE TABLE dbo.p126 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS DB_NAME() PERSISTED);
-- @step batch
CREATE TABLE dbo.p127 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS USER_ID() PERSISTED);
-- @step batch
CREATE TABLE dbo.p128 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS COMPRESS(s) PERSISTED);
-- @step batch
CREATE TABLE dbo.p129 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS CRYPT_GEN_RANDOM(4) PERSISTED);
-- @step batch
CREATE TABLE dbo.p130 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS @@SPID PERSISTED);
-- @step batch
CREATE TABLE dbo.p131 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS @@DATEFIRST PERSISTED);
-- @step batch
CREATE TABLE dbo.p132 (s nvarchar(100), d date, o datetimeoffset, t time, d2 datetime2, f float, m money, i int, c AS @@LANGUAGE PERSISTED);
-- @step batch
CREATE TABLE dbo.p133 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS OBJECT_NAME(i) PERSISTED);
-- @step batch
CREATE TABLE dbo.p134 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS SCHEMA_NAME() PERSISTED);
-- @step batch
CREATE TABLE dbo.p135 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS SCHEMA_ID() PERSISTED);
-- @step batch
CREATE TABLE dbo.p136 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS DB_ID() PERSISTED);
-- @step batch
CREATE TABLE dbo.p137 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS TYPE_ID('int') PERSISTED);
-- @step batch
CREATE TABLE dbo.p138 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS TYPE_NAME(i) PERSISTED);
-- @step batch
CREATE TABLE dbo.p139 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS COL_NAME(i,i) PERSISTED);
-- @step batch
CREATE TABLE dbo.p140 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS SUSER_ID() PERSISTED);
-- @step batch
CREATE TABLE dbo.p141 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS SUSER_NAME() PERSISTED);
-- @step batch
CREATE TABLE dbo.p142 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS SUSER_SID() PERSISTED);
-- @step batch
CREATE TABLE dbo.p143 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS USER_NAME() PERSISTED);
-- @step batch
CREATE TABLE dbo.p144 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS CURRENT_USER PERSISTED);
-- @step batch
CREATE TABLE dbo.p145 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS SESSION_USER PERSISTED);
-- @step batch
CREATE TABLE dbo.p146 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS SYSTEM_USER PERSISTED);
-- @step batch
CREATE TABLE dbo.p147 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS ORIGINAL_LOGIN() PERSISTED);
-- @step batch
CREATE TABLE dbo.p148 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS HOST_ID() PERSISTED);
-- @step batch
CREATE TABLE dbo.p149 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS IS_MEMBER('x') PERSISTED);
-- @step batch
CREATE TABLE dbo.p150 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS IS_SRVROLEMEMBER('x') PERSISTED);
-- @step batch
CREATE TABLE dbo.p151 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS OBJECTPROPERTY(i,'IsTable') PERSISTED);
-- @step batch
CREATE TABLE dbo.p152 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS COLUMNPROPERTY(i,'c','IsComputed') PERSISTED);
-- @step batch
CREATE TABLE dbo.p153 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS SERVERPROPERTY('Edition') PERSISTED);
-- @step batch
CREATE TABLE dbo.p154 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS DATABASEPROPERTYEX('master','Status') PERSISTED);
-- @step batch
CREATE TABLE dbo.p155 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS CONNECTIONPROPERTY('net_transport') PERSISTED);
-- @step batch
CREATE TABLE dbo.p156 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS DECOMPRESS(b) PERSISTED);
-- @step batch
CREATE TABLE dbo.p157 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS ERROR_NUMBER() PERSISTED);
-- @step batch
CREATE TABLE dbo.p158 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS XACT_STATE() PERSISTED);
-- @step batch
CREATE TABLE dbo.p159 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS SCOPE_IDENTITY() PERSISTED);
-- @step batch
CREATE TABLE dbo.p160 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS IDENT_CURRENT('x') PERSISTED);
-- @step batch
CREATE TABLE dbo.p161 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS @@ROWCOUNT PERSISTED);
-- @step batch
CREATE TABLE dbo.p162 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS @@VERSION PERSISTED);
-- @step batch
CREATE TABLE dbo.p163 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS @@SERVERNAME PERSISTED);
-- @step batch
CREATE TABLE dbo.p164 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS @@TRANCOUNT PERSISTED);
-- @step batch
CREATE TABLE dbo.p165 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS @@DBTS PERSISTED);
-- @step batch
CREATE TABLE dbo.p166 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS CURRENT_TRANSACTION_ID() PERSISTED);
-- @step batch
CREATE TABLE dbo.p167 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS GETANSINULL() PERSISTED);
-- @step batch
CREATE TABLE dbo.p168 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS FORMATMESSAGE('a %s', s) PERSISTED);
-- @step batch
CREATE TABLE dbo.p169 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS RAND(1) PERSISTED);
-- @step batch
CREATE TABLE dbo.p170 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS CHECKSUM(NEWID()) PERSISTED);
-- @step batch
CREATE TABLE dbo.p171 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS DIFFERENCE(s, s) PERSISTED);
-- @step batch
CREATE TABLE dbo.p172 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS QUOTENAME(s) PERSISTED);
-- @step batch
CREATE TABLE dbo.p173 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS REPLICATE(s, 2) PERSISTED);
-- @step batch
CREATE TABLE dbo.p174 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS TRANSLATE(s, 'a', 'b') PERSISTED);
-- @step batch
CREATE TABLE dbo.p175 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS CONCAT_WS(',', s, s) PERSISTED);
-- @step batch
CREATE TABLE dbo.p176 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS GREATEST(i, 1) PERSISTED);
-- @step batch
CREATE TABLE dbo.p177 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS ROUND(f, 1) PERSISTED);
-- @step batch
CREATE TABLE dbo.p178 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS PI() PERSISTED);
-- @step batch
CREATE TABLE dbo.p179 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS LOG(f) PERSISTED);
-- @step batch
CREATE TABLE dbo.p180 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS SIN(f) PERSISTED);
-- @step batch
CREATE TABLE dbo.p181 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS POWER(f, 2) PERSISTED);
-- @step batch
CREATE TABLE dbo.p182 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS ABS(f) PERSISTED);
-- @step batch
CREATE TABLE dbo.p183 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS f * 2 PERSISTED);
-- @step batch
CREATE TABLE dbo.p184 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS CAST(f AS decimal(10,2)) PERSISTED);
-- @step batch
CREATE TABLE dbo.p185 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS CURRENT_TIMEZONE() PERSISTED);
-- @step batch
CREATE TABLE dbo.p186 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS CURRENT_TIMEZONE_ID() PERSISTED);
-- @step batch
CREATE TABLE dbo.p187 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS DATETIME2FROMPARTS(i,1,1,0,0,0,0,0) PERSISTED);
-- @step batch
CREATE TABLE dbo.p188 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS SESSIONPROPERTY('ANSI_NULLS') PERSISTED);
-- @step batch
CREATE TABLE dbo.p189 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS @@OPTIONS PERSISTED);
-- @step batch
CREATE TABLE dbo.p190 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS @@NESTLEVEL PERSISTED);
-- @step batch
CREATE TABLE dbo.p191 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS @@MAX_PRECISION PERSISTED);
-- @step batch
CREATE TABLE dbo.p192 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS COLLATIONPROPERTY('Latin1_General_CI_AS','CodePage') PERSISTED);
-- @step batch
CREATE TABLE dbo.p193 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS IDENT_SEED('x') PERSISTED);
-- @step batch
CREATE TABLE dbo.p194 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS APPLOCK_MODE('public','x','Transaction') PERSISTED);
-- @step batch
CREATE TABLE dbo.p195 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS HASHBYTES('MD5', s) PERSISTED);
-- @step batch
CREATE TABLE dbo.p196 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS CHECKSUM(f) PERSISTED);
-- @step batch
CREATE TABLE dbo.p197 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS LEFT(s, 1) PERSISTED);
-- @step batch
CREATE TABLE dbo.p198 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS FORMAT(i, 'N') PERSISTED);
-- @step batch
CREATE TABLE dbo.p199 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS STR(f, 10, 2) PERSISTED);
-- @step batch
CREATE TABLE dbo.p200 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS TRIM(s) PERSISTED);
-- @step batch
CREATE TABLE dbo.p201 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS REVERSE(s) PERSISTED);
-- @step batch
CREATE TABLE dbo.p202 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS UNICODE(s) PERSISTED);
-- @step batch
CREATE TABLE dbo.p203 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS ASCII(s) PERSISTED);
-- @step batch
CREATE TABLE dbo.p204 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS JSON_MODIFY(s, '$.a', 1) PERSISTED);
-- @step batch
CREATE TABLE dbo.p205 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS JSON_OBJECT('a': i) PERSISTED);
-- @step batch
CREATE TABLE dbo.p206 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS JSON_ARRAY(i) PERSISTED);
-- @step batch
CREATE TABLE dbo.p207 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS SQL_VARIANT_PROPERTY(i, 'BaseType') PERSISTED);
-- @step batch
CREATE TABLE dbo.p208 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS CAST(i AS sql_variant) PERSISTED);
-- @step batch
CREATE TABLE dbo.p209 (s nvarchar(100), b varbinary(100), d date, f float, i int, c AS CONVERT(nvarchar(30), CAST(i AS sql_variant)) PERSISTED);
-- @step batch
CREATE TABLE dbo.np (body nvarchar(max), value AS CONVERT(date, JSON_VALUE(body, N'$.a')));
INSERT dbo.np (body) VALUES (N'{"a":"2020-03-04"}');
SELECT value FROM dbo.np;
-- @step batch
CREATE TABLE dbo.ps (body nvarchar(max), value AS CONVERT(date, JSON_VALUE(body, N'$.a'), 126) PERSISTED);
INSERT dbo.ps (body) VALUES (N'{"a":"2020-03-04"}');
SELECT value FROM dbo.ps;

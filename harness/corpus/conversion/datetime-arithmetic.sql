-- Legacy datetime/smalldatetime arithmetic: + and - with numbers, bit,
-- binary, character data or another legacy datetime add day counts in
-- 1/300 s units (smalldatetime result rounds to the minute); * / are 257,
-- % and the newer date/time types 402; date/time types with numbers are
-- 206 with the temporal type first. CURRENT_DATE is a non-nullable date.
-- Such type errors fail the whole batch before anything runs (also in an
-- IF branch or TRY block, after a missing table); run-time errors do not.
-- @step batch
DECLARE @d datetime = '2020-01-31T12:00:00';
SELECT @d + 1 AS a, @d - 1 AS b, @d + 1.5 AS c, @d - 0.25 AS d, 1 + @d AS e, @d + CAST(2 AS bigint) AS f, @d + CAST(1.5 AS float) AS g, @d + CAST(1 AS money) AS h;
-- @step batch
DECLARE @d datetime = '2020-01-31T12:00:00';
SELECT @d + @d AS a, @d - @d AS b, @d - CAST('2020-01-01' AS datetime) AS c;
-- @step batch
DECLARE @s smalldatetime = '2020-01-31T12:00:00';
SELECT @s + 1 AS a, @s - 0.5 AS b;
-- @step batch
DECLARE @d datetime = '2020-01-31T12:00:00';
SELECT @d + '1900-01-02' AS a;
-- @step batch
SELECT CAST('2020-01-01' AS date) + 1;
-- @step batch
SELECT CAST('2020-01-01' AS datetime2) + 1;
-- @step batch
DECLARE @d datetime = '9999-12-31';
SELECT @d + 1;
-- @step batch
SELECT CAST('2020-01-01' AS datetime) * 2;
-- @step batch
SELECT SQL_VARIANT_PROPERTY(CURRENT_DATE, 'BaseType') AS t, CASE WHEN DATEDIFF(day, CURRENT_DATE, GETDATE()) BETWEEN 0 AND 1 THEN 1 ELSE 0 END AS near, CASE WHEN CURRENT_DATE = CAST(GETDATE() AS date) THEN 1 ELSE 0 END AS same;
-- @step batch
SELECT CURRENT_DATE();
-- @step batch
DECLARE @d datetime = '2020-01-31T12:00:00';
SELECT CAST(@d - 1 AS sql_variant) AS v, SQL_VARIANT_PROPERTY(@d + 1.5, 'BaseType') AS t;
-- @step batch
SELECT CAST('2020-01-01' AS date) + 1;
-- @step batch
SELECT 1 + CAST('2020-01-01' AS date);
-- @step batch
SELECT CAST('2020-01-01' AS date) - 1;
-- @step batch
SELECT 1.5 + CAST('10:00' AS time);
-- @step batch
SELECT CAST('2020-01-01' AS datetimeoffset) + CAST(1 AS bigint);
-- @step batch
SELECT CAST(1 AS int) + CAST('2020-01-01' AS date);
-- @step batch
SELECT CAST('2020-01-01' AS date) + CAST(1 AS int);
-- @step batch
SELECT CAST('2020-01-01' AS datetime) + NEWID();
-- @step batch
SELECT CAST('2020-01-01' AS datetime) + CAST('2020-01-01' AS date);
-- @step batch
SELECT CAST('2020-01-01' AS datetime) - CAST('2020-01-01' AS datetime2);
-- @step batch
DECLARE @d datetime = '2020-01-01', @b bit = 1; SELECT @d + @b AS a;
-- @step batch
DECLARE @d datetime = '2020-01-01', @s smalldatetime = '2020-01-02'; SELECT @d + @s AS a, @s + @d AS b, @s - @s AS c;
-- @step batch
SELECT CAST('2020-01-01' AS datetime) % 2;
-- @step batch
SELECT CAST('2020-01-01' AS datetime) / 2;
-- @step batch
DECLARE @d datetime = '1900-01-01'; SELECT @d - 1 AS a, @d - 53690 AS b, CAST(@d - 53691 AS nvarchar(30)) AS c;
-- @step batch
DECLARE @d datetime = '1900-01-01'; SELECT @d - 53691.5;
-- @step batch
DECLARE @d datetime = '2020-01-01T00:00:00'; SELECT CONVERT(nvarchar(30), @d + 0.0000001, 121) AS a, CONVERT(nvarchar(30), @d + 0.000001, 121) AS b, CONVERT(nvarchar(30), @d + 0.00001, 121) AS c, CONVERT(nvarchar(30), @d + CAST(0.00001 AS float), 121) AS d, CONVERT(nvarchar(30), @d - 0.00001, 121) AS e, CONVERT(nvarchar(30), @d + 1e0/3, 121) AS f;
-- @step batch
DECLARE @s smalldatetime = '2020-01-01T00:00:00'; SELECT CONVERT(nvarchar(30), @s + 0.0003, 121) AS a, CONVERT(nvarchar(30), @s + 0.0004, 121) AS b, CONVERT(nvarchar(30), @s - 0.0004, 121) AS c;
-- @step batch
DECLARE @d datetime = '2020-01-01T10:00:00'; SELECT CONVERT(nvarchar(30), @d + N'12:00', 121) AS a, CONVERT(nvarchar(30), @d - '1900-01-01 06:00', 121) AS b, CONVERT(nvarchar(30), '1900-01-02' + @d, 121) AS c;
-- @step batch
DECLARE @d datetime = '2020-01-01T10:00:00'; SELECT @d + 'abc';
-- @step batch
DECLARE @d datetime = '2020-01-01T10:00:00', @n decimal(38,10) = 1.5, @m money = 2.25, @r real = 0.5; SELECT CONVERT(nvarchar(30), @d + @n, 121) AS a, CONVERT(nvarchar(30), @d - @m, 121) AS b, CONVERT(nvarchar(30), @d + @r, 121) AS c, CONVERT(nvarchar(30), @d + CAST(1 AS tinyint), 121) AS e;
-- @step batch
DECLARE @d datetime = NULL; SELECT @d + 1 AS a, CAST(NULL AS datetime) - NULL AS b;
-- @step batch
DECLARE @d datetime = '2020-01-01'; SELECT @d + NULL AS a, NULL - @d AS b;
-- @step batch
DECLARE @d date = '2020-01-01', @i int = 1; SELECT @i + @d;
-- @step batch
SELECT 1 AS a; IF 1 = 0 SELECT CAST('2020-01-01' AS date) + 1;
-- @step batch
SELECT 1 AS a; BEGIN TRY SELECT CAST('2020-01-01' AS date) + 1 END TRY BEGIN CATCH SELECT 99 END CATCH
-- @step batch
DECLARE @v sql_variant = 1; SELECT 1 AS a; DECLARE @n nvarchar(10) = @v;
-- @step batch
SELECT 1 AS a; SELECT * FROM dbo.missing_table; SELECT CAST('2020-01-01' AS date) + 1;
-- @step batch
SELECT 1 AS a; SELECT CAST('x' AS int);

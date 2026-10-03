-- Built-ins with a sql_variant argument: 8116 (invalid argument type) or
-- 257 (no implicit conversion to the parameter type) per function and
-- argument position, and the functions that take sql_variant.
-- (One oracle probe per function; bind/fn_variant.mbt encodes the table.)
-- @step batch
SELECT LEN(CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT UPPER(CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT LTRIM(CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT TRIM(CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT REVERSE(CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT LEFT(CAST(N'1' AS sql_variant), 1) AS r;
-- @step batch
SELECT LEFT(N'abc', CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT RIGHT(CAST(N'1' AS sql_variant), 1) AS r;
-- @step batch
SELECT SUBSTRING(CAST(N'1' AS sql_variant), 1, 1) AS r;
-- @step batch
SELECT SUBSTRING(N'abc', CAST(N'1' AS sql_variant), 1) AS r;
-- @step batch
SELECT REPLACE(N'abc', CAST(N'1' AS sql_variant), 'b') AS r;
-- @step batch
SELECT REPLICATE(CAST(N'1' AS sql_variant), 2) AS r;
-- @step batch
SELECT REPLICATE(N'a', CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT CHARINDEX(CAST(N'1' AS sql_variant), N'abc') AS r;
-- @step batch
SELECT CHARINDEX('a', CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT CHARINDEX(N'a', CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT PATINDEX('%a%', CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT CONCAT(CAST(N'1' AS sql_variant), 1) AS r;
-- @step batch
SELECT CONCAT(N'a', CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT CONCAT_WS(',', CAST(N'1' AS sql_variant), 1) AS r;
-- @step batch
SELECT SPACE(CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT STR(CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT STR(1.5, CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT NCHAR(CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT ASCII(CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT UNICODE(CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT STUFF(CAST(N'1' AS sql_variant), 1, 1, 'x') AS r;
-- @step batch
SELECT QUOTENAME(CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT SOUNDEX(CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT FORMAT(CAST(N'1' AS sql_variant), 'N2') AS r;
-- @step batch
SELECT TRANSLATE(CAST(N'1' AS sql_variant), 'a', 'b') AS r;
-- @step batch
SELECT STRING_ESCAPE(CAST(N'1' AS sql_variant), 'json') AS r;
-- @step batch
SELECT ABS(CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT CEILING(CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT ROUND(CAST(N'1' AS sql_variant), 0) AS r;
-- @step batch
SELECT ROUND(1.5, CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT POWER(CAST(N'1' AS sql_variant), 2) AS r;
-- @step batch
SELECT SQRT(CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT LOG(CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT SIGN(CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT DATEPART(year, CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT DATENAME(month, CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT YEAR(CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT DAY(CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT EOMONTH(CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT EOMONTH(CAST('2024-01-01' AS date), CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT DATEADD(day, CAST(N'1' AS sql_variant), CAST('2024-01-01' AS date)) AS r;
-- @step batch
SELECT DATEADD(day, 1, CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT DATEDIFF(day, CAST(N'1' AS sql_variant), CAST('2024-01-02' AS date)) AS r;
-- @step batch
SELECT DATETRUNC(day, CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT DATEFROMPARTS(CAST(N'1' AS sql_variant), 1, 1) AS r;
-- @step batch
SELECT ISDATE(CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT ISNUMERIC(CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT HASHBYTES('MD5', CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT JSON_VALUE(CAST(N'1' AS sql_variant), '$.a') AS r;
-- @step batch
SELECT ISJSON(CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT OBJECT_ID(CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT OBJECT_NAME(CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT DB_NAME(CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT SCHEMA_NAME(CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT TYPE_NAME(CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT CHOOSE(CAST(N'1' AS sql_variant), 1, 2) AS r;
-- @step batch
SELECT ISNULL(5, CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT SERVERPROPERTY(CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT DATABASEPROPERTYEX(CAST(N'1' AS sql_variant), 'Status') AS r;
-- @step batch
SELECT SQL_VARIANT_PROPERTY(1, CAST(N'1' AS sql_variant)) AS r;
-- @step batch
SELECT SUM(v) AS r FROM (SELECT CAST(1 AS sql_variant) AS v) AS t;
-- @step batch
SELECT AVG(v) AS r FROM (SELECT CAST(1 AS sql_variant) AS v) AS t;
-- @step batch
SELECT STDEV(v) AS r FROM (SELECT CAST(1 AS sql_variant) AS v) AS t;
-- @step batch
SELECT VARP(v) AS r FROM (SELECT CAST(1 AS sql_variant) AS v) AS t;
-- @step batch
SELECT STRING_AGG(v, ',') AS r FROM (SELECT CAST(1 AS sql_variant) AS v) AS t;
-- @step batch
SELECT STRING_AGG(N'a', v) AS r FROM (SELECT CAST(1 AS sql_variant) AS v) AS t;
-- @step batch
DECLARE @v sql_variant = 1, @n sql_variant = NULL;
SELECT DATALENGTH(@v) AS dl, ISNULL(@n, 5) AS isnull_lit, ISNULL(@v, 2) AS isnull_v, ISNULL(NULL, @v) AS isnull_null,
       COALESCE(@n, N'x', 3) AS coalesce_, NULLIF(@v, 1) AS nullif_eq, NULLIF(@v, 2) AS nullif_ne,
       IIF(1 = 1, @v, 2) AS iif_, CHOOSE(2, 1, @v) AS choose_, GREATEST(@v, 2) AS greatest_, LEAST(@v, 2) AS least_;
SELECT SQL_VARIANT_PROPERTY(COALESCE(NULL, 5.5), 'BaseType') AS bt_coalesce,
       SQL_VARIANT_PROPERTY(ISNULL(@n, 5), 'BaseType') AS bt_isnull,
       SQL_VARIANT_PROPERTY(CASE WHEN 1 = 0 THEN @v ELSE N'x' END, 'BaseType') AS bt_case;
SELECT MIN(v) AS mn, MAX(v) AS mx, COUNT(v) AS c, COUNT_BIG(DISTINCT v) AS cd FROM (SELECT CAST(1 AS sql_variant) AS v
  UNION ALL SELECT CAST(N'z' AS sql_variant) UNION ALL SELECT CAST(2.5e0 AS sql_variant)) AS t;
-- @step batch
SELECT CAST(1 AS sql_variant) AS v UNION ALL SELECT 2 UNION ALL SELECT N'x';
SELECT CASE WHEN 1 = 1 THEN CAST(1 AS sql_variant) ELSE 2 END AS a, CASE WHEN 1 = 0 THEN 1 ELSE CAST(N'x' AS sql_variant) END AS b;

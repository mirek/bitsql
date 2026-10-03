-- sql_variant comparison: values of different type families order by
-- family (date/time > approximate > exact numeric > character > binary >
-- uniqueidentifier), same-family values compare after conversion, strings
-- compare collation properties first. ORDER BY, GROUP BY, DISTINCT,
-- MIN/MAX, IN, BETWEEN.
-- @step setup
CREATE TABLE dbo.o (id int NOT NULL PRIMARY KEY, v sql_variant NULL);
INSERT INTO dbo.o SELECT 1, CAST(1 AS sql_variant) UNION ALL SELECT 2, CAST(2.5e0 AS sql_variant)
  UNION ALL SELECT 3, CAST(N'abc' AS sql_variant) UNION ALL SELECT 4, CAST('abd' AS sql_variant)
  UNION ALL SELECT 5, CAST(0x01 AS sql_variant) UNION ALL SELECT 6, CAST(CAST('2024-01-01' AS date) AS sql_variant)
  UNION ALL SELECT 7, CAST(CAST('6F9619FF-8B86-D011-B42D-00C04FC964FF' AS uniqueidentifier) AS sql_variant)
  UNION ALL SELECT 8, NULL UNION ALL SELECT 9, CAST(1000 AS bigint) UNION ALL SELECT 10, CAST(1.5 AS decimal(5,1))
  UNION ALL SELECT 11, CAST(CAST(3 AS money) AS sql_variant) UNION ALL SELECT 12, CAST(CAST('01:00' AS time) AS sql_variant)
  UNION ALL SELECT 13, CAST(CAST('2024-01-01 00:00:01' AS datetime) AS sql_variant)
  UNION ALL SELECT 14, CAST(CAST(1 AS bit) AS sql_variant) UNION ALL SELECT 15, CAST(CAST(1e0 AS real) AS sql_variant)
  UNION ALL SELECT 16, CAST('ABC' AS sql_variant) UNION ALL SELECT 17, CAST(N'Abc' COLLATE Latin1_General_BIN AS sql_variant)
  UNION ALL SELECT 18, CAST(CAST(0x0100 AS binary(2)) AS sql_variant)
  UNION ALL SELECT 19, CAST(CAST('2023-12-31 23:00 -02:00' AS datetimeoffset(0)) AS sql_variant);
-- @step batch
SELECT id, v FROM dbo.o ORDER BY v, id;
SELECT id, v FROM dbo.o ORDER BY v DESC, id;
SELECT MIN(v) AS mn, MAX(v) AS mx, COUNT(DISTINCT v) AS cd, COUNT(v) AS c FROM dbo.o;
-- @step batch
SELECT CASE WHEN CAST(CAST('2024-01-01' AS date) AS sql_variant) > CAST(CAST('01:00' AS time) AS sql_variant) THEN 1 ELSE 0 END AS a,
 CASE WHEN CAST(1 AS sql_variant) = CAST(1.0 AS sql_variant) THEN 1 ELSE 0 END AS b,
 CASE WHEN CAST(1 AS sql_variant) = CAST(1e0 AS sql_variant) THEN 1 ELSE 0 END AS c,
 CASE WHEN CAST(N'abc' AS sql_variant) = CAST('ABC' AS sql_variant) THEN 1 ELSE 0 END AS d,
 CASE WHEN CAST(N'abc' AS sql_variant) = 'ABC' THEN 1 ELSE 0 END AS e,
 CASE WHEN CAST(N'abc' COLLATE Latin1_General_CS_AS AS sql_variant) = CAST(N'ABC' AS sql_variant) THEN 1 ELSE 0 END AS f,
 CASE WHEN CAST(N'abc' COLLATE Latin1_General_CS_AS AS sql_variant) > CAST(N'ABC' AS sql_variant) THEN 1 ELSE 0 END AS g,
 CASE WHEN CAST(0x01 AS sql_variant) = CAST(CAST(0x01 AS binary(2)) AS sql_variant) THEN 1 ELSE 0 END AS h,
 CASE WHEN CAST(1 AS sql_variant) = N'1' THEN 1 ELSE 0 END AS i,
 CASE WHEN CAST(1 AS sql_variant) IN (1, 2) THEN 1 ELSE 0 END AS j,
 CASE WHEN CAST(NULL AS sql_variant) = CAST(NULL AS sql_variant) THEN 1 ELSE 0 END AS k,
 CASE WHEN CAST('a ' AS sql_variant) = CAST('a' AS sql_variant) THEN 1 ELSE 0 END AS l,
 CASE WHEN CAST(CAST('2024-01-01' AS date) AS sql_variant) = CAST(CAST('2024-01-01' AS datetime) AS sql_variant) THEN 1 ELSE 0 END AS m,
 CASE WHEN CAST(N'a' AS sql_variant) BETWEEN 'a' AND 'b' THEN 1 ELSE 0 END AS n,
 CASE WHEN CAST(CAST(1 AS money) AS sql_variant) = CAST(1 AS sql_variant) THEN 1 ELSE 0 END AS o,
 CASE WHEN CAST(CAST(1.5 AS real) AS sql_variant) = CAST(1.5e0 AS sql_variant) THEN 1 ELSE 0 END AS p,
 CASE WHEN CAST(CAST('2024-01-01 01:00 +01:00' AS datetimeoffset) AS sql_variant) = CAST(CAST('2024-01-01 00:00' AS datetime2) AS sql_variant) THEN 1 ELSE 0 END AS q;
-- @step batch
SELECT v, COUNT(*) AS c FROM (SELECT CAST(1 AS sql_variant) AS v UNION ALL SELECT CAST(CAST(1 AS bigint) AS sql_variant)
  UNION ALL SELECT CAST(1.0 AS sql_variant) UNION ALL SELECT CAST(1e0 AS sql_variant) UNION ALL SELECT CAST(N'A' AS sql_variant)
  UNION ALL SELECT CAST('a' AS sql_variant)) AS t GROUP BY v ORDER BY v;
SELECT DISTINCT v FROM (SELECT CAST(1 AS sql_variant) AS v UNION ALL SELECT CAST(CAST(1 AS bigint) AS sql_variant)) AS t;
SELECT CAST(1 AS sql_variant) AS v UNION SELECT CAST(CAST(1 AS tinyint) AS sql_variant) UNION SELECT CAST(N'x' AS sql_variant) ORDER BY v;

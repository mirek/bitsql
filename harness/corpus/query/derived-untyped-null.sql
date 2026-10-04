-- SQL Server's "NULL constant" (an untyped NULL, reported as int) keeps its
-- assignment compatibility through derived tables, VALUES, CTEs, DISTINCT,
-- TOP, GROUP BY, joins and set operations whose every branch is NULL:
-- INSERT/UPDATE/MERGE into datetimeoffset, uniqueidentifier and xml
-- columns work, UNION with a typed branch takes that type. An explicitly
-- typed NULL (CAST(NULL AS int)), a VALUES column mixing NULL with an int,
-- a view, an inline function, SELECT INTO, a scalar subquery and unary
-- minus over the column are int (206). Expressions over the column stay
-- untyped (NULL + s.o, ISNULL(s.o, NULL), ~s.o) and count as the NULL
-- constant for CASE (8133), COALESCE (4127) and aggregates (8117/8116),
-- but a bare column reference does not. Reported by an external
-- compatibility test (INSERT ... SELECT source.* FROM (VALUES ...)).
-- @step setup
CREATE TABLE items (id int, occurred datetimeoffset, g uniqueidentifier, x xml);
-- @step batch
INSERT items (id, occurred) SELECT source.* FROM (VALUES (1, NULL), (2, NULL)) source (id, occurred);
INSERT items (id, g) SELECT source.* FROM (VALUES (3, NULL), (4, NULL)) source (id, g);
INSERT items (id, x) SELECT source.* FROM (VALUES (5, NULL)) source (id, x);
INSERT items WITH (SERIALIZABLE) (id, occurred)
SELECT source.* FROM (VALUES (6, NULL)) source (id, occurred)
WHERE NOT EXISTS (SELECT 1 FROM items i WITH (SERIALIZABLE) WHERE i.id = source.id);
SELECT COUNT(*) AS n FROM items;
-- @step batch
INSERT items (id, occurred) SELECT s.* FROM (VALUES (1, CAST(NULL AS int))) s (id, o);
-- @step batch
INSERT items (id, occurred) SELECT 1, s.o FROM (VALUES (NULL), (5)) s (o);
-- @step batch
INSERT items (id, occurred) SELECT 1, s.o FROM (VALUES (NULL), (CAST(NULL AS int))) s (o);
-- @step batch
INSERT items (id, occurred) VALUES (7, NULL);
INSERT items (id, occurred) SELECT s.* FROM (VALUES (8, CAST(NULL AS datetimeoffset))) s (id, o);
INSERT items (id, occurred) SELECT s.* FROM (SELECT 9 AS id, NULL AS o) s;
INSERT items (id, occurred) SELECT s.* FROM (SELECT * FROM (SELECT 10 AS id, NULL AS o) s0) s;
WITH c AS (SELECT 11 AS id, NULL AS o) INSERT items (id, occurred) SELECT * FROM c;
INSERT items (id, occurred) SELECT s.* FROM (SELECT 12 AS id, NULL AS o UNION ALL SELECT 13, NULL) s;
INSERT items (id, occurred) SELECT 14, NULL UNION ALL SELECT 15, NULL;
INSERT items (id, occurred) SELECT 16, s.o FROM (SELECT DISTINCT NULL AS o) s;
INSERT items (id, occurred) SELECT 17, s.o FROM (SELECT TOP 1 NULL AS o ORDER BY 1) s;
INSERT items (id, occurred) SELECT 18, s.o FROM (SELECT NULL AS o FROM items GROUP BY id) s WHERE 1 = 0;
INSERT items (id, occurred) SELECT 19, s.o FROM (SELECT 1 AS k) k LEFT JOIN (SELECT NULL AS o) s ON 1 = 1;
INSERT items (id, occurred) SELECT 20, s.o FROM (SELECT NULL AS o EXCEPT SELECT NULL) s;
INSERT items (id, occurred) SELECT 21, s.o FROM (SELECT NULL AS o UNION SELECT NULL) s;
INSERT items (id, occurred) SELECT 22, s.o FROM (SELECT (NULL) AS o) s;
INSERT items (id, occurred) SELECT 23, s.o FROM (SELECT NULL + NULL AS o) s;
INSERT items (id, occurred) SELECT 24, s.o FROM (SELECT ISNULL(NULL, NULL) AS o) s;
INSERT items (id, occurred) SELECT 25, s.p FROM (SELECT ISNULL(s.o, s.o) AS p FROM (SELECT NULL AS o) s) s;
INSERT items (id, occurred) SELECT 26, s.p FROM (SELECT s.o + s.o AS p FROM (SELECT NULL AS o) s) s;
INSERT items (id, occurred) SELECT 27, ~s.o FROM (SELECT NULL AS o) s;
INSERT items (id, occurred) SELECT 28, -NULL;
INSERT items (id, occurred) SELECT 29, ~NULL;
INSERT items (id, occurred) OUTPUT inserted.id SELECT 30, s.o FROM (SELECT NULL AS o) s;
SELECT COUNT(*) AS n FROM items;
-- @step batch
UPDATE items SET occurred = s.o FROM (VALUES (1, NULL)) s (id, o) WHERE items.id = s.id;
MERGE items t USING (VALUES (31, NULL)) s (id, o) ON t.id = s.id
WHEN NOT MATCHED THEN INSERT (id, occurred) VALUES (s.id, s.o)
WHEN MATCHED THEN UPDATE SET occurred = s.o;
DECLARE @d datetimeoffset = SYSDATETIMEOFFSET();
SELECT @d = s.o FROM (SELECT NULL AS o) s;
SELECT @d AS d;
-- @step batch
INSERT items (id, occurred) SELECT 1, s.o FROM (SELECT NULL AS o UNION ALL SELECT 5) s;
-- @step batch
INSERT items (id, occurred) SELECT 1, -s.o FROM (SELECT NULL AS o) s;
-- @step batch
INSERT items (id, occurred) SELECT 1, NULL * 2;
-- @step batch
INSERT items (id, occurred) SELECT 1, (SELECT NULL);
-- @step batch
SELECT * INTO #t FROM (VALUES (1, NULL)) s (id, o);
SELECT name, TYPE_NAME(system_type_id) AS t, max_length, is_nullable
FROM tempdb.sys.columns WHERE object_id = OBJECT_ID('tempdb..#t') ORDER BY column_id;
INSERT items (id, occurred) SELECT * FROM #t;
-- @step setup
CREATE VIEW v_nul AS SELECT 1 AS id, NULL AS o;
-- @step batch
INSERT items (id, occurred) SELECT id, o FROM v_nul;
-- @step setup
CREATE FUNCTION f_nul() RETURNS TABLE AS RETURN SELECT 1 AS id, NULL AS o;
-- @step batch
INSERT items (id, occurred) SELECT id, o FROM f_nul();
-- @step batch
SELECT name, system_type_name, is_nullable
FROM sys.dm_exec_describe_first_result_set(N'SELECT * FROM (VALUES (1, NULL)) s (id, o)', NULL, 0);
-- @step batch
SELECT s.o + N'x' AS a, COALESCE(s.o, N'yy') AS b, ISNULL(s.o, N'zz') AS c,
  CASE WHEN 1 = 1 THEN s.o ELSE N'q' END AS d, CONCAT(NULL, 1) AS e, CONCAT(s.o, 1) AS f,
  CONCAT(s.o, s.o, 'x') AS g, SQL_VARIANT_PROPERTY(ISNULL(s.o, 1.5), 'BaseType') AS h
FROM (SELECT NULL AS o) s;
-- @step batch
SELECT s.o FROM (SELECT NULL AS o) s UNION ALL SELECT N'abc';
-- @step batch
SELECT o FROM (SELECT NULL AS o UNION ALL SELECT NULL) s UNION ALL SELECT N'abc';
-- @step batch
SELECT o FROM (SELECT NULL AS o) s UNION SELECT CAST('2020-01-01' AS date);
-- @step batch
SELECT CAST('2020-01-01' AS date) AS d UNION ALL SELECT o FROM (SELECT NULL AS o) s;
-- @step batch
SELECT * FROM (SELECT NULL AS o) s CROSS APPLY (SELECT s.o + N'x' AS p) a;
-- @step batch
SELECT * FROM (SELECT NULL AS o) s WHERE s.o = N'abc';
-- @step batch
SELECT * FROM (SELECT NULL AS o) s JOIN (SELECT N'a' AS p) p ON s.o = p.p;
-- @step batch
SELECT name, system_type_name FROM sys.dm_exec_describe_first_result_set(
  N'SELECT o FROM (SELECT CAST(NULL AS int) AS o) s UNION ALL SELECT N''abc''
    UNION ALL SELECT o FROM (SELECT NULL AS o) s', NULL, 0);
-- @step batch
SELECT s.o, COUNT(*) AS n FROM (SELECT NULL AS o) s GROUP BY s.o ORDER BY s.o;
-- @step batch
SELECT s.o, COUNT(*) AS n FROM (SELECT NULL AS o, 1 AS k) s GROUP BY s.k;
-- @step batch
SELECT k, o, (o) AS p FROM (SELECT NULL AS o, 1 AS k) s ORDER BY o;
-- @step batch
SELECT TOP 1 s.o, s.k FROM (SELECT NULL AS o, 1 AS k) s ORDER BY s.k DESC;
-- @step batch
SELECT NULL + s.o AS a, ISNULL(s.o, NULL) AS b, -s.o AS c, s.o + s.o AS d,
  CASE WHEN s.k = 1 THEN s.o END AS f, COALESCE(s.o, NULL) AS g
FROM (SELECT NULL AS o, 1 AS k) s;
-- @step batch
SELECT NULL AS a, -NULL AS b, NULL + NULL AS c, ISNULL(NULL, NULL) AS d, NULL * 2 AS e,
  CASE WHEN 1 = 1 THEN CAST(NULL AS int) END AS f;
-- @step batch
SELECT CASE WHEN 1 = 1 THEN NULL ELSE s.o END AS a FROM (SELECT NULL AS o) s;
-- @step batch
SELECT CASE WHEN 1 = 1 THEN (NULL) END;
-- @step batch
SELECT CASE WHEN 1 = 1 THEN NULL + NULL END;
-- @step batch
SELECT CASE WHEN 1 = 1 THEN ISNULL(NULL, NULL) END;
-- @step batch
SELECT CASE WHEN 1 = 1 THEN ISNULL(s.o, NULL) END FROM (SELECT NULL AS o) s;
-- @step batch
SELECT CASE WHEN 1 = 1 THEN NULL + s.o END FROM (SELECT NULL AS o) s;
-- @step batch
SELECT COALESCE(NULL, NULL);
-- @step batch
SELECT COALESCE(NULL, ISNULL(s.o, NULL)) FROM (SELECT NULL AS o) s;
-- @step batch
SELECT IIF(1 = 1, NULL, NULL);
-- @step batch
SELECT MAX(NULL);
-- @step batch
SELECT MIN(s.o) FROM (SELECT NULL AS o) s;
-- @step batch
SELECT COUNT(s.o) FROM (SELECT NULL AS o) s;
-- @step batch
SELECT SUM(s.o) FROM (SELECT NULL AS o) s;
-- @step batch
SELECT STRING_AGG(NULL, ',');
-- @step batch
SELECT id, CONVERT(nvarchar(40), occurred, 127) AS occurred, g, CAST(x AS nvarchar(10)) AS x
FROM items ORDER BY id;

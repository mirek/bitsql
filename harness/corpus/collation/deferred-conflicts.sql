-- Collation precedence with "no collation" values: two different implicit
-- collations meeting in +, CONCAT, CASE, COALESCE, IIF or UNION ALL give a
-- value without a collation. A result column of it is 451 (naming the
-- operator and column), a collation-sensitive operation on it is 4191, a
-- direct implicit clash in a sensitive operation is 468. ISNULL takes its
-- first argument's collation; INSERT ... SELECT accepts no-collation values.
-- @step setup
CREATE TABLE c (id int, a nvarchar(10) COLLATE Latin1_General_100_CI_AS, b nvarchar(10) COLLATE Latin1_General_100_CS_AS, x nvarchar(10) COLLATE Latin1_General_100_BIN2);
INSERT INTO c VALUES (1, N'a', N'A', N'a');
-- @step batch
SELECT a + b AS s FROM c;
-- @step batch
SELECT id, a + b AS s FROM c;
-- @step batch
SELECT CONCAT(a, b) AS s FROM c;
-- @step batch
SELECT COALESCE(a, b) AS s FROM c;
-- @step batch
SELECT IIF(id = 1, a, b) AS s FROM c;
-- @step batch
SELECT ISNULL(a, b) AS s FROM c;
-- @step batch
SELECT CAST(a + b AS nvarchar(20)) AS s FROM c;
-- @step batch
SELECT s FROM (SELECT CASE WHEN id = 1 THEN a ELSE b END AS s FROM c) q;
-- @step batch
SELECT s FROM (SELECT a AS s FROM c UNION ALL SELECT b FROM c) q;
-- @step batch
SELECT (SELECT a + b FROM c) AS s;
-- @step batch
SELECT 1 AS n FROM c WHERE a + b = N'x';
-- @step batch
SELECT 1 AS n FROM c WHERE (a + b) = x;
-- @step batch
SELECT 1 AS n FROM c WHERE CASE WHEN id = 1 THEN a ELSE b END LIKE N'x';
-- @step batch
SELECT 1 AS n FROM c WHERE CASE WHEN id = 1 THEN a ELSE b END IN (N'x', N'y');
-- @step batch
SELECT LEN(a + b) AS n FROM c;
-- @step batch
SELECT UPPER(a + b) AS n FROM c;
-- @step batch
SELECT LEFT(CASE WHEN id = 1 THEN a ELSE b END, 1) AS n FROM c;
-- @step batch
SELECT MAX(CASE WHEN id = 1 THEN a ELSE b END) AS m FROM c;
-- @step batch
SELECT (a + b) COLLATE Latin1_General_100_BIN2 AS s FROM c;
-- @step batch
SELECT a FROM c INTERSECT SELECT b FROM c;
-- @step batch
SELECT a FROM c EXCEPT SELECT b FROM c;
-- @step batch
SELECT a FROM c UNION ALL SELECT N'x' COLLATE Latin1_General_100_BIN2 FROM c;
-- @step batch
SELECT a FROM c UNION SELECT N'x' FROM c;
-- @step batch
SELECT x.s FROM (SELECT a AS s FROM c) x JOIN (SELECT b AS s FROM c) y ON x.s = y.s;
-- @step batch
SELECT CASE WHEN q.v = c.a THEN 1 ELSE 0 END AS n FROM (SELECT N'a' COLLATE Latin1_General_100_BIN2 AS v) q CROSS JOIN c;
-- @step batch
INSERT INTO c (id, a) SELECT 2, a + b FROM c;
SELECT id, a FROM c ORDER BY id;

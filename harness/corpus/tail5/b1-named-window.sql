-- Named windows: SELECT ... WINDOW w AS (...), OVER w, OVER (w ...),
-- references between definitions, scoping and the compile errors
-- 5362/16211/5365/5367/4123/5364/5366 (whole batch). Probed 2026-10-04.
-- @step setup
CREATE TABLE dbo.wt (n int, g int); INSERT INTO dbo.wt VALUES (1,1),(2,1),(3,2)
-- @step batch
SELECT n, ROW_NUMBER() OVER w AS r, SUM(n) OVER w AS s FROM (VALUES (1,1),(2,1),(3,2)) v(n,g) WINDOW w AS (PARTITION BY g ORDER BY n) ORDER BY n
-- @step batch
SELECT n, SUM(n) OVER (w ORDER BY n) AS s FROM (VALUES (1,1),(2,1),(3,2)) v(n,g) WINDOW w AS (PARTITION BY g) ORDER BY n
-- @step batch
SELECT n, SUM(n) OVER w2 AS s FROM (VALUES (1,1),(2,1),(3,2)) v(n,g) WINDOW w1 AS (PARTITION BY g), w2 AS (w1 ORDER BY n DESC) ORDER BY n
-- @step batch
SELECT n, SUM(n) OVER x AS s FROM (VALUES (1,1),(2,1),(3,2)) v(n,g) WINDOW w AS (PARTITION BY g) ORDER BY n
-- @step batch
SELECT n, SUM(n) OVER w AS s FROM (VALUES (1,1),(2,1),(3,2)) v(n,g)
-- @step batch
SELECT n, SUM(n) OVER w AS s FROM (VALUES (1,1),(2,1),(3,2)) v(n,g) WINDOW w AS (PARTITION BY g), w AS (ORDER BY n)
-- @step batch
SELECT n, SUM(n) OVER (w PARTITION BY n) AS s FROM (VALUES (1,1),(2,1),(3,2)) v(n,g) WINDOW w AS (PARTITION BY g)
-- @step batch
SELECT n, SUM(n) OVER (w ORDER BY n) AS s FROM (VALUES (1,1),(2,1),(3,2)) v(n,g) WINDOW w AS (ORDER BY g)
-- @step batch
SELECT n, SUM(n) OVER (w ROWS UNBOUNDED PRECEDING) AS s FROM (VALUES (1,1),(2,1),(3,2)) v(n,g) WINDOW w AS (ORDER BY g, n) ORDER BY n
-- @step batch
SELECT n, SUM(n) OVER (w ORDER BY n) AS s FROM (VALUES (1,1),(2,1),(3,2)) v(n,g) WINDOW w AS (ORDER BY g ROWS UNBOUNDED PRECEDING)
-- @step batch
SELECT n, SUM(n) OVER W AS s FROM (VALUES (1,1),(2,1),(3,2)) v(n,g) WINDOW w AS (ORDER BY n) ORDER BY n
-- @step batch
SELECT n, SUM(n) OVER w1 AS s FROM (VALUES (1,1),(2,1),(3,2)) v(n,g) WINDOW w1 AS (w2), w2 AS (w1)
-- @step batch
SELECT n, SUM(n) OVER w1 AS s FROM (VALUES (1,1),(2,1),(3,2)) v(n,g) WINDOW w1 AS (w2 ORDER BY n), w2 AS (PARTITION BY g) ORDER BY n
-- @step batch
SELECT n FROM (VALUES (1,1),(2,1),(3,2)) v(n,g) WINDOW w AS (ORDER BY n) ORDER BY SUM(n) OVER w DESC
-- @step batch
SELECT n, (SELECT SUM(n) OVER w) AS s FROM (VALUES (1,1),(2,1),(3,2)) v(n,g) WINDOW w AS (ORDER BY n) ORDER BY n
-- @step batch
SELECT g, SUM(SUM(n)) OVER w AS s FROM (VALUES (1,1),(2,1),(3,2)) v(n,g) GROUP BY g HAVING COUNT(*) > 0 WINDOW w AS (ORDER BY g) ORDER BY g
-- @step batch
SELECT n, SUM(n) OVER w AS s FROM (VALUES (1,1),(2,1),(3,2)) v(n,g) WINDOW w AS (ORDER BY n) UNION ALL SELECT 9, 9 ORDER BY n
-- @step batch
SELECT 1 AS window
-- @step batch
SELECT n, SUM(n) OVER [w] AS s FROM (VALUES (1,1)) v(n,g) WINDOW [w] AS (ORDER BY n)
-- @step batch
SELECT n, SUM(n) OVER w AS s FROM (VALUES (1,1)) v(n,g) WINDOW w AS ()
-- @step batch
SELECT n, LAG(n) OVER w AS s FROM (VALUES (1,1),(2,1)) v(n,g) WINDOW w AS (PARTITION BY g) ORDER BY n
-- @step batch
SELECT n, SUM(n) OVER (w) AS s FROM (VALUES (1,1),(2,1)) v(n,g) WINDOW w AS (ORDER BY n) ORDER BY n
-- @step batch
SELECT 1 AS a; SELECT n, SUM(n) OVER x AS s FROM (VALUES (1,1)) v(n,g) WINDOW w AS (ORDER BY n)
-- @step batch
SELECT 1 AS a; SELECT n, SUM(n) OVER w AS s FROM (VALUES (1,1)) v(n,g) WINDOW w AS (ORDER BY n), w AS (ORDER BY n)
-- @step batch
SELECT 1 AS a; SELECT n, SUM(n) OVER (w ORDER BY n) AS s FROM (VALUES (1,1)) v(n,g) WINDOW w AS (ORDER BY n)
-- @step batch
SELECT 1 AS a; SELECT n, LAG(n) OVER w AS s FROM (VALUES (1,1)) v(n,g) WINDOW w AS (PARTITION BY g)
-- @step batch
SELECT n, ROW_NUMBER() OVER w AS s FROM (VALUES (1,1)) v(n,g) WINDOW w AS (PARTITION BY g)
-- @step batch
SELECT n, NTILE(2) OVER w AS s FROM (VALUES (1,1)) v(n,g) WINDOW w AS (PARTITION BY g)
-- @step batch
SELECT n, LEAD(n) OVER w AS s FROM (VALUES (1,1)) v(n,g) WINDOW w AS ()
-- @step batch
SELECT n, SUM(n) OVER (w PARTITION BY n) AS s FROM (VALUES (1,1)) v(n,g) WINDOW w AS (ORDER BY n)
-- @step batch
SELECT n, SUM(n) OVER w2 AS s FROM (VALUES (1,1)) v(n,g) WINDOW w1 AS (ORDER BY g), w2 AS (w1 PARTITION BY n)
-- @step batch
SELECT n, SUM(n) OVER w AS s FROM (VALUES (1,1)) v(n,g) WINDOW w AS (ORDER BY n), z AS (q)
-- @step batch
SELECT 1 AS a; SELECT n, SUM(n) OVER w AS s FROM (VALUES (1,1)) v(n,g) WINDOW w AS (w)
-- @step batch
SELECT n, SUM(n) OVER w AS s FROM (VALUES (1,1)) v(n,g) WINDOW w AS (ORDER BY n), z AS (w ORDER BY g)
-- @step batch
SELECT n, SUM(n) OVER w AS s FROM (VALUES (1,1)) v(n,g) WINDOW w AS (ORDER BY n ROWS UNBOUNDED PRECEDING), z AS (w)
-- @step batch
SELECT n, SUM(n) OVER (w ROWS UNBOUNDED PRECEDING) AS s FROM (VALUES (1,1)) v(n,g) WINDOW w AS (PARTITION BY g)
-- @step batch
SELECT n, SUM(n) OVER w AS s FROM (VALUES (1,1),(2,1)) v(n,g) WINDOW w AS (PARTITION BY g ORDER BY n ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) ORDER BY n
-- @step batch
SELECT n, COUNT(*) OVER w AS c, MAX(n) OVER w AS m FROM (VALUES (1,1),(2,1),(3,1)) v(n,g) WINDOW w AS (ORDER BY n RANGE BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) ORDER BY n
-- @step batch
SELECT n, SUM(n) OVER w AS s FROM (VALUES (1,1)) v(n,g) WHERE n > 0 WINDOW w AS (ORDER BY n) ORDER BY n OPTION (MAXDOP 1)
-- @step batch
WITH c AS (SELECT n, SUM(n) OVER w AS s FROM (VALUES (1,1)) v(n,g) WINDOW w AS (ORDER BY n)) SELECT * FROM c
-- @step batch
SELECT * FROM (SELECT n, SUM(n) OVER w AS s FROM (VALUES (1,1)) v(n,g) WINDOW w AS (ORDER BY n)) d
-- @step batch
SELECT n, SUM(n) OVER w AS s FROM (VALUES (1,1)) v(n,g) WINDOW w AS (ORDER BY n),
-- @step batch
SELECT n, SUM(n) OVER w AS s FROM (VALUES (1,1)) v(n,g) WINDOW w (ORDER BY n)
-- @step batch
SELECT n, SUM(n) OVER w AS s FROM (VALUES (1,1)) v(n,g) WINDOW w AS (ORDER BY n) WHERE n > 0
-- @step batch
SELECT n, SUM(n) OVER w AS s FROM dbo.wt WINDOW w AS (ORDER BY n) ORDER BY n
-- @step batch
SELECT n, SUM(n) OVER w AS s FROM dbo.wt window w AS (ORDER BY n) ORDER BY n
-- @step batch
SELECT window.n FROM dbo.wt window
-- @step batch
SELECT n, RANK() OVER w AS a FROM dbo.wt WINDOW w AS (PARTITION BY g)
-- @step batch
SELECT n, DENSE_RANK() OVER w AS a FROM dbo.wt WINDOW w AS (PARTITION BY g)
-- @step batch
SELECT n, PERCENT_RANK() OVER w AS a FROM dbo.wt WINDOW w AS (PARTITION BY g)
-- @step batch
SELECT n, CUME_DIST() OVER w AS a FROM dbo.wt WINDOW w AS (PARTITION BY g)
-- @step batch
SELECT n, FIRST_VALUE(n) OVER w AS a FROM dbo.wt WINDOW w AS (PARTITION BY g)
-- @step batch
SELECT n, LAST_VALUE(n) OVER w AS a FROM dbo.wt WINDOW w AS (PARTITION BY g)
-- @step batch
SELECT n, ROW_NUMBER() OVER (w PARTITION BY n) AS a FROM dbo.wt WINDOW w AS ()
-- @step batch
SELECT n, ROW_NUMBER() OVER (w ORDER BY n) AS a FROM dbo.wt WINDOW w AS (PARTITION BY g) ORDER BY n
-- @step batch
SELECT n, PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY n) OVER w AS a FROM dbo.wt WINDOW w AS (PARTITION BY g) ORDER BY n
-- @step batch
SELECT n, ROW_NUMBER() OVER (PARTITION BY g) AS a FROM dbo.wt
-- @step batch
SELECT n, SUM(n) OVER (w ROWS UNBOUNDED PRECEDING) AS s FROM dbo.wt WINDOW w AS (ORDER BY n ROWS UNBOUNDED PRECEDING)
-- @step batch
SELECT n, SUM(n) OVER w2 AS s FROM dbo.wt WINDOW w AS (ORDER BY n ROWS UNBOUNDED PRECEDING), w2 AS (w ROWS UNBOUNDED PRECEDING)
-- @step batch
SELECT n, SUM(n) OVER w2 AS s FROM dbo.wt WINDOW w AS (PARTITION BY g), w2 AS (w ROWS UNBOUNDED PRECEDING)
-- @step batch
SELECT n, SUM(n) OVER w AS s FROM dbo.wt WINDOW w AS (PARTITION BY g ROWS UNBOUNDED PRECEDING)
-- @step batch
SELECT n, SUM(n) OVER w AS s FROM dbo.wt WINDOW w AS (ROWS UNBOUNDED PRECEDING)
-- @step batch
SELECT n, SUM(n) OVER w AS s FROM dbo.wt WINDOW w AS (ORDER BY n) UNION SELECT 1, 1 ORDER BY SUM(n) OVER w
-- @step batch
SELECT 1 AS a UNION SELECT n FROM dbo.wt WINDOW w AS (ORDER BY n) ORDER BY 1
-- @step batch
SELECT n, SUM(n) OVER w AS s, SUM(n) OVER v AS t FROM dbo.wt WINDOW w AS (ORDER BY n), v AS (w) ORDER BY n
-- @step batch
SELECT n, SUM(n) OVER w AS s FROM dbo.wt GROUP BY n WINDOW w AS (ORDER BY n) ORDER BY n
-- @step batch
UPDATE dbo.wt SET n = n WHERE n IN (SELECT SUM(n) OVER w FROM dbo.wt WINDOW w AS (ORDER BY n))
-- @step batch
SELECT n, SUM(n) OVER w AS s FROM dbo.wt WINDOW w AS (PARTITION BY g ORDER BY n), WINDOW AS (ORDER BY g) ORDER BY n

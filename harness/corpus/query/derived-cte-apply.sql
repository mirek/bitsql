-- Derived tables, CTEs (incl. recursive and MAXRECURSION), CROSS/OUTER APPLY.
-- @step setup
CREATE TABLE dt (id int NOT NULL, g int NULL, v varchar(5) NULL);
INSERT INTO dt VALUES (1, 1, 'a'), (2, 1, 'b'), (3, 2, NULL);
-- @step batch
SELECT q.id, q.v FROM (SELECT id, v FROM dt WHERE id > 1) AS q ORDER BY q.id;
-- @step batch
SELECT a, b FROM (SELECT id + 1, v FROM dt) q(a, b) ORDER BY a;
-- @step batch
SELECT * FROM (SELECT g, COUNT(*) AS c FROM dt GROUP BY g) q ORDER BY g;
-- @step batch
WITH c AS (SELECT id, v FROM dt) SELECT * FROM c WHERE id < 3 ORDER BY id;
-- @step batch
WITH c (x, y) AS (SELECT id, g FROM dt), d AS (SELECT x FROM c WHERE y = 1) SELECT d.x, c.y FROM d JOIN c ON c.x = d.x ORDER BY d.x;
-- @step batch
WITH r AS (SELECT 1 AS n UNION ALL SELECT n + 1 FROM r WHERE n < 5) SELECT n FROM r;
-- @step batch
WITH r (n, s) AS (SELECT 1, CAST('a' AS varchar(20)) UNION ALL SELECT n + 1, CAST(s + 'b' AS varchar(20)) FROM r WHERE n < 3) SELECT n, s FROM r ORDER BY n;
-- @step batch
WITH r AS (SELECT 1 AS n UNION ALL SELECT n + 1 FROM r) SELECT n FROM r;
-- @step batch
WITH r AS (SELECT 1 AS n UNION ALL SELECT n + 1 FROM r WHERE n < 200) SELECT MAX(n) AS m FROM r OPTION (MAXRECURSION 300);
-- @step batch
WITH r AS (SELECT 1 AS n UNION ALL SELECT n + 1 FROM r WHERE n < 10) SELECT n FROM r OPTION (MAXRECURSION 3);
-- @step batch
SELECT dt.id, x.y FROM dt CROSS APPLY (SELECT dt.id * 10 AS y) x ORDER BY dt.id;
-- @step batch
SELECT a.id, b.id AS bid FROM dt a OUTER APPLY (SELECT TOP 1 id FROM dt i WHERE i.g = a.g AND i.id > a.id ORDER BY id) b ORDER BY a.id;
-- @step batch
SELECT a.id, b.id AS bid FROM dt a CROSS APPLY (SELECT id FROM dt i WHERE i.g = a.g AND i.id > a.id) b ORDER BY a.id;
-- @step batch
SELECT * FROM (VALUES (1, 'x'), (2, NULL)) v(a, b) CROSS JOIN (SELECT 5 AS c) d ORDER BY a;
-- @step batch
SELECT * FROM (SELECT 1 AS a, 2 AS a) q;

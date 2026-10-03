-- UNION / EXCEPT / INTERSECT, ORDER BY over set operations, TOP WITH TIES,
-- TOP PERCENT.
-- @step setup
CREATE TABLE so (id int NOT NULL, v varchar(5) NULL, n int NULL);
INSERT INTO so VALUES (1, 'a', 10), (2, 'b', 20), (3, 'a', 20), (4, NULL, 30), (5, 'A', NULL);
-- @step batch
SELECT v FROM so UNION SELECT 'c' ORDER BY v;
-- @step batch
SELECT v FROM so EXCEPT SELECT 'b' ORDER BY 1;
-- @step batch
SELECT n FROM so INTERSECT SELECT n FROM so WHERE id > 2 ORDER BY n DESC;
-- @step batch
SELECT id, v FROM so WHERE id < 3 UNION ALL SELECT id, v FROM so WHERE id > 3 ORDER BY id DESC;
-- @step batch
SELECT 1 AS a UNION SELECT 2 UNION ALL SELECT 1 ORDER BY a;
-- @step batch
SELECT 1 AS a UNION ALL SELECT 2 EXCEPT SELECT 2;
-- @step batch
SELECT CAST(1 AS smallint) AS x UNION SELECT 2.5;
-- @step batch
SELECT TOP 2 WITH TIES id, n FROM so ORDER BY n;
-- @step batch
SELECT TOP 40 PERCENT id FROM so ORDER BY id;
-- @step batch
SELECT TOP (50) PERCENT id FROM so ORDER BY id DESC;
-- @step batch
SELECT TOP 1 WITH TIES n, COUNT(*) AS c FROM so GROUP BY n ORDER BY COUNT(*) DESC;
-- @step batch
SELECT v FROM so UNION SELECT v FROM so ORDER BY id;
-- @step batch
SELECT id FROM so UNION SELECT id, v FROM so;
-- @step batch
SELECT TOP 2 WITH TIES id FROM so;

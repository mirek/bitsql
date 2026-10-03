-- GROUP BY / HAVING: grouping keys, expressions, NULL groups, HAVING filters,
-- ORDER BY on aggregates, errors for ungrouped columns.
-- @step setup
CREATE TABLE gb (id int NOT NULL, g int NULL, h varchar(5) NULL, n int NULL);
INSERT INTO gb VALUES (1, 1, 'a', 10), (2, 1, 'b', 20), (3, 2, 'a', NULL), (4, NULL, 'b', 5), (5, 2, 'A', 7), (6, NULL, NULL, 1);
-- @step batch
SELECT g, COUNT(*) AS c, SUM(n) AS s FROM gb GROUP BY g ORDER BY g;
-- @step batch
SELECT h, COUNT(*) AS c FROM gb GROUP BY h ORDER BY h;
-- @step batch
SELECT g, h, MAX(n) AS m FROM gb GROUP BY g, h ORDER BY g, h;
-- @step batch
SELECT g % 2 AS parity, COUNT(*) AS c FROM gb GROUP BY g % 2 ORDER BY parity;
-- @step batch
SELECT g, COUNT(*) AS c FROM gb GROUP BY g HAVING COUNT(*) > 1 ORDER BY g;
-- @step batch
SELECT g FROM gb GROUP BY g HAVING SUM(n) > 10 ORDER BY SUM(n) DESC;
-- @step batch
SELECT COUNT(*) AS c FROM gb HAVING COUNT(*) > 100;
-- @step batch
SELECT COUNT(*) AS c FROM gb WHERE id > 100 GROUP BY g;
-- @step batch
SELECT g + 1 AS g1, COUNT(n) AS c FROM gb GROUP BY g ORDER BY 1;
-- @step batch
SELECT gb.g, COUNT(*) AS c FROM gb GROUP BY gb.g ORDER BY gb.g;
-- @step batch
SELECT g, n FROM gb GROUP BY g;
-- @step batch
SELECT g FROM gb GROUP BY g HAVING n > 1;
-- @step batch
SELECT g FROM gb GROUP BY g ORDER BY n;
-- @step batch
SELECT g, COUNT(*) AS c FROM gb GROUP BY g, h HAVING h = 'a' ORDER BY g;
-- @step batch
SELECT COUNT(*) AS c FROM gb GROUP BY ();
-- @step batch
SELECT g, COUNT(*) FROM gb GROUP BY g ORDER BY 2 DESC, 1;
-- @step batch
SELECT DISTINCT COUNT(*) AS c FROM gb GROUP BY g;
-- @step batch
SELECT g FROM gb GROUP BY COUNT(*);
-- @step batch
SELECT g, COUNT(*) AS c FROM gb GROUP BY ROLLUP(g) ORDER BY g;

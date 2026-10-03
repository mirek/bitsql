-- Subqueries: scalar (metadata, 512 on >1 row, empty = NULL), EXISTS,
-- IN / NOT IN with NULLs, ANY/SOME/ALL, correlated references.
-- @step setup
CREATE TABLE sq (id int NOT NULL, g int NULL, v varchar(5) NULL);
INSERT INTO sq VALUES (1, 1, 'a'), (2, 1, 'b'), (3, 2, NULL), (4, NULL, 'd');
CREATE TABLE sr (id int NOT NULL, x int NULL);
INSERT INTO sr VALUES (1, 1), (2, NULL);
-- @step batch
SELECT (SELECT MAX(id) FROM sq) AS mx, (SELECT id FROM sq WHERE id = 99) AS none, (SELECT 1) AS one, (SELECT v FROM sq WHERE id = 1) AS vv;
-- @step batch
SELECT id, (SELECT COUNT(*) FROM sq i WHERE i.g = o.g) AS same_g FROM sq o ORDER BY id;
-- @step batch
SELECT id FROM sq WHERE EXISTS (SELECT 1 FROM sr WHERE sr.id = sq.id) ORDER BY id;
-- @step batch
SELECT id FROM sq WHERE NOT EXISTS (SELECT * FROM sr WHERE sr.id = sq.id) ORDER BY id;
-- @step batch
SELECT id FROM sq WHERE g IN (SELECT x FROM sr) ORDER BY id;
-- @step batch
SELECT id FROM sq WHERE g NOT IN (SELECT x FROM sr) ORDER BY id;
-- @step batch
SELECT id FROM sq WHERE g NOT IN (SELECT x FROM sr WHERE x IS NOT NULL) ORDER BY id;
-- @step batch
SELECT id FROM sq WHERE id > ALL (SELECT x FROM sr WHERE x IS NOT NULL) ORDER BY id;
-- @step batch
SELECT id FROM sq WHERE id > ALL (SELECT x FROM sr) ORDER BY id;
-- @step batch
SELECT id FROM sq WHERE id = ANY (SELECT x FROM sr) ORDER BY id;
-- @step batch
SELECT id FROM sq WHERE id < SOME (SELECT id FROM sq WHERE g = 1) ORDER BY id;
-- @step batch
SELECT id FROM sq WHERE id > ALL (SELECT id FROM sq WHERE id > 100) ORDER BY id;
-- @step batch
SELECT CASE WHEN 1 IN (SELECT x FROM sr) THEN 'y' ELSE 'n' END AS a, CASE WHEN 3 NOT IN (SELECT x FROM sr) THEN 'y' ELSE 'n' END AS b;
-- @step batch
SELECT (SELECT id FROM sq) AS many;
-- @step batch
SELECT id, (SELECT id FROM sr WHERE sr.id >= sq.id) AS r FROM sq ORDER BY id;
-- @step batch
SELECT (SELECT id, g FROM sq) AS two;
-- @step batch
SELECT id FROM sq WHERE id IN (SELECT id, g FROM sq);
-- @step batch
SELECT id FROM sq o WHERE g = (SELECT MAX(g) FROM sq i WHERE i.id < o.id) ORDER BY id;
-- @step batch
SELECT id FROM sq WHERE EXISTS (SELECT 1 FROM sr WHERE sr.x = sq.g AND EXISTS (SELECT 1 FROM sq s2 WHERE s2.id = sr.id AND s2.v = sq.v));

-- Correlated subqueries on an integer key `inner.col = outer.col`, the
-- shapes exec/decorrelate.mbt unnests into a key partition: NULL keys on
-- either side, mixed integer types, empty buckets (COUNT 0, MAX NULL),
-- repeated outer keys, residual conjuncts, a second outer column, a
-- variable, TOP/ORDER BY, DISTINCT and GROUP BY inside, IN, 512 for a
-- bucket of more than one row, warning 8153, and UPDATE reading the
-- table it writes.
-- @step setup
CREATE TABLE up (id int NOT NULL PRIMARY KEY, grp smallint NULL, lim int NULL, big bigint NULL);
INSERT INTO up VALUES (1, 1, 0, 1), (2, 2, 5, 2), (3, 1, 2, NULL), (4, NULL, 1, 4), (5, 3, NULL, 5), (6, 2, 1, 6), (7, 4, 0, 99);
CREATE TABLE uc (id int NOT NULL PRIMARY KEY, pid int NULL, tid tinyint NULL, v int NULL);
INSERT INTO uc VALUES (10, 1, 1, 3), (11, 1, 1, NULL), (12, 2, 2, 7), (13, NULL, NULL, 1), (14, 4, 4, 2), (15, 2, 2, 7), (16, 6, 6, NULL), (17, 1, 1, 5);
-- @step batch
SELECT id FROM up WHERE EXISTS (SELECT 1 FROM uc WHERE uc.pid = up.id) ORDER BY id;
SELECT id FROM up WHERE NOT EXISTS (SELECT * FROM uc WHERE uc.pid = up.grp) ORDER BY id;
SELECT id FROM up WHERE EXISTS (SELECT 1 FROM uc WHERE uc.tid = up.big) ORDER BY id;
SELECT id FROM up WHERE EXISTS (SELECT 1 FROM uc WHERE up.grp = uc.tid AND uc.v > 4) ORDER BY id;
-- @step batch
SELECT id, (SELECT COUNT(*) FROM uc WHERE uc.pid = up.grp) AS n, (SELECT MAX(v) FROM uc WHERE uc.pid = up.grp) AS mx FROM up ORDER BY id;
-- @step batch
SELECT id, (SELECT SUM(v) FROM uc WHERE uc.pid = up.id) AS s FROM up ORDER BY id;
-- @step batch
SELECT id, (SELECT COUNT(*) FROM uc WHERE uc.pid = up.grp AND uc.v > up.lim) AS n FROM up ORDER BY id;
-- @step batch
DECLARE @k int = 2;
SELECT id, (SELECT COUNT(*) FROM uc WHERE uc.pid = up.id AND uc.v > @k) AS n FROM up ORDER BY id;
SET @k = 6;
SELECT id, (SELECT COUNT(*) FROM uc WHERE uc.pid = up.id AND uc.v > @k) AS n FROM up ORDER BY id;
-- @step batch
SELECT id, (SELECT TOP 1 v FROM uc WHERE uc.pid = up.id ORDER BY v DESC) AS top_v,
  (SELECT TOP 1 uc.id FROM uc WHERE uc.pid = up.id ORDER BY v, uc.id DESC) AS first_id FROM up ORDER BY id;
-- @step batch
SELECT id, (SELECT COUNT(*) FROM (SELECT DISTINCT v FROM uc WHERE uc.pid = up.id) d) AS nd,
  (SELECT MAX(n) FROM (SELECT COUNT(*) AS n FROM uc WHERE uc.pid = up.id GROUP BY v) g) AS mg FROM up ORDER BY id;
-- @step batch
SELECT id FROM up WHERE lim IN (SELECT v FROM uc WHERE uc.pid = up.id) ORDER BY id;
SELECT id FROM up WHERE lim NOT IN (SELECT v FROM uc WHERE uc.pid = up.id) ORDER BY id;
-- @step batch
SELECT id, (SELECT v FROM uc WHERE uc.pid = up.id) AS v FROM up WHERE id IN (3, 4, 5, 6) ORDER BY id;
-- @step batch
SELECT COUNT(*) AS n FROM up WHERE (SELECT v FROM uc WHERE uc.pid = up.id) > 0;
-- @step batch
UPDATE uc SET v = (SELECT COUNT(*) FROM uc c2 WHERE c2.pid = uc.pid) WHERE pid IS NOT NULL;
SELECT id, v FROM uc ORDER BY id;

-- INSERT/UPDATE/DELETE through a view over one base table: the view's
-- WHERE restricts UPDATE/DELETE, view column names (aliases) are used,
-- INSERT fills other base columns with their defaults, OUTPUT images have
-- the view's columns (computed ones evaluated, without fComputed).
-- @step setup
CREATE TABLE vt(id int NOT NULL PRIMARY KEY, n int NULL, t nvarchar(10) NOT NULL CONSTRAINT df_vt_t DEFAULT N'dflt', z int NULL);
INSERT INTO vt VALUES(1,10,N'a',NULL),(2,20,N'b',NULL),(3,30,N'c',NULL);
-- @step setup
CREATE VIEW v1 AS SELECT id AS k, n AS v, n*2 AS dbl FROM vt WHERE id < 3;
-- @step setup
CREATE VIEW v_all AS SELECT * FROM vt;
-- @step batch
UPDATE v1 SET v = v + 1;
SELECT id, n, t, z FROM vt ORDER BY id
-- @step batch
UPDATE v1 SET v = 0 OUTPUT inserted.*, deleted.v WHERE k = 2
-- @step batch
UPDATE v1 SET dbl = 5
-- @step batch
UPDATE dbo.v1 SET v = 7 OUTPUT deleted.k, inserted.dbl WHERE dbl > 0 AND k = 1
-- @step batch
UPDATE x SET v = 8 OUTPUT inserted.k FROM v1 x JOIN (VALUES(1)) s(id) ON x.k = s.id
-- @step batch
UPDATE v1 SET v = s.d OUTPUT inserted.k, s.d FROM v1 JOIN (VALUES(2,99)) s(id,d) ON v1.k = s.id
-- @step batch
INSERT INTO v1(k, v) VALUES(4, 40);
SELECT id, n, t, z FROM vt ORDER BY id
-- @step batch
INSERT INTO v1(k, v) OUTPUT inserted.* VALUES(5, 50)
-- @step batch
INSERT INTO v1 VALUES(6, 60, 120)
-- @step batch
INSERT INTO v1(k, dbl) VALUES(6, 60)
-- @step batch
DELETE v1 OUTPUT deleted.* WHERE k = 1;
SELECT id, n, t, z FROM vt ORDER BY id
-- @step batch
DELETE FROM v1 OUTPUT deleted.k WHERE k > 3
-- @step batch
UPDATE v_all SET z = id OUTPUT inserted.* WHERE id = 3
-- @step batch
INSERT INTO v_all(id, n) OUTPUT inserted.* VALUES(7, 70)
-- @step batch
DELETE v_all WHERE id > 3;
SELECT id, n, t, z FROM vt ORDER BY id

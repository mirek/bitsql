-- Views over joins and non-updatable views: a modification must affect a
-- single base table (4405); setting a derived column is 4406; aggregate,
-- DISTINCT and GROUP BY views are 4403.
-- @step setup
CREATE TABLE va (id int NOT NULL PRIMARY KEY, x int NOT NULL);
CREATE TABLE vb (id int NOT NULL PRIMARY KEY, y int NOT NULL CONSTRAINT df_vb_y DEFAULT 5);
INSERT INTO va VALUES (1, 10), (2, 20); INSERT INTO vb VALUES (1, 100), (2, 200);
-- @step setup
CREATE VIEW v_join AS SELECT va.id, va.x, vb.y, vb.id AS bid FROM va JOIN vb ON va.id = vb.id;
-- @step setup
CREATE VIEW v_agg AS SELECT COUNT(*) AS c, SUM(x) AS s FROM va;
-- @step setup
CREATE VIEW v_grp AS SELECT x, COUNT(*) AS c FROM va GROUP BY x;
-- @step setup
CREATE VIEW v_dist AS SELECT DISTINCT x FROM va;
-- @step batch
UPDATE v_join SET x = 11 OUTPUT deleted.x, inserted.x, inserted.y WHERE id = 1;
SELECT id, x FROM va ORDER BY id
-- @step batch
UPDATE v_join SET y = 101 WHERE bid = 1;
SELECT id, y FROM vb ORDER BY id
-- @step batch
UPDATE v_join SET x = 12, y = 102 WHERE id = 1
-- @step batch
DELETE v_join WHERE id = 1
-- @step batch
INSERT INTO v_join (id, x) VALUES (3, 30);
SELECT id, x FROM va ORDER BY id
-- @step batch
INSERT INTO v_join (bid, y) VALUES (3, 300);
SELECT id, y FROM vb ORDER BY id
-- @step batch
INSERT INTO v_join (id, x, y) VALUES (4, 40, 400)
-- @step batch
INSERT INTO v_join VALUES (4, 40, 400, 4)
-- @step batch
UPDATE v_agg SET s = 0
-- @step batch
UPDATE v_grp SET x = 0
-- @step batch
UPDATE v_grp SET c = 0
-- @step batch
UPDATE v_dist SET x = 0
-- @step batch
DELETE v_dist
-- @step batch
DELETE v_agg
-- @step batch
INSERT INTO v_dist VALUES (5)
-- @step batch
SELECT id, x FROM va ORDER BY id; SELECT id, y FROM vb ORDER BY id

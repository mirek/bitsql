-- Trap: updatable-view rules are strict (multi-base updates, aggregates).
-- @step setup
CREATE TABLE va (id int NOT NULL PRIMARY KEY, x int NOT NULL);
CREATE TABLE vb (id int NOT NULL PRIMARY KEY, y int NOT NULL);
INSERT INTO va VALUES (1, 10); INSERT INTO vb VALUES (1, 100);
-- @step setup
CREATE VIEW v_join AS SELECT va.id, va.x, vb.y FROM va JOIN vb ON va.id = vb.id;
-- @step setup
CREATE VIEW v_agg AS SELECT COUNT(*) AS c, SUM(x) AS s FROM va;
-- @step batch
UPDATE v_join SET x = 11 WHERE id = 1;
SELECT x FROM va;
-- @step batch
UPDATE v_join SET x = 12, y = 101 WHERE id = 1;
-- @step batch
UPDATE v_agg SET s = 0;
-- @step batch
INSERT INTO v_join (id, x, y) VALUES (2, 20, 200);

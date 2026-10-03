-- Nested views and WITH CHECK OPTION: DML through a view over a view
-- reaches the base table with both WHEREs; rows leaving a CHECK OPTION
-- view (or a view stacked on one) fail with 550.
-- @step setup
CREATE TABLE vc(id int NOT NULL PRIMARY KEY, n int NULL);
INSERT INTO vc VALUES(1,10),(2,20),(3,30),(4,40);
-- @step setup
CREATE VIEW v_in AS SELECT id, n FROM vc WHERE id > 1;
-- @step setup
CREATE VIEW v_out AS SELECT id AS k, n AS m FROM v_in WHERE n < 40;
-- @step setup
CREATE VIEW v_chk AS SELECT id, n FROM vc WHERE n < 100 WITH CHECK OPTION;
-- @step setup
CREATE VIEW v_over_chk AS SELECT id, n FROM v_chk WHERE id < 10;
-- @step batch
UPDATE v_out SET m = m + 1 OUTPUT deleted.k, inserted.m;
SELECT id, n FROM vc ORDER BY id
-- @step batch
DELETE v_out OUTPUT deleted.* WHERE k = 2;
SELECT id, n FROM vc ORDER BY id
-- @step batch
INSERT INTO v_out(k, m) OUTPUT inserted.* VALUES(5, 50);
SELECT id, n FROM vc ORDER BY id
-- @step batch
UPDATE v_chk SET n = 150 WHERE id = 1
-- @step batch
UPDATE v_chk SET n = 15 OUTPUT inserted.n WHERE id = 1
-- @step batch
INSERT INTO v_chk VALUES(6, 600)
-- @step batch
INSERT INTO v_chk(id, n) OUTPUT inserted.id VALUES(7, 70), (8, 800)
-- @step batch
UPDATE v_over_chk SET n = 500 WHERE id = 3
-- @step batch
INSERT INTO v_over_chk VALUES(9, 900)
-- @step batch
BEGIN TRY UPDATE v_chk SET n = 150 WHERE id = 1; END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS e, ERROR_STATE() AS s; END CATCH
-- @step batch
SELECT id, n FROM vc ORDER BY id

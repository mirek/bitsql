-- More DML through views and CTEs: aliases inside the view, stars over a
-- join view in OUTPUT (404), INSERT through a CTE, derived tables over a
-- join, duplicate keys through a view, AFTER triggers of the base table.
-- @step setup
CREATE TABLE va (id int NOT NULL CONSTRAINT pk_va PRIMARY KEY, x int NOT NULL);
CREATE TABLE vb (id int NOT NULL CONSTRAINT pk_vb PRIMARY KEY, y int NOT NULL);
CREATE TABLE vlog (msg nvarchar(40) NOT NULL);
CREATE TABLE vlog3 (a int NULL, b int NULL, c int NULL);
INSERT INTO va VALUES (1, 10), (2, 20); INSERT INTO vb VALUES (1, 100), (2, 200);
-- @step setup
CREATE VIEW v_alias AS SELECT a.id AS k, a.x FROM dbo.va AS a WHERE a.id < 10;
-- @step setup
CREATE VIEW v_join AS SELECT va.id, va.x, vb.y FROM va JOIN vb ON va.id = vb.id;
-- @step setup
CREATE TRIGGER tr_va ON va AFTER UPDATE AS INSERT INTO vlog SELECT N'upd ' + CAST(id AS nvarchar(10)) FROM inserted;
-- @step batch
UPDATE v_alias SET x = x + 1 OUTPUT inserted.k INTO vlog(msg) WHERE k = 1;
SELECT id, x FROM va ORDER BY id; SELECT msg FROM vlog ORDER BY msg
-- @step batch
UPDATE v_join SET x = 5 OUTPUT inserted.* INTO vlog3 WHERE id = 1
-- @step batch
UPDATE v_join SET x = 5 OUTPUT deleted.id, deleted.x INTO vlog(msg) WHERE id = 1
-- @step batch
UPDATE v_alias SET k = 2 WHERE k = 1
-- @step batch
INSERT INTO v_alias VALUES (2, 1)
-- @step batch
WITH c AS (SELECT id, x FROM va) INSERT INTO c(id, x) VALUES (3, 30);
SELECT id, x FROM va ORDER BY id
-- @step batch
WITH c AS (SELECT id AS k, x * 2 AS dx FROM va) INSERT INTO c(k, dx) VALUES (4, 40)
-- @step batch
DELETE d FROM (SELECT va.id, vb.y FROM va JOIN vb ON va.id = vb.id) d WHERE d.id = 1
-- @step batch
UPDATE d SET y = 7 FROM (SELECT va.id, vb.y FROM va JOIN vb ON va.id = vb.id) d WHERE d.id = 2;
SELECT id, y FROM vb ORDER BY id
-- @step batch
SELECT id, x FROM va ORDER BY id; SELECT msg FROM vlog ORDER BY msg

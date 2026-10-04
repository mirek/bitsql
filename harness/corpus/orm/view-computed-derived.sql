-- Column flags of computed columns read through a derived table, CTE or
-- APPLY: a view's (or catalog view's) computed column reads as a base
-- column (9), a table's computed column keeps fComputed (33), an
-- expression is 1. Sequelize's describeTable reads
-- INFORMATION_SCHEMA.TABLE_CONSTRAINTS.CONSTRAINT_TYPE through a derived table.
-- @step setup
CREATE TABLE t (id int NOT NULL PRIMARY KEY, c AS id * 2);
-- @step setup
CREATE VIEW vv AS SELECT id, id + 1 AS x, c FROM t;
-- @step batch
SELECT x, c FROM vv;
SELECT d.x, d.c FROM (SELECT x, c FROM vv) d;
WITH w AS (SELECT x FROM vv) SELECT x FROM w;
SELECT d.c FROM (SELECT c FROM t) d;
SELECT d.y FROM (SELECT id + 1 AS y FROM t) d;
SELECT d.CONSTRAINT_TYPE FROM (SELECT CONSTRAINT_TYPE FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS) d;
WITH w AS (SELECT CONSTRAINT_TYPE FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS) SELECT CONSTRAINT_TYPE FROM w;
SELECT a.x FROM t CROSS APPLY (SELECT x FROM vv WHERE vv.id = t.id) a;
SELECT x FROM vv ORDER BY id;
SELECT d.x FROM (SELECT TOP 5 x FROM vv ORDER BY id) d;
SELECT x FROM vv UNION ALL SELECT x FROM vv;

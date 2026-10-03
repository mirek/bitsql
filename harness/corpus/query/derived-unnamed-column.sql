-- A derived table column without a name: SQL Server reports 8155 and then
-- keeps binding, so the outer reference also fails with 207 (two errors).
-- @step setup
CREATE TABLE dt (id int NOT NULL);
-- @step batch
SELECT id FROM (SELECT id + 1 FROM dt) q;
-- @step batch
SELECT x FROM (SELECT id + 1 FROM dt) q;

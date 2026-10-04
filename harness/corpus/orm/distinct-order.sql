-- SELECT DISTINCT without ORDER BY comes out of a sort on the select list
-- (small inputs); plain catalog reads come in object_id order. TypeORM
-- builds its schema-diff queries in the order these rows arrive.
-- @step setup
CREATE TABLE zeta (id int NOT NULL PRIMARY KEY, a_id int NULL);
CREATE TABLE alpha (id int NOT NULL PRIMARY KEY);
CREATE TABLE mid (id int NOT NULL PRIMARY KEY);
-- @step batch
DECLARE @before int = OBJECT_ID('zeta');
ALTER TABLE zeta ADD CONSTRAINT fk_z FOREIGN KEY (a_id) REFERENCES alpha (id);
SELECT CASE WHEN OBJECT_ID('zeta') = @before THEN 'same' ELSE 'changed' END AS id_after_alter;
SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE';
SELECT DISTINCT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE';
SELECT name FROM sys.tables;
SELECT name FROM sys.objects WHERE type = 'U';
SELECT DISTINCT name FROM sys.tables;

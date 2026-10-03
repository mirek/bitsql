-- Missing sequences, invalid contexts, duplicates, DROP.
-- @step setup
CREATE SEQUENCE dbo.s START WITH 1;
CREATE TABLE t (id int);
-- @step batch
SELECT NEXT VALUE FOR dbo.nope AS a;
-- @step batch
SELECT (SELECT NEXT VALUE FOR dbo.s) AS a;
-- @step batch
SELECT DISTINCT NEXT VALUE FOR dbo.s AS a FROM t;
-- @step batch
CREATE SEQUENCE dbo.s;
-- @step batch
CREATE SEQUENCE dbo.bad AS varchar(10);
-- @step batch
CREATE SEQUENCE dbo.bad2 START WITH 10 MAXVALUE 5;
-- @step batch
DROP SEQUENCE dbo.s;
SELECT OBJECT_ID('dbo.s') AS gone;
-- @step batch
DROP SEQUENCE dbo.s;

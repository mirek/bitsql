-- sp_rename for columns and tables: caution message, return status, and
-- errors raised inside the procedure.
-- @step setup
CREATE TABLE dbo.a (id int NOT NULL, x int NULL);
CREATE TABLE dbo.r (id int NOT NULL);
-- @step batch
EXEC sp_rename 'dbo.a.x', 'xx', 'COLUMN';
SELECT name FROM sys.columns WHERE object_id = OBJECT_ID('dbo.a') ORDER BY column_id;
-- @step batch
DECLARE @rc int;
EXEC @rc = sp_rename 'a', 'b';
SELECT @rc AS rc, OBJECT_ID('a') AS old_id, CASE WHEN OBJECT_ID('b') IS NULL THEN 0 ELSE 1 END AS renamed;
-- @step batch
EXEC sp_rename 'b.nosuch', 'y', 'COLUMN';
-- @step batch
EXEC sp_rename 'nosuch', 'y';
-- @step batch
EXEC sp_rename 'b', 'r';
-- @step batch
DECLARE @rc int;
EXEC @rc = sp_rename 'nosuch', 'y';
SELECT @rc AS rc;

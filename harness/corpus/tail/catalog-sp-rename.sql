-- sp_rename beyond the msduck gaps-catalog captures: duplicate index
-- names, schema-bound dependencies (15336 for columns and tables), objtype
-- spelling, TRY behaviour, @@ERROR afterwards, brackets in the new name.
-- @step setup
CREATE TABLE dbo.rp(id INT CONSTRAINT PK_rp PRIMARY KEY, a INT, b INT, c INT);
CREATE INDEX IX_rp_a ON dbo.rp(a);
CREATE INDEX IX_rp_b ON dbo.rp(b);
CREATE TABLE dbo.rc(id INT, p INT CONSTRAINT FK_rc_rp REFERENCES dbo.rp(id));
-- @step batch
EXEC sp_rename 'dbo.rp.IX_rp_a', 'IX_rp_b', 'INDEX'
-- @step batch
EXEC sp_rename 'dbo.rp.IX_rp_a', 'PK_rp', 'INDEX'
-- @step batch
EXEC sp_rename NULL, NULL
-- @step batch
EXEC sp_rename 'dbo.rp', 'x', 'bogus'
-- @step batch
EXEC sp_rename 'dbo.FK_rc_rp', 'PK_rp'
-- @step batch
BEGIN TRY EXEC sp_rename 'dbo.rp.nope', 'x', 'COLUMN' END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS number, ERROR_PROCEDURE() AS proc_name, ERROR_LINE() AS line, ERROR_SEVERITY() AS severity, @@ERROR AS error END CATCH
-- @step batch
EXEC sp_rename 'dbo.rp.nope', 'x', 'column'; SELECT @@ERROR AS error
-- @step batch
EXEC sp_rename 'dbo.rp.IX_rp_a', 'IX_new', 'index'
-- @step batch
EXEC sp_rename '[dbo].[rp].[a]', '[x]', 'COLUMN'
-- @step batch
EXEC sp_rename 'dbo.FK_rc_rp', 'FK_new'
-- @step batch
SELECT name, type FROM sys.objects WHERE parent_object_id IN (OBJECT_ID('dbo.rp'), OBJECT_ID('dbo.rc')) ORDER BY name;
SELECT name FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.rp') ORDER BY index_id;
SELECT name FROM sys.columns WHERE object_id = OBJECT_ID('dbo.rp') ORDER BY column_id
-- @step batch
CREATE VIEW dbo.vsb WITH SCHEMABINDING AS SELECT c FROM dbo.rp
-- @step batch
EXEC sp_rename 'dbo.rp.c', 'c2', 'COLUMN'
-- @step batch
EXEC sp_rename 'dbo.rp.b', 'b2', 'COLUMN'
-- @step batch
EXEC sp_rename 'dbo.rp', 'rp2', 'Object'
-- @step batch
EXEC sp_rename 'dbo.vsb', 'vsb2'
-- @step batch
SELECT name FROM sys.columns WHERE object_id = OBJECT_ID('dbo.rp') ORDER BY column_id;
SELECT name FROM sys.views WHERE name LIKE 'vsb%'

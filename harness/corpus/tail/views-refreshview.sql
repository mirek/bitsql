-- sp_refreshview: the internal completions and transaction of a successful
-- refresh (autocommit, inside a transaction, under NOCOUNT), 15165 for a
-- name that is not a view, and the procedure argument errors.
-- @step setup
CREATE TABLE dbo.b(id int, v int);
-- @step setup
CREATE VIEW dbo.bv AS SELECT MIN(v) AS result FROM dbo.b
-- @step batch
DECLARE @r int; EXEC @r = sp_refreshview N'dbo.bv'; SELECT @r, @@ERROR, @@TRANCOUNT
-- @step batch
EXEC sp_refreshview 'bv'
-- @step batch
EXEC sys.sp_refreshview @viewname = N'dbo.bv'
-- @step batch
BEGIN TRAN; EXEC sp_refreshview 'bv'; COMMIT
-- @step batch
EXEC sp_refreshview N'dbo.missing'
-- @step batch
DECLARE @r int; EXEC @r = sp_refreshview N'dbo.b'; SELECT @r, @@ERROR
-- @step batch
EXEC sp_refreshview NULL
-- @step batch
EXEC sp_refreshview 1
-- @step batch
EXEC sp_refreshview
-- @step batch
EXEC sp_refreshview N'bv', 2
-- @step batch
EXEC sp_refreshview @name = N'bv'
-- @step batch
SET NOCOUNT ON; EXEC sp_refreshview 'bv'; EXEC sp_refreshview 'nope'; SET NOCOUNT OFF
-- @step rpc
EXEC sp_refreshview N'dbo.bv'
-- @step proc sp_refreshview
-- @param @viewname nvarchar(100) = "dbo.bv"

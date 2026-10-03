-- Nesting levels: a procedure and an EXEC string run one level down,
-- sp_executesql text two (the system procedure and its batch), also over
-- RPC and for sp_prepexec. SET options set in an EXEC string or
-- sp_executesql revert when it ends. A batch of only comments completes
-- with DONE CurCmd 253.
-- @step batch
-- only a comment
-- @step setup
CREATE PROCEDURE p_lvl AS BEGIN SELECT @@NESTLEVEL AS proc_lvl; EXEC ('SELECT @@NESTLEVEL AS dyn_lvl'); EXEC sp_executesql N'SELECT @@NESTLEVEL AS sql_lvl'; END
-- @step batch
EXEC p_lvl
-- @step batch
EXEC ('SELECT @@NESTLEVEL AS a'); EXEC sp_executesql N'SELECT @@NESTLEVEL AS b'
-- @step rpc
SELECT @@NESTLEVEL AS rpc_lvl
-- @step proc p_lvl
-- @step proc sp_prepexec
-- @param @handle int output
-- @param @params nvarchar(max) = null
-- @param @stmt nvarchar(max) = "SELECT @@NESTLEVEL AS lvl"
-- @step batch
EXEC ('SET NOCOUNT ON'); SELECT 1 AS a;
EXEC sp_executesql N'SET NOCOUNT ON'; SELECT 2 AS b;
-- @step rpc
SET NOCOUNT ON; SELECT 3 AS c
-- @step batch
SELECT 4 AS d

-- Completion tokens of a procedure called from a procedure, from
-- sp_executesql text (RPC) and from a batch.
-- @step setup
CREATE PROCEDURE dbo.inner_p AS SELECT 1 AS a;
-- @step setup
CREATE PROCEDURE dbo.outer_p AS BEGIN EXEC dbo.inner_p; RETURN 5; END
-- @step batch
EXEC dbo.outer_p;
-- @step rpc
EXEC dbo.inner_p;
-- @step batch
DECLARE @r int; EXEC @r = dbo.outer_p; SELECT @r AS r;

-- XACT_ABORT: the error comes before the rollback ENVCHANGE, in a batch, in
-- an RPC and inside a procedure; a DML statement aborted this way completes
-- with DONE 253. Lines of errors inside a procedure count from the start of
-- the batch that created it, comment lines included.
-- @step setup
CREATE TABLE t (id int CONSTRAINT pk_t PRIMARY KEY);
-- @step setup
-- leading comment line 1
-- leading comment line 2
CREATE PROCEDURE p_lines
AS
BEGIN
  SELECT 1 AS one;

  RAISERROR('line', 16, 1);
END
-- @step batch
SET XACT_ABORT ON; BEGIN TRAN; SELECT 1/0 AS z
-- @step batch
SELECT @@TRANCOUNT AS tc
-- @step batch
SET XACT_ABORT ON; BEGIN TRAN; INSERT t VALUES (1); INSERT t VALUES (1)
-- @step batch
SELECT @@TRANCOUNT AS tc; SET XACT_ABORT OFF
-- @step rpc
SET XACT_ABORT ON; BEGIN TRAN; SELECT 1/0 AS z
-- @step batch
SELECT @@TRANCOUNT AS tc; SET XACT_ABORT OFF
-- @step batch
EXEC p_lines
-- @step batch
BEGIN TRY EXEC p_lines END TRY BEGIN CATCH SELECT ERROR_LINE() AS l, ERROR_PROCEDURE() AS p END CATCH

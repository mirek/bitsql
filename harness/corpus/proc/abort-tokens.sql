-- Errors that end a module. A batch-aborting error inside a procedure
-- (conversion 245, THROW, XACT_ABORT) sends no completion of its own and no
-- DONEPROC: the batch ends with one DONE carrying the failed statement's
-- CurCmd (an RPC with DONEPROC). A compile-time error (208) ends only the
-- procedure: DONEPROC/DONEINPROC 224 with the error bit, no RETURNSTATUS,
-- and the caller continues. 266 follows RETURNSTATUS of a procedure but
-- precedes it for sp_executesql.
-- @step setup
CREATE TABLE t (id int CONSTRAINT pk_t PRIMARY KEY);
-- @step setup
CREATE PROCEDURE p_conv AS BEGIN SELECT 'a' AS a; SELECT CAST('x' AS int) AS c; SELECT 'b' AS b; END
-- @step setup
CREATE PROCEDURE p_div AS BEGIN SELECT 1/0 AS x; SELECT 2 AS y END
-- @step setup
CREATE PROCEDURE p_dup AS BEGIN INSERT t VALUES (1); INSERT t VALUES (1); SELECT 'after' AS a END
-- @step setup
CREATE PROCEDURE p_missing AS BEGIN SELECT 'first' AS f; SELECT * FROM no_such_table; SELECT 'after' AS after END
-- @step setup
CREATE PROCEDURE p_outer_missing AS BEGIN EXEC p_missing; SELECT 'outer after' AS a END
-- @step setup
CREATE PROCEDURE p_tran AS BEGIN TRANSACTION
-- @step setup
CREATE PROCEDURE p_tran_outer AS BEGIN EXEC p_tran; SELECT @@TRANCOUNT AS tc; END
-- @step batch
DECLARE @r int = 99;
EXEC @r = p_conv; SELECT @r AS r;
-- @step batch
SELECT 'next batch' AS n;
-- @step proc p_conv
-- @step batch
SET XACT_ABORT ON; BEGIN TRAN; EXEC p_div; SELECT 'never' AS n
-- @step batch
SELECT @@TRANCOUNT AS tc; SET XACT_ABORT OFF
-- @step batch
SET XACT_ABORT ON; BEGIN TRAN; EXEC p_dup; SELECT 'never' AS n
-- @step batch
SELECT @@TRANCOUNT AS tc; SET XACT_ABORT OFF
-- @step batch
DECLARE @r int = 99; EXEC @r = p_missing; SELECT @r AS r, @@ERROR AS e
-- @step batch
DECLARE @r int = 99; EXEC @r = p_outer_missing; SELECT @r AS r, @@ERROR AS e
-- @step proc p_missing
-- @step batch
DECLARE @r int = 4; EXEC @r = p_tran_outer; SELECT @r AS r, @@TRANCOUNT AS tc; IF @@TRANCOUNT > 0 ROLLBACK
-- @step rpc
BEGIN TRAN
-- @step batch
SELECT @@TRANCOUNT AS tc; IF @@TRANCOUNT > 0 ROLLBACK

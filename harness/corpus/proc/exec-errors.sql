-- Errors of an EXEC itself, and errors inside modules, caught by a TRY of
-- the caller: the module completes with DONEPROC 224 (no error bit) before
-- CATCH. ERROR_PROCEDURE() is the called procedure for argument errors and
-- 266, NULL for 2812 and for dynamic SQL; ERROR_LINE() is 0 for argument
-- errors. Uncaught, 201 and 2812 leave EXEC @r's variable unchanged.
-- @step setup
CREATE PROCEDURE p_in @a int AS SELECT @a AS a
-- @step setup
CREATE PROCEDURE p_tran AS BEGIN TRANSACTION
-- @step setup
CREATE PROCEDURE p_missing AS BEGIN SELECT 'first' AS f; SELECT * FROM no_such_table; SELECT 'after' AS after END
-- @step setup
CREATE PROCEDURE p_outer_try AS BEGIN BEGIN TRY EXEC p_missing; SELECT 'not' AS n END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS num, ERROR_PROCEDURE() AS p, ERROR_LINE() AS l END CATCH END
-- @step setup
CREATE PROCEDURE p_dynerr AS BEGIN BEGIN TRY EXEC ('SELECT 1/0 AS z') END TRY BEGIN CATCH SELECT ERROR_PROCEDURE() AS p, ERROR_LINE() AS l END CATCH; BEGIN TRY EXEC sp_executesql N'SELECT 1/0 AS z' END TRY BEGIN CATCH SELECT ERROR_PROCEDURE() AS p2 END CATCH END
-- @step setup
CREATE PROCEDURE p_conv AS BEGIN SELECT 'a' AS a; SELECT CAST('x' AS int) AS c; SELECT 'b' AS b; END
-- @step batch
BEGIN TRY EXEC no_such_proc END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS n, ERROR_PROCEDURE() AS p, ERROR_LINE() AS l END CATCH
-- @step batch
BEGIN TRY EXEC p_in END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS n, ERROR_PROCEDURE() AS p, ERROR_LINE() AS l END CATCH
-- @step batch
BEGIN TRY EXEC p_in 'abc' END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS n, ERROR_PROCEDURE() AS p, ERROR_LINE() AS l END CATCH
-- @step batch
BEGIN TRY EXEC ('SELECT FROM WHERE') END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS n, ERROR_PROCEDURE() AS p END CATCH
-- @step batch
BEGIN TRY EXEC sp_executesql N'SELECT * FROM no_such_table' END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS n, ERROR_PROCEDURE() AS p END CATCH
-- @step batch
BEGIN TRY EXEC p_tran END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS n, ERROR_PROCEDURE() AS p, @@TRANCOUNT AS tc END CATCH; IF @@TRANCOUNT > 0 ROLLBACK
-- @step batch
BEGIN TRY EXEC p_conv END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS num, ERROR_PROCEDURE() AS p END CATCH
-- @step batch
DECLARE @r int = 7; EXEC @r = p_outer_try; SELECT @r AS r
-- @step batch
EXEC p_dynerr
-- @step batch
DECLARE @r int = 5; EXEC @r = p_in; SELECT @r AS r, @@ERROR AS e
-- @step batch
DECLARE @r int = 5; EXEC @r = no_such_proc; SELECT @r AS r, @@ERROR AS e

-- Return status of a procedure that ends without RETURN <value>: 10 minus
-- the highest severity (> 10) of the errors its own statements raised,
-- caught or not; errors of nested modules (EXEC string, called procedures)
-- do not count. RETURN NULL is INFO 282 and status 0. EXEC (string) gets a
-- status like a procedure.
-- @step setup
CREATE TABLE t (id int CONSTRAINT pk_t PRIMARY KEY, v int NOT NULL);
-- @step setup
CREATE PROCEDURE s10 AS RAISERROR('x', 10, 1);
-- @step setup
CREATE PROCEDURE s11 AS RAISERROR('x', 11, 1);
-- @step setup
CREATE PROCEDURE s12 AS RAISERROR('x', 12, 1);
-- @step setup
CREATE PROCEDURE s13 AS RAISERROR('x', 13, 1);
-- @step setup
CREATE PROCEDURE s14 AS RAISERROR('x', 14, 1);
-- @step setup
CREATE PROCEDURE s15 AS RAISERROR('x', 15, 1);
-- @step setup
CREATE PROCEDURE s17 AS RAISERROR('x', 17, 1);
-- @step setup
CREATE PROCEDURE s18 AS RAISERROR('x', 18, 1);
-- @step setup
CREATE PROCEDURE s11_16 AS BEGIN RAISERROR('x', 11, 1); RAISERROR('y', 16, 1); END
-- @step setup
CREATE PROCEDURE s14_11 AS BEGIN RAISERROR('x', 14, 1); RAISERROR('y', 11, 1); END
-- @step setup
CREATE PROCEDURE s16_ret AS BEGIN RAISERROR('x', 16, 1); RETURN; END
-- @step setup
CREATE PROCEDURE s16_ret5 AS BEGIN RAISERROR('x', 16, 1); RETURN 5; END
-- @step setup
CREATE PROCEDURE s_null AS INSERT t (id, v) VALUES (1, NULL);
-- @step setup
CREATE PROCEDURE s_dyn AS BEGIN EXEC ('RAISERROR(''d'', 16, 1)'); SELECT 1 AS one; END
-- @step setup
CREATE PROCEDURE s_seterr AS RAISERROR('x', 5, 1) WITH SETERROR;
-- @step setup
CREATE PROCEDURE s_overflow AS BEGIN DECLARE @i int; SET @i = 1/0; SELECT 1 AS one; END
-- @step setup
CREATE PROCEDURE s_caught AS BEGIN BEGIN TRY SELECT 1/0 AS z END TRY BEGIN CATCH SELECT ERROR_PROCEDURE() AS p END CATCH END
-- @step setup
CREATE PROCEDURE s_missing_callee AS BEGIN EXEC no_such_proc; SELECT 'after' AS a; END
-- @step setup
CREATE PROCEDURE s_retnull AS RETURN NULL
-- @step batch
DECLARE @r int;
EXEC @r = s10; SELECT @r AS s10;
EXEC @r = s11; SELECT @r AS s11;
EXEC @r = s12; SELECT @r AS s12;
EXEC @r = s13; SELECT @r AS s13;
EXEC @r = s14; SELECT @r AS s14;
EXEC @r = s15; SELECT @r AS s15;
EXEC @r = s17; SELECT @r AS s17;
EXEC @r = s18; SELECT @r AS s18;
-- @step batch
DECLARE @r int;
EXEC @r = s11_16; SELECT @r AS s11_16;
EXEC @r = s14_11; SELECT @r AS s14_11;
EXEC @r = s16_ret; SELECT @r AS s16_ret;
EXEC @r = s16_ret5; SELECT @r AS s16_ret5;
EXEC @r = s_null; SELECT @r AS s_null;
EXEC @r = s_dyn; SELECT @r AS s_dyn;
EXEC @r = s_seterr; SELECT @r AS s_seterr, @@ERROR AS e;
EXEC @r = s_overflow; SELECT @r AS s_overflow;
EXEC @r = s_caught; SELECT @r AS s_caught;
EXEC @r = s_missing_callee; SELECT @r AS s_missing_callee, @@ERROR AS e;
EXEC @r = s_retnull; SELECT @r AS s_retnull;
-- @step batch
INSERT t VALUES (1, 1); EXEC ('INSERT t VALUES (1, 1)'); SELECT @@ERROR AS e
-- @step proc s16_ret
-- @step proc s_retnull

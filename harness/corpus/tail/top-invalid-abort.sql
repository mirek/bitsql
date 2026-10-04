-- Run-time TOP errors (1014, 127, 1031; class 15) end the batch without
-- rolling back; TRY catches them.
-- @step setup
CREATE TABLE tp(id int); INSERT INTO tp VALUES (1),(2),(3);
-- @step batch
DECLARE @n INT = NULL; SELECT TOP (@n) id FROM tp ORDER BY id; SELECT 2 AS after_it
-- @step batch
DECLARE @n INT = -1; SELECT TOP (@n) id FROM tp ORDER BY id; SELECT 2 AS after_it
-- @step batch
DECLARE @p FLOAT = 101; SELECT TOP (@p) PERCENT id FROM tp ORDER BY id; SELECT 2 AS after_it
-- @step batch
BEGIN TRY DECLARE @n INT = NULL; SELECT TOP (@n) id FROM tp ORDER BY id; END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS n END CATCH
-- @step batch
BEGIN TRAN; DECLARE @n INT = -1; SELECT TOP (@n) id FROM tp ORDER BY id; SELECT @@TRANCOUNT AS tc
-- @step batch
SELECT @@TRANCOUNT AS tc; IF @@TRANCOUNT > 0 ROLLBACK
-- @step batch
DECLARE @n INT = -1; UPDATE TOP (@n) tp SET id = id; SELECT 2 AS after_it
-- @step batch
DECLARE @n INT = NULL; DELETE TOP (@n) FROM tp; SELECT 2 AS after_it

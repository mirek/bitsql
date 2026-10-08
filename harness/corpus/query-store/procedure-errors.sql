-- Return variables, ERROR_* values and continuation inside TRY/CATCH.
-- @step batch
DECLARE @r int = -10;
EXEC @r = sys.sp_query_store_flush_db;
SELECT @r AS return_status, @@ERROR AS last_error;
-- @step batch
DECLARE @r int = -10;
EXEC @r = sys.sp_query_store_remove_query 987654321;
SELECT @r AS return_status, @@ERROR AS last_error;
-- @step batch
DECLARE @r int = -10;
BEGIN TRY
  EXEC @r = sys.sp_query_store_remove_query 987654321;
END TRY
BEGIN CATCH
  SELECT ERROR_NUMBER() AS error_number, ERROR_STATE() AS error_state,
         ERROR_SEVERITY() AS error_severity, ERROR_PROCEDURE() AS error_procedure,
         ERROR_LINE() AS error_line, @r AS return_status;
END CATCH;
SELECT 1 AS continued;
-- @step batch
BEGIN TRY
  EXEC sys.sp_query_store_remove_query;
END TRY
BEGIN CATCH
  SELECT ERROR_NUMBER() AS error_number, ERROR_STATE() AS error_state,
         ERROR_SEVERITY() AS error_severity, ERROR_PROCEDURE() AS error_procedure,
         ERROR_LINE() AS error_line;
END CATCH;
SELECT 1 AS continued;
-- @step batch
EXEC sys.sp_query_store_force_plan @plan_id = 91, @query_id = 92;
-- @step batch
EXEC sys.sp_query_store_remove_plan N'1';
-- @step batch
EXEC sys.sp_query_store_remove_plan 1.0;
-- @step batch
EXEC sys.sp_query_store_set_hints 987654321, 1;
-- @step batch
EXEC sys.sp_query_store_clear_hints 987654321, NULL;

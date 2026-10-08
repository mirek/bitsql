-- Query Store procedure completions and nonexistent-ID errors (on).
-- @step setup
ALTER DATABASE CURRENT SET QUERY_STORE = ON;
-- @step batch
EXEC sys.sp_query_store_flush_db ;
-- @step batch
-- @mask errors/0/message
EXEC sys.sp_query_store_reset_exec_stats @plan_id = 987654321;
-- @step batch
EXEC sys.sp_query_store_force_plan @query_id = 987654321, @plan_id = 987654321;
-- @step batch
EXEC sys.sp_query_store_unforce_plan @query_id = 987654321, @plan_id = 987654321;
-- @step batch
EXEC sys.sp_query_store_remove_plan @plan_id = 987654321;
-- @step batch
EXEC sys.sp_query_store_remove_query @query_id = 987654321;
-- @step batch
EXEC sys.sp_query_store_clear_message_queues ;
-- @step batch
EXEC sys.sp_query_store_consistency_check ;
-- @step batch
EXEC sys.sp_query_store_set_hints @query_id = 987654321, @query_hints = N'OPTION (MAXDOP 1)';
-- @step batch
EXEC sys.sp_query_store_clear_hints @query_id = 987654321;
-- @step batch
EXEC sys.sp_query_store_remove_plan_feedback @plan_id = 987654321;

-- Query Store native procedure argument arity, types and positional binding.
-- @step batch
EXEC sys.sp_query_store_flush_db ;
-- @step batch
EXEC sys.sp_query_store_flush_db NULL;
-- @step batch
EXEC sys.sp_query_store_flush_db N'wrong';
-- @step batch
EXEC sys.sp_query_store_flush_db @unknown = 1;
-- @step batch
EXEC sys.sp_query_store_flush_db 1, 2, 3, 4;
-- @step batch
EXEC sys.sp_query_store_clear_message_queues ;
-- @step batch
EXEC sys.sp_query_store_clear_message_queues NULL;
-- @step batch
EXEC sys.sp_query_store_clear_message_queues N'wrong';
-- @step batch
EXEC sys.sp_query_store_clear_message_queues @unknown = 1;
-- @step batch
EXEC sys.sp_query_store_clear_message_queues 1, 2, 3, 4;
-- @step batch
EXEC sys.sp_query_store_consistency_check ;
-- @step batch
EXEC sys.sp_query_store_consistency_check NULL;
-- @step batch
EXEC sys.sp_query_store_consistency_check N'wrong';
-- @step batch
EXEC sys.sp_query_store_consistency_check @unknown = 1;
-- @step batch
EXEC sys.sp_query_store_consistency_check 1, 2, 3, 4;
-- @step batch
EXEC sys.sp_query_store_reset_exec_stats ;
-- @step batch
EXEC sys.sp_query_store_reset_exec_stats NULL;
-- @step batch
EXEC sys.sp_query_store_reset_exec_stats N'wrong';
-- @step batch
-- @mask errors/0/message
EXEC sys.sp_query_store_reset_exec_stats @unknown = 1;
-- @step batch
EXEC sys.sp_query_store_reset_exec_stats 1, 2, 3, 4;
-- @step batch
EXEC sys.sp_query_store_force_plan ;
-- @step batch
EXEC sys.sp_query_store_force_plan NULL;
-- @step batch
EXEC sys.sp_query_store_force_plan N'wrong';
-- @step batch
EXEC sys.sp_query_store_force_plan @unknown = 1;
-- @step batch
EXEC sys.sp_query_store_force_plan 1, 2, 3, 4;
-- @step batch
EXEC sys.sp_query_store_unforce_plan ;
-- @step batch
EXEC sys.sp_query_store_unforce_plan NULL;
-- @step batch
EXEC sys.sp_query_store_unforce_plan N'wrong';
-- @step batch
EXEC sys.sp_query_store_unforce_plan @unknown = 1;
-- @step batch
EXEC sys.sp_query_store_unforce_plan 1, 2, 3, 4;
-- @step batch
EXEC sys.sp_query_store_remove_plan ;
-- @step batch
EXEC sys.sp_query_store_remove_plan NULL;
-- @step batch
EXEC sys.sp_query_store_remove_plan N'wrong';
-- @step batch
EXEC sys.sp_query_store_remove_plan @unknown = 1;
-- @step batch
EXEC sys.sp_query_store_remove_plan 1, 2, 3, 4;
-- @step batch
EXEC sys.sp_query_store_remove_query ;
-- @step batch
EXEC sys.sp_query_store_remove_query NULL;
-- @step batch
EXEC sys.sp_query_store_remove_query N'wrong';
-- @step batch
EXEC sys.sp_query_store_remove_query @unknown = 1;
-- @step batch
EXEC sys.sp_query_store_remove_query 1, 2, 3, 4;
-- @step batch
EXEC sys.sp_query_store_set_hints ;
-- @step batch
EXEC sys.sp_query_store_set_hints NULL;
-- @step batch
EXEC sys.sp_query_store_set_hints N'wrong';
-- @step batch
EXEC sys.sp_query_store_set_hints @unknown = 1;
-- @step batch
EXEC sys.sp_query_store_set_hints 1, 2, 3, 4;
-- @step batch
EXEC sys.sp_query_store_clear_hints ;
-- @step batch
EXEC sys.sp_query_store_clear_hints NULL;
-- @step batch
EXEC sys.sp_query_store_clear_hints N'wrong';
-- @step batch
EXEC sys.sp_query_store_clear_hints @unknown = 1;
-- @step batch
EXEC sys.sp_query_store_clear_hints 1, 2, 3, 4;
-- @step batch
EXEC sys.sp_query_store_remove_plan_feedback ;
-- @step batch
EXEC sys.sp_query_store_remove_plan_feedback NULL;
-- @step batch
EXEC sys.sp_query_store_remove_plan_feedback N'wrong';
-- @step batch
EXEC sys.sp_query_store_remove_plan_feedback @unknown = 1;
-- @step batch
EXEC sys.sp_query_store_remove_plan_feedback 1, 2, 3, 4;

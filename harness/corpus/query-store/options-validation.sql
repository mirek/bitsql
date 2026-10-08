-- Invalid Query Store options and transaction behavior, followed by reuse.
-- @step batch
ALTER DATABASE CURRENT SET QUERY_STORE = ON (INTERVAL_LENGTH_MINUTES = 7);
-- @step batch
ALTER DATABASE CURRENT SET QUERY_STORE = ON (DATA_FLUSH_INTERVAL_SECONDS = 0);
-- @step batch
ALTER DATABASE CURRENT SET QUERY_STORE = ON (MAX_STORAGE_SIZE_MB = 0);
-- @step batch
ALTER DATABASE CURRENT SET QUERY_STORE = ON (MAX_PLANS_PER_QUERY = 0);
-- @step batch
ALTER DATABASE CURRENT SET QUERY_STORE = ON (QUERY_CAPTURE_MODE = CUSTOM, QUERY_CAPTURE_POLICY = (STALE_CAPTURE_POLICY_THRESHOLD = 2 HOURS, EXECUTION_COUNT = 5, TOTAL_COMPILE_CPU_TIME_MS = 20, TOTAL_EXECUTION_CPU_TIME_MS = 30));
SELECT query_capture_mode, query_capture_mode_desc, capture_policy_execution_count, capture_policy_total_compile_cpu_time_ms, capture_policy_total_execution_cpu_time_ms, capture_policy_stale_threshold_hours FROM sys.database_query_store_options;
-- @step batch
BEGIN TRANSACTION;
ALTER DATABASE CURRENT SET QUERY_STORE = OFF;
ROLLBACK TRANSACTION;
-- @step batch
ALTER DATABASE CURRENT SET QUERY_STORE (OPERATION_MODE = INVALID);
-- @step batch
ALTER DATABASE CURRENT SET QUERY_STORE (UNKNOWN_SETTING = 10);

-- Report workload and stable relational/statistical invariants.
-- @step setup
ALTER DATABASE CURRENT SET QUERY_STORE = ON (OPERATION_MODE=READ_WRITE,INTERVAL_LENGTH_MINUTES=1,QUERY_CAPTURE_MODE=ALL);
-- @step batch
SELECT actual_state_desc FROM sys.database_query_store_options;
-- @step setup
SELECT N'probe' AS compatibility_marker, COUNT_BIG(*) AS total FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b;
EXEC sys.sp_query_store_flush_db;
-- @step batch
SELECT qt.query_sql_text,rs.count_executions,
CASE WHEN rs.avg_duration>0 THEN 1 ELSE 0 END AS positive_duration,
CASE WHEN rs.first_execution_time<=rs.last_execution_time THEN 1 ELSE 0 END AS ordered_times
FROM sys.query_store_query_text qt
JOIN sys.query_store_query q ON q.query_text_id=qt.query_text_id
JOIN sys.query_store_plan p ON p.query_id=q.query_id
JOIN sys.query_store_runtime_stats rs ON rs.plan_id=p.plan_id
JOIN sys.query_store_runtime_stats_interval ri ON ri.runtime_stats_interval_id=rs.runtime_stats_interval_id
WHERE qt.query_sql_text LIKE N'% AS compatibility_marker,%' AND qt.query_sql_text NOT LIKE N'%sys.query_store_%';
-- @step batch
SELECT CASE WHEN COUNT_BIG(*)>0 THEN 1 ELSE 0 END AS has_text FROM sys.query_store_query_text;
SELECT CASE WHEN COUNT_BIG(*)>0 THEN 1 ELSE 0 END AS has_query FROM sys.query_store_query;
SELECT CASE WHEN COUNT_BIG(*)>0 THEN 1 ELSE 0 END AS has_plan FROM sys.query_store_plan;
SELECT CASE WHEN COUNT_BIG(*)>0 THEN 1 ELSE 0 END AS has_stats FROM sys.query_store_runtime_stats;
SELECT CASE WHEN COUNT_BIG(*)>0 THEN 1 ELSE 0 END AS has_interval FROM sys.query_store_runtime_stats_interval;

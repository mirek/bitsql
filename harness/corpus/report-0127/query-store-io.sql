-- Numeric IO observations; exact page counts are engine/workload dependent.
-- @step setup
ALTER DATABASE CURRENT SET QUERY_STORE=ON (OPERATION_MODE=READ_WRITE,INTERVAL_LENGTH_MINUTES=1,QUERY_CAPTURE_MODE=ALL);
-- @step setup
SELECT N'probe' AS compatibility_store_marker,COUNT_BIG(*) AS total FROM sys.all_objects a CROSS JOIN sys.all_objects b;
EXEC sys.sp_query_store_flush_db;
-- @step batch
SELECT rs.count_executions,rs.avg_rowcount,
CASE WHEN rs.avg_logical_io_reads>0 THEN 1 ELSE 0 END AS logical_reads_positive,
CASE WHEN rs.avg_physical_io_reads>=0 THEN 1 ELSE 0 END AS physical_reads_numeric,
CASE WHEN rs.min_logical_io_reads<=rs.avg_logical_io_reads AND rs.avg_logical_io_reads<=rs.max_logical_io_reads AND rs.last_logical_io_reads>=0 THEN 1 ELSE 0 END AS logical_consistent,
CASE WHEN rs.min_physical_io_reads<=rs.avg_physical_io_reads AND rs.avg_physical_io_reads<=rs.max_physical_io_reads AND rs.last_physical_io_reads>=0 THEN 1 ELSE 0 END AS physical_consistent,
CASE WHEN rs.stdev_logical_io_reads=0 AND rs.stdev_physical_io_reads=0 THEN 1 ELSE 0 END AS single_sample_stdev
FROM sys.query_store_query_text qt JOIN sys.query_store_query q ON q.query_text_id=qt.query_text_id
JOIN sys.query_store_plan p ON p.query_id=q.query_id JOIN sys.query_store_runtime_stats rs ON rs.plan_id=p.plan_id
WHERE qt.query_sql_text LIKE N'% AS compatibility_store_marker,%' AND qt.query_sql_text NOT LIKE N'%sys.query_store_%';
-- @step batch
SELECT CASE WHEN SUM(rs.count_executions*rs.avg_logical_io_reads)>0 THEN 1 ELSE 0 END AS numeric_total
FROM sys.query_store_query_text qt JOIN sys.query_store_query q ON q.query_text_id=qt.query_text_id
JOIN sys.query_store_plan p ON p.query_id=q.query_id JOIN sys.query_store_runtime_stats rs ON rs.plan_id=p.plan_id
WHERE qt.query_sql_text LIKE N'% AS compatibility_store_marker,%' AND qt.query_sql_text NOT LIKE N'%sys.query_store_%';

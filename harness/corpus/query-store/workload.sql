-- Capture real workload, inspect query/plan/runtime linkage, reset and remove.
-- @step setup
ALTER DATABASE CURRENT SET QUERY_STORE = ON (QUERY_CAPTURE_MODE = ALL);
WAITFOR DELAY '00:00:02';
ALTER DATABASE CURRENT SET QUERY_STORE CLEAR ALL;
WAITFOR DELAY '00:00:02';
CREATE TABLE dbo.qs_workload (id int NOT NULL PRIMARY KEY);
INSERT dbo.qs_workload VALUES (1), (2), (3);
-- @step batch
SELECT id FROM dbo.qs_workload WHERE id > 1 ORDER BY id OPTION (MAXDOP 1);
-- @step batch
SELECT id FROM dbo.qs_workload WHERE id > 1 ORDER BY id OPTION (MAXDOP 1);
-- @step setup
WAITFOR DELAY '00:00:01';
EXEC sys.sp_query_store_flush_db;
DECLARE @qs_attempt int = 0;
WHILE 2 > (SELECT COALESCE(SUM(r.count_executions), 0) FROM sys.query_store_query_text t JOIN sys.query_store_query q ON q.query_text_id = t.query_text_id JOIN sys.query_store_plan p ON p.query_id = q.query_id JOIN sys.query_store_runtime_stats r ON r.plan_id = p.plan_id WHERE t.query_sql_text LIKE N'SELECT id FROM dbo.qs_workload%' AND t.query_sql_text NOT LIKE N'%query_store%') AND @qs_attempt < 100
BEGIN
  WAITFOR DELAY '00:00:00.1';
  EXEC sys.sp_query_store_flush_db;
  SET @qs_attempt = @qs_attempt + 1;
END;
IF 2 > (SELECT COALESCE(SUM(r.count_executions), 0) FROM sys.query_store_query_text t JOIN sys.query_store_query q ON q.query_text_id = t.query_text_id JOIN sys.query_store_plan p ON p.query_id = q.query_id JOIN sys.query_store_runtime_stats r ON r.plan_id = p.plan_id WHERE t.query_sql_text LIKE N'SELECT id FROM dbo.qs_workload%' AND t.query_sql_text NOT LIKE N'%query_store%')
  THROW 51000, 'Query Store workload was not ingested within ten seconds', 1;
-- @step batch
SELECT t.query_sql_text, q.object_id, q.query_parameterization_type_desc,
       p.is_forced_plan, p.force_failure_count, p.last_force_failure_reason,
       r.execution_type_desc, SUM(r.count_executions) AS count_executions,
       SUM(r.avg_rowcount * r.count_executions) / SUM(r.count_executions) AS avg_rowcount,
       MIN(r.min_rowcount) AS min_rowcount, MAX(r.max_rowcount) AS max_rowcount,
       CASE WHEN MIN(r.avg_duration) >= 0 THEN 1 ELSE 0 END AS duration_nonnegative,
       CASE WHEN MIN(r.first_execution_time) <= MAX(r.last_execution_time) THEN 1 ELSE 0 END AS time_ordered
FROM sys.query_store_query_text t
JOIN sys.query_store_query q ON t.query_text_id = q.query_text_id
JOIN sys.query_store_plan p ON q.query_id = p.query_id
JOIN sys.query_store_runtime_stats r ON p.plan_id = r.plan_id
WHERE t.query_sql_text LIKE N'SELECT id FROM dbo.qs_workload%' AND t.query_sql_text NOT LIKE N'%query_store%'
GROUP BY t.query_sql_text, q.object_id, q.query_parameterization_type_desc,
         p.is_forced_plan, p.force_failure_count, p.last_force_failure_reason, r.execution_type_desc
ORDER BY r.execution_type_desc;
-- @step batch
DECLARE @query_id bigint, @plan_id bigint;
SELECT @query_id = q.query_id, @plan_id = p.plan_id
FROM sys.query_store_query_text t
JOIN sys.query_store_query q ON t.query_text_id = q.query_text_id
JOIN sys.query_store_plan p ON q.query_id = p.query_id
WHERE t.query_sql_text LIKE N'SELECT id FROM dbo.qs_workload%' AND t.query_sql_text NOT LIKE N'%query_store%';
SELECT CASE WHEN @query_id IS NOT NULL THEN 1 ELSE 0 END AS found_query;
EXEC sys.sp_query_store_force_plan @query_id, @plan_id;
SELECT is_forced_plan FROM sys.query_store_plan WHERE plan_id = @plan_id;
EXEC sys.sp_query_store_unforce_plan @query_id, @plan_id;
SELECT is_forced_plan FROM sys.query_store_plan WHERE plan_id = @plan_id;
EXEC sys.sp_query_store_reset_exec_stats @plan_id;
SELECT COUNT(*) AS stats_after_reset FROM sys.query_store_runtime_stats WHERE plan_id = @plan_id;
EXEC sys.sp_query_store_remove_plan @plan_id;
SELECT COUNT(*) AS plans_after_remove FROM sys.query_store_plan WHERE plan_id = @plan_id;
EXEC sys.sp_query_store_remove_query @query_id;
SELECT COUNT(*) AS queries_after_remove FROM sys.query_store_query WHERE query_id = @query_id;

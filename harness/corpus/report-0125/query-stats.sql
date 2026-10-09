-- Plan-cache history and correlated SQL-text lookup after repeated execution.
-- @step setup
CREATE TABLE dbo.foo (id int NOT NULL PRIMARY KEY);
INSERT dbo.foo VALUES (1),(2),(3);
-- @step setup
SELECT id AS report_history_marker FROM dbo.foo WHERE id>1 ORDER BY id;
-- @step setup
SELECT id AS report_history_marker FROM dbo.foo WHERE id>1 ORDER BY id;
-- @step batch
SELECT qs.execution_count,qs.total_rows,qs.last_rows,
CASE WHEN qs.total_elapsed_time>=qs.last_elapsed_time THEN 1 ELSE 0 END AS elapsed_consistent,
CASE WHEN qs.creation_time<=qs.last_execution_time THEN 1 ELSE 0 END AS time_ordered
FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t
WHERE t.text LIKE N'%report_history_marker%' AND t.text NOT LIKE N'%dm_exec_query_stats%';

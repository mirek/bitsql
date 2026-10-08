-- Stored procedure statement identity and execution statistics.
-- @step setup
ALTER DATABASE CURRENT SET QUERY_STORE = ON (QUERY_CAPTURE_MODE = ALL);
WAITFOR DELAY '00:00:02';
CREATE TABLE dbo.qs_proc_table (id int NOT NULL PRIMARY KEY);
INSERT dbo.qs_proc_table VALUES (1), (2), (3);
-- @step setup
CREATE PROCEDURE dbo.qs_proc @min int AS SELECT id FROM dbo.qs_proc_table WHERE id > @min ORDER BY id;
-- @step batch
EXEC dbo.qs_proc @min = 1;
-- @step batch
EXEC dbo.qs_proc @min = 2;
-- @step setup
WAITFOR DELAY '00:00:01';
EXEC sys.sp_query_store_flush_db;
DECLARE @qs_attempt int = 0;
WHILE 2 > (SELECT COALESCE(SUM(r.count_executions), 0) FROM sys.query_store_query q JOIN sys.query_store_plan p ON p.query_id = q.query_id JOIN sys.query_store_runtime_stats r ON r.plan_id = p.plan_id WHERE q.object_id = OBJECT_ID(N'dbo.qs_proc')) AND @qs_attempt < 100
BEGIN
  WAITFOR DELAY '00:00:00.1';
  EXEC sys.sp_query_store_flush_db;
  SET @qs_attempt = @qs_attempt + 1;
END;
IF 2 > (SELECT COALESCE(SUM(r.count_executions), 0) FROM sys.query_store_query q JOIN sys.query_store_plan p ON p.query_id = q.query_id JOIN sys.query_store_runtime_stats r ON r.plan_id = p.plan_id WHERE q.object_id = OBJECT_ID(N'dbo.qs_proc'))
  THROW 51000, 'Query Store workload was not ingested within ten seconds', 1;
-- @step batch
SELECT OBJECT_NAME(q.object_id) AS procedure_name, t.query_sql_text,
       q.query_parameterization_type_desc, SUM(r.count_executions) AS executions,
       SUM(r.avg_rowcount * r.count_executions) / SUM(r.count_executions) AS avg_rowcount,
       MIN(r.min_rowcount) AS min_rowcount, MAX(r.max_rowcount) AS max_rowcount
FROM sys.query_store_query_text t
JOIN sys.query_store_query q ON t.query_text_id = q.query_text_id
JOIN sys.query_store_plan p ON q.query_id = p.query_id
JOIN sys.query_store_runtime_stats r ON p.plan_id = r.plan_id
WHERE q.object_id = OBJECT_ID(N'dbo.qs_proc')
GROUP BY q.object_id, t.query_sql_text, q.query_parameterization_type_desc;

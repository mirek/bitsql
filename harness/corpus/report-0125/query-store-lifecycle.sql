-- Capture modes retain existing history; read-only/off suppress additions.
-- @step setup
ALTER DATABASE CURRENT SET QUERY_STORE=ON (QUERY_CAPTURE_MODE=ALL);
WAITFOR DELAY '00:00:01';
CREATE TABLE dbo.foo(id int);
INSERT dbo.foo VALUES(1),(2);
-- @step setup
SELECT id AS report_lifecycle_marker FROM dbo.foo;
-- @step setup
SELECT id AS report_lifecycle_marker FROM dbo.foo;
WAITFOR DELAY '00:00:01';
EXEC sys.sp_query_store_flush_db;
-- @step batch
SELECT SUM(rs.count_executions) AS executions FROM sys.query_store_query_text t JOIN sys.query_store_query q ON q.query_text_id=t.query_text_id JOIN sys.query_store_plan p ON p.query_id=q.query_id JOIN sys.query_store_runtime_stats rs ON rs.plan_id=p.plan_id WHERE t.query_sql_text LIKE N'SELECT id AS report_lifecycle_marker%';
-- @step setup
ALTER DATABASE CURRENT SET QUERY_STORE(OPERATION_MODE=READ_ONLY);
SELECT id AS report_lifecycle_marker FROM dbo.foo;
WAITFOR DELAY '00:00:01';
EXEC sys.sp_query_store_flush_db;
-- @step batch
SELECT SUM(rs.count_executions) AS executions FROM sys.query_store_query_text t JOIN sys.query_store_query q ON q.query_text_id=t.query_text_id JOIN sys.query_store_plan p ON p.query_id=q.query_id JOIN sys.query_store_runtime_stats rs ON rs.plan_id=p.plan_id WHERE t.query_sql_text LIKE N'SELECT id AS report_lifecycle_marker%';
-- @step setup
ALTER DATABASE CURRENT SET QUERY_STORE(OPERATION_MODE=READ_WRITE,QUERY_CAPTURE_MODE=NONE);
SELECT id AS report_lifecycle_marker FROM dbo.foo;
WAITFOR DELAY '00:00:01';
EXEC sys.sp_query_store_flush_db;
-- @step batch
SELECT SUM(rs.count_executions) AS executions FROM sys.query_store_query_text t JOIN sys.query_store_query q ON q.query_text_id=t.query_text_id JOIN sys.query_store_plan p ON p.query_id=q.query_id JOIN sys.query_store_runtime_stats rs ON rs.plan_id=p.plan_id WHERE t.query_sql_text LIKE N'SELECT id AS report_lifecycle_marker%';
-- @step setup
ALTER DATABASE CURRENT SET QUERY_STORE=OFF;
SELECT id AS report_lifecycle_marker FROM dbo.foo;
-- @step batch
SELECT SUM(rs.count_executions) AS executions FROM sys.query_store_query_text t JOIN sys.query_store_query q ON q.query_text_id=t.query_text_id JOIN sys.query_store_plan p ON p.query_id=q.query_id JOIN sys.query_store_runtime_stats rs ON rs.plan_id=p.plan_id WHERE t.query_sql_text LIKE N'SELECT id AS report_lifecycle_marker%';
-- @step setup
ALTER DATABASE CURRENT SET QUERY_STORE CLEAR ALL;
-- @step batch
SELECT COUNT(*) AS query_count FROM sys.query_store_query;
SELECT COUNT(*) AS runtime_count FROM sys.query_store_runtime_stats;

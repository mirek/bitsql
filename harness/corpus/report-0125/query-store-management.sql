-- Successful management must use the IDs of actual captured records.
-- @step setup
ALTER DATABASE CURRENT SET QUERY_STORE=ON (QUERY_CAPTURE_MODE=ALL);
WAITFOR DELAY '00:00:01';
CREATE TABLE dbo.foo(id int);
INSERT dbo.foo VALUES(1),(2);
-- @step setup
SELECT id AS report_management_marker FROM dbo.foo;
WAITFOR DELAY '00:00:01';
EXEC sys.sp_query_store_flush_db;
-- @step batch
DECLARE @q bigint,@p bigint;
SELECT @q=q.query_id,@p=p.plan_id FROM sys.query_store_query_text t JOIN sys.query_store_query q ON q.query_text_id=t.query_text_id JOIN sys.query_store_plan p ON p.query_id=q.query_id WHERE t.query_sql_text LIKE N'SELECT id AS report_management_marker%';
SELECT CASE WHEN @q IS NOT NULL AND @p IS NOT NULL THEN 1 ELSE 0 END AS found;
EXEC sys.sp_query_store_reset_exec_stats @p;
SELECT COUNT(*) AS stats_after_reset FROM sys.query_store_runtime_stats WHERE plan_id=@p;
EXEC sys.sp_query_store_remove_plan @p;
SELECT COUNT(*) AS plans_after_remove FROM sys.query_store_plan WHERE plan_id=@p;
SELECT COUNT(*) AS queries_after_plan_remove FROM sys.query_store_query WHERE query_id=@q;
EXEC sys.sp_query_store_remove_query @q;
SELECT COUNT(*) AS queries_after_remove FROM sys.query_store_query WHERE query_id=@q;

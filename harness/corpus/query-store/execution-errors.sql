-- Runtime exceptions have separate Query Store execution-type statistics.
-- @step setup
ALTER DATABASE CURRENT SET QUERY_STORE = ON (QUERY_CAPTURE_MODE = ALL);
WAITFOR DELAY '00:00:02';
CREATE TABLE dbo.qs_error (id int NOT NULL);
INSERT dbo.qs_error VALUES (2), (1);
-- @step setup
SELECT 10 / id AS value FROM dbo.qs_error OPTION (MAXDOP 1);
-- @step setup
DECLARE @warmup_attempt int = 0, @warmup_plan bigint;
WHILE @warmup_plan IS NULL AND @warmup_attempt < 100
BEGIN
 WAITFOR DELAY '00:00:00.1';
 EXEC sys.sp_query_store_flush_db;
 SELECT @warmup_plan = p.plan_id FROM sys.query_store_query_text t JOIN sys.query_store_query q ON q.query_text_id = t.query_text_id JOIN sys.query_store_plan p ON p.query_id = q.query_id WHERE t.query_sql_text LIKE N'SELECT 10 / id%';
 SET @warmup_attempt = @warmup_attempt + 1;
END;
EXEC sys.sp_query_store_reset_exec_stats @warmup_plan;
UPDATE dbo.qs_error SET id = 0 WHERE id = 2;
-- @step batch
SELECT 10 / id AS value FROM dbo.qs_error OPTION (MAXDOP 1);
-- @step setup
UPDATE dbo.qs_error SET id = 2 WHERE id = 0;
-- @step batch
SELECT 10 / id AS value FROM dbo.qs_error OPTION (MAXDOP 1);
-- @step setup
DECLARE @attempt int = 0;
WHILE 2 > (SELECT COALESCE(SUM(r.count_executions), 0) FROM sys.query_store_query_text t JOIN sys.query_store_query q ON q.query_text_id = t.query_text_id JOIN sys.query_store_plan p ON p.query_id = q.query_id JOIN sys.query_store_runtime_stats r ON r.plan_id = p.plan_id WHERE t.query_sql_text LIKE N'SELECT 10 / id%') AND @attempt < 100
BEGIN
 WAITFOR DELAY '00:00:00.1';
 EXEC sys.sp_query_store_flush_db;
 SET @attempt = @attempt + 1;
END;
-- @step batch
SELECT r.execution_type, r.execution_type_desc, SUM(r.count_executions) AS executions,
       CASE WHEN r.execution_type = 0 THEN SUM(r.avg_rowcount * r.count_executions) / SUM(r.count_executions) ELSE NULL END AS avg_rowcount
FROM sys.query_store_query_text t
JOIN sys.query_store_query q ON q.query_text_id = t.query_text_id
JOIN sys.query_store_plan p ON p.query_id = q.query_id
JOIN sys.query_store_runtime_stats r ON r.plan_id = p.plan_id
WHERE t.query_sql_text LIKE N'SELECT 10 / id%'
GROUP BY r.execution_type, r.execution_type_desc
ORDER BY r.execution_type;

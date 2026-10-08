-- Stored procedure parameterization and statement-handle lookup.
-- @step setup
ALTER DATABASE CURRENT SET QUERY_STORE = ON (QUERY_CAPTURE_MODE = ALL);
CREATE TABLE dbo.qs_param (id int NOT NULL);
INSERT dbo.qs_param VALUES(1),(2);
-- @step setup
CREATE PROCEDURE dbo.qs_param_proc @min int AS SELECT id FROM dbo.qs_param WHERE id > @min OPTION (MAXDOP 1);
-- @step setup
DECLARE @attempt int = 0;
WHILE NOT EXISTS(SELECT 1 FROM sys.query_store_query WHERE object_id = OBJECT_ID(N'dbo.qs_param_proc')) AND @attempt < 100
BEGIN
 EXEC dbo.qs_param_proc 0;
 WAITFOR DELAY '00:00:00.1';
 EXEC sys.sp_query_store_flush_db;
 SET @attempt = @attempt + 1;
END;
-- @step batch
SELECT t.query_sql_text, q.query_parameterization_type, q.query_parameterization_type_desc
FROM sys.query_store_query q JOIN sys.query_store_query_text t ON q.query_text_id=t.query_text_id
WHERE q.object_id=OBJECT_ID(N'dbo.qs_param_proc');
-- @step batch
SELECT f.query_sql_text, f.query_parameterization_type,
       DATALENGTH(f.statement_sql_handle) AS handle_bytes
FROM sys.query_store_query_text t
CROSS APPLY sys.fn_stmt_sql_handle_from_sql_stmt(t.query_sql_text, 0) f
WHERE t.query_sql_text LIKE N'(@min int)SELECT id FROM dbo.qs_param WHERE id > @min%';
-- @step batch
SELECT f.query_sql_text, f.query_parameterization_type,
       DATALENGTH(f.statement_sql_handle) AS handle_bytes
FROM sys.query_store_query_text t
CROSS APPLY sys.fn_stmt_sql_handle_from_sql_stmt(t.query_sql_text, 1) f
WHERE t.query_sql_text LIKE N'(@min int)SELECT id FROM dbo.qs_param WHERE id > @min%';
-- @step setup
DECLARE @attempt int = 0;
WHILE NOT EXISTS(SELECT 1 FROM sys.query_store_query_text WHERE query_sql_text LIKE N'(@minimum int)%') AND @attempt < 100
BEGIN
 EXEC sys.sp_executesql N'SELECT id FROM dbo.qs_param WHERE id > @minimum OPTION (MAXDOP 1)', N'@minimum int', @minimum=0;
 WAITFOR DELAY '00:00:00.1';
 EXEC sys.sp_query_store_flush_db;
 SET @attempt = @attempt + 1;
END;
-- @step batch
SELECT t.query_sql_text, q.query_parameterization_type, q.query_parameterization_type_desc
FROM sys.query_store_query q JOIN sys.query_store_query_text t ON q.query_text_id=t.query_text_id
WHERE t.query_sql_text LIKE N'(@minimum int)%';
-- @step batch
SELECT f.query_sql_text, f.query_parameterization_type,
       DATALENGTH(f.statement_sql_handle) AS handle_bytes
FROM sys.query_store_query_text t
CROSS APPLY sys.fn_stmt_sql_handle_from_sql_stmt(t.query_sql_text, 1) f
WHERE t.query_sql_text LIKE N'(@minimum int)%';
-- @step batch
SELECT f.query_sql_text, f.query_parameterization_type,
       DATALENGTH(f.statement_sql_handle) AS handle_bytes
FROM sys.query_store_query_text t
CROSS APPLY sys.fn_stmt_sql_handle_from_sql_stmt(t.query_sql_text, 0) f
WHERE t.query_sql_text LIKE N'(@minimum int)%';

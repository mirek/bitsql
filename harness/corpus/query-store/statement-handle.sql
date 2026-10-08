-- Statement-handle lookup for captured and uncaptured text.
-- @step setup
ALTER DATABASE CURRENT SET QUERY_STORE = ON (QUERY_CAPTURE_MODE = ALL);
WAITFOR DELAY '00:00:02';
CREATE TABLE dbo.qs_identity (id int NOT NULL);
INSERT dbo.qs_identity VALUES (1);
-- @step setup
DECLARE @qs_ready int = 0;
WHILE NOT EXISTS (SELECT 1 FROM sys.query_store_query_text WHERE query_sql_text = N'SELECT id FROM dbo.qs_identity OPTION (MAXDOP 1)') AND @qs_ready < 100
BEGIN
 EXEC(N'SELECT id FROM dbo.qs_identity OPTION (MAXDOP 1);');
 WAITFOR DELAY '00:00:00.1';
 EXEC sys.sp_query_store_flush_db;
 SET @qs_ready = @qs_ready + 1;
END;

-- @step batch
SELECT id FROM dbo.qs_identity OPTION (MAXDOP 1);
-- @step setup
DECLARE @attempt int = 0;
WHILE NOT EXISTS (SELECT 1 FROM sys.query_store_query_text WHERE query_sql_text LIKE N'SELECT id FROM dbo.qs_identity%') AND @attempt < 100
BEGIN
  WAITFOR DELAY '00:00:00.1';
  EXEC sys.sp_query_store_flush_db;
  SET @attempt = @attempt + 1;
END;
-- @step batch
SELECT f.query_sql_text, f.query_parameterization_type,
       DATALENGTH(f.statement_sql_handle) AS handle_bytes,
       CASE WHEN f.statement_sql_handle = t.statement_sql_handle THEN 1 ELSE 0 END AS handle_matches
FROM sys.query_store_query_text t
CROSS APPLY sys.fn_stmt_sql_handle_from_sql_stmt(t.query_sql_text, 0) f
WHERE t.query_sql_text = N'SELECT id FROM dbo.qs_identity OPTION (MAXDOP 1)';
-- @step batch
SELECT query_sql_text, query_parameterization_type,
       DATALENGTH(statement_sql_handle) AS handle_bytes
FROM sys.fn_stmt_sql_handle_from_sql_stmt(N'SELECT id FROM dbo.qs_identity OPTION (MAXDOP 1)', NULL);
-- @step batch
SELECT COUNT(*) AS uncaptured_rows
FROM sys.fn_stmt_sql_handle_from_sql_stmt(N'SELECT 917234 AS never_executed', 0);
-- @step batch
SELECT COUNT(*) AS other_parameterization_rows
FROM sys.fn_stmt_sql_handle_from_sql_stmt(N'SELECT id FROM dbo.qs_identity OPTION (MAXDOP 1)', 1);
-- @step batch
SELECT COUNT(*) AS invalid_parameterization_rows
FROM sys.fn_stmt_sql_handle_from_sql_stmt(N'SELECT id FROM dbo.qs_identity OPTION (MAXDOP 1)', 4);

-- Exact-text matching and argument boundaries for statement-handle lookup.
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
SELECT N'case' AS shape, COUNT(*) AS matches FROM sys.fn_stmt_sql_handle_from_sql_stmt(N'select id FROM dbo.qs_identity OPTION (MAXDOP 1)', 0)
UNION ALL
SELECT N'trailing space', COUNT(*) FROM sys.fn_stmt_sql_handle_from_sql_stmt(N'SELECT id FROM dbo.qs_identity OPTION (MAXDOP 1) ', 0)
UNION ALL
SELECT N'semicolon', COUNT(*) FROM sys.fn_stmt_sql_handle_from_sql_stmt(N'SELECT id FROM dbo.qs_identity OPTION (MAXDOP 1);', 0)
UNION ALL
SELECT N'null', COUNT(*) FROM sys.fn_stmt_sql_handle_from_sql_stmt(NULL, 0);
-- @step batch
SELECT query_sql_text, query_parameterization_type,
       DATALENGTH(statement_sql_handle) AS handle_bytes
FROM sys.fn_stmt_sql_handle_from_sql_stmt(N'SELECT id FROM dbo.qs_identity OPTION (MAXDOP 1)', DEFAULT);
-- @step batch
SELECT COUNT(*) AS bad_negative FROM sys.fn_stmt_sql_handle_from_sql_stmt(N'SELECT id FROM dbo.qs_identity OPTION (MAXDOP 1)', -1);
-- @step batch
SELECT COUNT(*) AS bad_arity FROM sys.fn_stmt_sql_handle_from_sql_stmt(N'SELECT id FROM dbo.qs_identity OPTION (MAXDOP 1)');

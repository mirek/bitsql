-- Query text and opaque handle metadata from an actual SELECT.
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
SELECT query_sql_text, is_part_of_encrypted_module, has_restricted_text,
       DATALENGTH(statement_sql_handle) AS handle_bytes
FROM sys.query_store_query_text
WHERE query_sql_text LIKE N'SELECT id FROM dbo.qs_identity%';

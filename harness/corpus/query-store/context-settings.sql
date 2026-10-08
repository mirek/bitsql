-- Compilation context changes; NOCOUNT must not split query identity.
-- @step setup
ALTER DATABASE CURRENT SET QUERY_STORE = ON (QUERY_CAPTURE_MODE = ALL);
WAITFOR DELAY '00:00:02';
CREATE TABLE dbo.qs_context (id int NOT NULL);
INSERT dbo.qs_context VALUES (1);
-- @step setup
DECLARE @qs_ready int = 0;
WHILE NOT EXISTS (SELECT 1 FROM sys.query_store_query_text WHERE query_sql_text = N'SELECT id FROM dbo.qs_context OPTION (MAXDOP 1)') AND @qs_ready < 100
BEGIN
 EXEC(N'SELECT id FROM dbo.qs_context OPTION (MAXDOP 1);');
 WAITFOR DELAY '00:00:00.1';
 EXEC sys.sp_query_store_flush_db;
 SET @qs_ready = @qs_ready + 1;
END;

-- @step setup
SELECT id FROM dbo.qs_context OPTION (MAXDOP 1);
-- @step setup
SET NOCOUNT ON;
-- @step setup
SELECT id FROM dbo.qs_context OPTION (MAXDOP 1);
-- @step setup
SET NOCOUNT OFF; SET DATEFIRST 1;
-- @step setup
SELECT id FROM dbo.qs_context OPTION (MAXDOP 1);
-- @step setup
SET DATEFIRST 7; SET DATEFORMAT ymd;
-- @step setup
SELECT id FROM dbo.qs_context OPTION (MAXDOP 1);
-- @step setup
SET DATEFORMAT mdy; SET ARITHABORT OFF;
-- @step setup
SELECT id FROM dbo.qs_context OPTION (MAXDOP 1);
-- @step setup
SET ARITHABORT ON; SET ANSI_WARNINGS OFF;
-- @step setup
SELECT id FROM dbo.qs_context OPTION (MAXDOP 1);
-- @step setup
SET ANSI_WARNINGS ON; SET QUOTED_IDENTIFIER OFF;
-- @step setup
SELECT id FROM dbo.qs_context OPTION (MAXDOP 1);
-- @step setup
SET QUOTED_IDENTIFIER ON;
WAITFOR DELAY '00:00:03';
EXEC sys.sp_query_store_flush_db;
-- @step batch
SELECT c.set_options, c.language_id, c.date_format, c.date_first, c.status, c.default_schema_id, COUNT(*) AS queries
FROM sys.query_store_query q JOIN sys.query_store_query_text t ON t.query_text_id = q.query_text_id JOIN sys.query_context_settings c ON c.context_settings_id = q.context_settings_id
WHERE t.query_sql_text = N'SELECT id FROM dbo.qs_context OPTION (MAXDOP 1)'
GROUP BY c.set_options, c.language_id, c.date_format, c.date_first, c.status, c.default_schema_id
ORDER BY c.set_options, c.date_format, c.date_first;

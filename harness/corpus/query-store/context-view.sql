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
SELECT DISTINCT set_options, language_id, date_format, date_first, status,
       required_cursor_options, acceptable_cursor_options, merge_action_type,
       default_schema_id, is_replication_specific, is_contained
FROM sys.query_context_settings
WHERE set_options IN (0x000010fb, 0x000000fb, 0x000010bb, 0x000010eb)
ORDER BY set_options, date_format, date_first;

-- Query identity, shared text and compilation context from an actual SELECT.
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
SELECT t.query_sql_text, t.is_part_of_encrypted_module, t.has_restricted_text,
       DATALENGTH(t.statement_sql_handle) AS handle_bytes,
       q.object_id, q.is_internal_query, q.query_parameterization_type,
       q.query_parameterization_type_desc, DATALENGTH(q.query_hash) AS hash_bytes,
       c.set_options, c.language_id, c.date_format, c.date_first, c.status,
       c.required_cursor_options, c.acceptable_cursor_options, c.merge_action_type,
       c.default_schema_id, c.is_replication_specific, c.is_contained
FROM sys.query_store_query_text t
JOIN sys.query_store_query q ON q.query_text_id = t.query_text_id
JOIN sys.query_context_settings c ON c.context_settings_id = q.context_settings_id
WHERE t.query_sql_text LIKE N'SELECT id FROM dbo.qs_identity%';
-- @step batch
SELECT COUNT(*) AS linked_plans FROM sys.query_store_plan p
JOIN sys.query_store_query q ON q.query_id = p.query_id
JOIN sys.query_store_query_text t ON t.query_text_id = q.query_text_id
WHERE t.query_sql_text LIKE N'SELECT id FROM dbo.qs_identity%';

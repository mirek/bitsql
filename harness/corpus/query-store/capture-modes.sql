-- NONE, READ_ONLY and OFF retain history and stop new capture.
-- @step setup
ALTER DATABASE CURRENT SET QUERY_STORE = ON (QUERY_CAPTURE_MODE = ALL);
WAITFOR DELAY '00:00:02';
CREATE TABLE dbo.qs_modes (id int NOT NULL PRIMARY KEY);
INSERT dbo.qs_modes VALUES (1), (2);
-- @step batch
SELECT id FROM dbo.qs_modes ORDER BY id;
-- @step setup
WAITFOR DELAY '00:00:01';
EXEC sys.sp_query_store_flush_db;
DECLARE @qs_attempt int = 0;
WHILE NOT EXISTS (SELECT 1 FROM sys.query_store_query_text WHERE query_sql_text = N'SELECT id FROM dbo.qs_modes ORDER BY id') AND @qs_attempt < 100
BEGIN
  WAITFOR DELAY '00:00:00.1';
  EXEC sys.sp_query_store_flush_db;
  SET @qs_attempt = @qs_attempt + 1;
END;
IF NOT EXISTS (SELECT 1 FROM sys.query_store_query_text WHERE query_sql_text = N'SELECT id FROM dbo.qs_modes ORDER BY id')
  THROW 51000, 'Query Store workload was not ingested within ten seconds', 1;
ALTER DATABASE CURRENT SET QUERY_STORE (QUERY_CAPTURE_MODE = NONE);
-- @step batch
SELECT id, id + 10 AS mode_none FROM dbo.qs_modes ORDER BY id;
-- @step setup
WAITFOR DELAY '00:00:01';
EXEC sys.sp_query_store_flush_db;
ALTER DATABASE CURRENT SET QUERY_STORE (OPERATION_MODE = READ_ONLY);
-- @step batch
SELECT id, id + 20 AS mode_readonly FROM dbo.qs_modes ORDER BY id;
-- @step batch
SELECT COUNT(*) AS retained_queries
FROM sys.query_store_query_text WHERE query_sql_text LIKE N'%qs_modes%' AND query_sql_text LIKE N'%SELECT%' AND query_sql_text NOT LIKE N'%query_store%';
-- @step batch
ALTER DATABASE CURRENT SET QUERY_STORE = OFF;
SELECT COUNT(*) AS retained_when_off
FROM sys.query_store_query_text WHERE query_sql_text LIKE N'%qs_modes%' AND query_sql_text LIKE N'%SELECT%' AND query_sql_text NOT LIKE N'%query_store%';
-- @step batch
ALTER DATABASE CURRENT SET QUERY_STORE CLEAR;
SELECT COUNT(*) AS queries_after_clear FROM sys.query_store_query;

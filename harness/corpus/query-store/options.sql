-- Query Store defaults, state transitions, configuration and clearing.
-- @step batch
SELECT * FROM sys.database_query_store_options;
-- @step batch
ALTER DATABASE CURRENT SET QUERY_STORE = OFF;
SELECT * FROM sys.database_query_store_options;
-- @step batch
ALTER DATABASE CURRENT SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE, QUERY_CAPTURE_MODE = ALL, INTERVAL_LENGTH_MINUTES = 5, DATA_FLUSH_INTERVAL_SECONDS = 60, MAX_STORAGE_SIZE_MB = 256, MAX_PLANS_PER_QUERY = 50, CLEANUP_POLICY = (STALE_QUERY_THRESHOLD_DAYS = 7), SIZE_BASED_CLEANUP_MODE = OFF, WAIT_STATS_CAPTURE_MODE = OFF);
SELECT * FROM sys.database_query_store_options;
-- @step batch
ALTER DATABASE CURRENT SET QUERY_STORE (OPERATION_MODE = READ_ONLY);
SELECT * FROM sys.database_query_store_options;
-- @step batch
ALTER DATABASE CURRENT SET QUERY_STORE CLEAR ALL;
SELECT * FROM sys.database_query_store_options;
-- @step batch
ALTER DATABASE CURRENT SET QUERY_STORE = OFF;
SELECT is_query_store_on FROM sys.databases WHERE name = DB_NAME();

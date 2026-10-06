-- Database-scoped preview state is shared across sessions.
-- @step batch
SELECT value, is_value_default FROM sys.database_scoped_configurations WHERE name='PREVIEW_FEATURES';
-- @step batch
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
-- @step batch conn=2
SELECT value, is_value_default FROM sys.database_scoped_configurations WHERE name='PREVIEW_FEATURES';
-- @step batch conn=2
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = OFF;
-- @step batch
SELECT value, is_value_default FROM sys.database_scoped_configurations WHERE name='PREVIEW_FEATURES';
-- @step batch
BEGIN TRAN;
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
SELECT @@TRANCOUNT AS tc;
ROLLBACK;
-- @step batch
SELECT @@TRANCOUNT AS tc, XACT_STATE() AS xs, value FROM sys.database_scoped_configurations WHERE name='PREVIEW_FEATURES';

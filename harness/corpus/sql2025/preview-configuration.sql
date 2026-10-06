-- SQL Server 2025 database-scoped preview configuration lifecycle.
-- @step batch
SELECT configuration_id, name, value, value_for_secondary, is_value_default FROM sys.database_scoped_configurations WHERE name = 'PREVIEW_FEATURES';
-- @step batch
SELECT EDIT_DISTANCE('a' COLLATE Latin1_General_100_CI_AS,'b');
-- @step batch
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
-- @step batch
SELECT configuration_id, name, value, value_for_secondary, is_value_default FROM sys.database_scoped_configurations WHERE name = 'PREVIEW_FEATURES';
-- @step batch
SELECT EDIT_DISTANCE('a' COLLATE Latin1_General_100_CI_AS,'b');
-- @step batch conn=2
SELECT EDIT_DISTANCE('a' COLLATE Latin1_General_100_CI_AS,'b');
-- @step batch
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = OFF;
-- @step batch
SELECT configuration_id, name, value, value_for_secondary, is_value_default FROM sys.database_scoped_configurations WHERE name = 'PREVIEW_FEATURES';
-- @step batch
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = 1;
-- @step batch
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = 'ON';
-- @step batch
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES ON;
-- @step batch
BEGIN TRAN;
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
SELECT @@TRANCOUNT AS tc;
ROLLBACK;
-- @step batch
SELECT value FROM sys.database_scoped_configurations WHERE name = 'PREVIEW_FEATURES';
-- @step batch
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = OFF;

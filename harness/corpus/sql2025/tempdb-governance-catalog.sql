-- SQL Server 2025 tempdb governance: read-only default limits and descriptors.
-- @step batch
SELECT name,group_max_tempdb_data_mb,group_max_tempdb_data_percent FROM sys.resource_governor_workload_groups WHERE name IN ('internal','default') ORDER BY name;
-- @step batch
SELECT c.name,t.name AS type_name,c.max_length,c.precision,c.scale,c.is_nullable FROM sys.all_columns AS c JOIN sys.types AS t ON c.user_type_id=t.user_type_id WHERE c.object_id=OBJECT_ID('sys.dm_resource_governor_workload_groups') AND c.name LIKE '%tempdb%' ORDER BY c.column_id;
-- @step batch
SELECT c.name,t.name AS type_name,c.max_length,c.precision,c.scale,c.is_nullable FROM sys.all_columns AS c JOIN sys.types AS t ON c.user_type_id=t.user_type_id WHERE c.object_id=OBJECT_ID('sys.resource_governor_workload_groups') AND c.name LIKE '%tempdb%' ORDER BY c.column_id;

-- SQL Server 2022 diagnostic catalog metadata, independent of activity.
SELECT * FROM sys.dm_exec_query_stats WHERE 1=0;
SELECT * FROM sys.dm_db_index_usage_stats WHERE 1=0;
SELECT * FROM sys.dm_db_missing_index_details WHERE 1=0;
SELECT * FROM sys.dm_db_missing_index_groups WHERE 1=0;
SELECT * FROM sys.dm_db_missing_index_group_stats WHERE 1=0;
SELECT * FROM sys.dm_db_partition_stats WHERE 1=0;
SELECT * FROM sys.dm_os_sys_info WHERE 1=0;

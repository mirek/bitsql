-- Partition rows and joins after real DML (small-page oracle contract).
-- @step setup
CREATE TABLE dbo.foo (id int NOT NULL PRIMARY KEY, category nvarchar(20));
-- @step batch
SELECT d.index_id,d.partition_number,d.row_count,d.in_row_data_page_count,d.in_row_used_page_count,d.in_row_reserved_page_count,d.used_page_count,d.reserved_page_count
FROM sys.dm_db_partition_stats d JOIN sys.partitions p ON p.partition_id=d.partition_id
WHERE d.object_id=OBJECT_ID(N'dbo.foo') ORDER BY d.index_id;
-- @step setup
INSERT dbo.foo VALUES(1,N'alpha'),(2,N'beta'),(3,N'gamma');
-- @step batch
SELECT d.index_id,d.partition_number,d.row_count,d.in_row_data_page_count,d.in_row_used_page_count,d.in_row_reserved_page_count,d.used_page_count,d.reserved_page_count
FROM sys.dm_db_partition_stats d JOIN sys.partitions p ON p.partition_id=d.partition_id
WHERE d.object_id=OBJECT_ID(N'dbo.foo') ORDER BY d.index_id;
-- @step setup
DELETE dbo.foo WHERE id=2;
-- @step batch
SELECT d.row_count,p.rows FROM sys.dm_db_partition_stats d JOIN sys.partitions p ON p.partition_id=d.partition_id WHERE d.object_id=OBJECT_ID(N'dbo.foo');

-- sys.partitions and sys.allocation_units: one partition per heap/index
-- (none for a disabled nonclustered index), filtered index row counts,
-- IN_ROW / LOB / ROW_OVERFLOW allocation units, ids joining container_id to
-- hobt_id/partition_id, and small-table page counts before/after TRUNCATE
-- (2026-10-05 compatibility report: storage-size query).
-- @step setup
CREATE TABLE dbo.items(id int NOT NULL PRIMARY KEY, name nvarchar(50) NULL, f int NULL, INDEX ix_name (name));
CREATE INDEX ix_f ON dbo.items (f) WHERE f IS NOT NULL;
CREATE TABLE dbo.heap(id int, v varchar(max));
CREATE TABLE dbo.ov(id int NOT NULL, a varchar(8000), b varchar(8000));
CREATE TABLE dbo.e(id int NOT NULL PRIMARY KEY);
CREATE TABLE dbo.dis(id int NOT NULL PRIMARY KEY, v int, INDEX ixv (v));
INSERT INTO dbo.items VALUES (1, N'a', NULL), (2, N'b', 5);
INSERT INTO dbo.heap VALUES (1, 'x');
INSERT INTO dbo.ov VALUES (1, REPLICATE('a', 100), 'b');
INSERT INTO dbo.dis VALUES (1, 1);
ALTER INDEX ixv ON dbo.dis DISABLE;
-- @step batch
SELECT OBJECT_NAME(object_id) AS t, index_id, partition_number, rows,
  CASE WHEN partition_id = hobt_id THEN 1 ELSE 0 END AS same_id,
  filestream_filegroup_id, data_compression, data_compression_desc, xml_compression, xml_compression_desc
FROM sys.partitions
WHERE object_id IN (OBJECT_ID(N'dbo.items'), OBJECT_ID(N'dbo.heap'), OBJECT_ID(N'dbo.ov'), OBJECT_ID(N'dbo.e'), OBJECT_ID(N'dbo.dis'))
ORDER BY t, index_id;
-- @step batch
SELECT OBJECT_NAME(p.object_id) AS t, p.index_id, au.type, au.type_desc, au.data_space_id,
  au.total_pages, au.used_pages, au.data_pages
FROM sys.allocation_units AS au
JOIN sys.partitions AS p ON au.container_id = CASE WHEN au.type IN (1, 3) THEN p.hobt_id ELSE p.partition_id END
WHERE p.object_id IN (OBJECT_ID(N'dbo.items'), OBJECT_ID(N'dbo.heap'), OBJECT_ID(N'dbo.ov'), OBJECT_ID(N'dbo.e'), OBJECT_ID(N'dbo.dis'))
ORDER BY t, p.index_id, au.type;
-- @step batch
SELECT COUNT(*) AS n FROM sys.partitions WHERE partition_id IS NULL OR hobt_id IS NULL;
SELECT COUNT(*) AS n FROM (SELECT TOP (1) allocation_unit_id, type, container_id, used_pages FROM sys.allocation_units) AS x;
-- @step batch
SELECT COUNT(*) AS au_rows, SUM(au.used_pages) * 8192 AS used_bytes, SUM(CASE WHEN au.type = 1 THEN p.rows ELSE 0 END) AS row_count
FROM sys.partitions AS p
JOIN sys.allocation_units AS au ON au.container_id IN (p.hobt_id, p.partition_id)
WHERE p.object_id = OBJECT_ID(N'dbo.items') AND p.index_id IN (0, 1);
TRUNCATE TABLE dbo.items;
SELECT COUNT(*) AS au_rows, SUM(au.used_pages) * 8192 AS used_bytes, SUM(CASE WHEN au.type = 1 THEN p.rows ELSE 0 END) AS row_count
FROM sys.partitions AS p
JOIN sys.allocation_units AS au ON au.container_id IN (p.hobt_id, p.partition_id)
WHERE p.object_id = OBJECT_ID(N'dbo.items') AND p.index_id IN (0, 1);
-- @step batch
CREATE TABLE #tt(id int); INSERT #tt VALUES (1);
SELECT index_id, rows FROM tempdb.sys.partitions WHERE object_id = OBJECT_ID(N'tempdb..#tt');
SELECT index_id, rows FROM sys.partitions WHERE object_id = OBJECT_ID(N'tempdb..#tt');

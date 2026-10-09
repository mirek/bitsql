-- Missing-index details/group/statistics join after a selective scan workload.
-- @step setup
CREATE TABLE dbo.foo(id int NOT NULL PRIMARY KEY, category int NOT NULL, payload varchar(100));
INSERT dbo.foo SELECT value,value%100,REPLICATE('x',100) FROM GENERATE_SERIES(1,10000);
-- @step setup
SELECT payload FROM dbo.foo WHERE category=42 ORDER BY payload OPTION(RECOMPILE);
-- @step setup
SELECT payload FROM dbo.foo WHERE category=42 ORDER BY payload OPTION(RECOMPILE);
-- @step batch
SELECT d.equality_columns,d.inequality_columns,d.included_columns,
CASE WHEN s.user_seeks+s.user_scans>0 THEN 1 ELSE 0 END AS has_usage,
CASE WHEN s.avg_total_user_cost>0 THEN 1 ELSE 0 END AS has_cost,
CASE WHEN s.avg_user_impact>0 THEN 1 ELSE 0 END AS has_impact
FROM sys.dm_db_missing_index_details d JOIN sys.dm_db_missing_index_groups g ON g.index_handle=d.index_handle
JOIN sys.dm_db_missing_index_group_stats s ON s.group_handle=g.index_group_handle
WHERE d.database_id=DB_ID() AND d.object_id=OBJECT_ID(N'dbo.foo');
-- @step setup
CREATE INDEX foo_category_idx ON dbo.foo(category) INCLUDE(payload);
-- @step batch
SELECT COUNT(*) AS recommendations FROM sys.dm_db_missing_index_details WHERE database_id=DB_ID() AND object_id=OBJECT_ID(N'dbo.foo');

-- Index counters count statements, including rolled-back writes.
-- @step setup
CREATE TABLE dbo.foo (id int NOT NULL PRIMARY KEY, category nvarchar(20));
INSERT dbo.foo VALUES(1,N'alpha'),(2,N'beta'),(3,N'gamma');
-- @step setup
SELECT category FROM dbo.foo WHERE id=2;
SELECT SUM(id) FROM dbo.foo;
UPDATE dbo.foo SET category=N'delta' WHERE id=3;
-- @step batch
SELECT i.index_id,
CASE WHEN u.user_seeks>0 THEN 1 ELSE 0 END AS has_seeks,
CASE WHEN u.user_scans>0 THEN 1 ELSE 0 END AS has_scans,
CASE WHEN u.user_updates>0 THEN 1 ELSE 0 END AS has_updates,
CASE WHEN u.last_user_seek IS NOT NULL THEN 1 ELSE 0 END AS has_seek_time
FROM sys.dm_db_index_usage_stats u JOIN sys.indexes i ON i.object_id=u.object_id AND i.index_id=u.index_id
WHERE u.database_id=DB_ID() AND u.object_id=OBJECT_ID(N'dbo.foo');

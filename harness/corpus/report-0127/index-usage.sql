-- Report's uniform nonclustered nvarchar fixture.
-- @step setup
CREATE TABLE dbo.foo(id int NOT NULL PRIMARY KEY,note nvarchar(50) NOT NULL);
CREATE INDEX foo_note_idx ON dbo.foo(note);
INSERT dbo.foo(id,note) SELECT TOP(5000) ROW_NUMBER() OVER(ORDER BY(SELECT NULL)),N'note' FROM sys.all_objects a CROSS JOIN sys.all_objects b;
-- @step batch
SELECT COUNT(*) AS total FROM dbo.foo WITH(INDEX(foo_note_idx)) WHERE note=N'note';
SELECT i.name,u.user_seeks,u.user_scans,u.user_lookups,u.user_updates
FROM sys.indexes i LEFT JOIN sys.dm_db_index_usage_stats u ON u.database_id=DB_ID() AND u.object_id=i.object_id AND u.index_id=i.index_id
WHERE i.object_id=OBJECT_ID(N'dbo.foo') AND i.name=N'foo_note_idx';

-- ALTER INDEX DISABLE / REBUILD / REORGANIZE on nonclustered indexes:
-- completions (CurCmd 337), 2727 / 1088 for missing objects, a disabled
-- unique index accepts duplicates and its REBUILD fails with 1505, 1973
-- for REORGANIZE of a disabled index, ALL, FILLFACTOR, rollback, and the
-- lowest free index_id being reused.
-- @step setup
CREATE TABLE dbo.t(id INT CONSTRAINT PK_t PRIMARY KEY, v INT, w INT);
CREATE UNIQUE INDEX UX_t_v ON dbo.t(v);
CREATE INDEX IX_t_w ON dbo.t(w);
INSERT dbo.t VALUES (1, 1, 1), (2, 2, 2);
-- @step batch
ALTER INDEX nope ON dbo.t DISABLE
-- @step batch
ALTER INDEX IX_t_w ON dbo.nope DISABLE
-- @step batch
ALTER INDEX UX_t_v ON dbo.t DISABLE; INSERT dbo.t VALUES (3, 1, 3); SELECT * FROM dbo.t ORDER BY id
-- @step batch
SELECT id FROM dbo.t WHERE v = 1 ORDER BY id
-- @step batch
ALTER INDEX UX_t_v ON dbo.t REBUILD
-- @step batch
SELECT name, is_disabled, is_unique FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.t') ORDER BY index_id
-- @step batch
DELETE dbo.t WHERE id = 3; ALTER INDEX UX_t_v ON dbo.t REORGANIZE
-- @step batch
ALTER INDEX ALL ON dbo.t REBUILD; SELECT name, is_disabled FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.t') ORDER BY index_id
-- @step batch
INSERT dbo.t VALUES (4, 1, 4)
-- @step batch
ALTER INDEX IX_t_w ON dbo.t REBUILD WITH (FILLFACTOR = 80, ONLINE = OFF); SELECT name, fill_factor FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.t') ORDER BY index_id
-- @step batch
ALTER INDEX IX_t_w ON dbo.t REORGANIZE; SELECT @@ROWCOUNT AS r
-- @step batch
BEGIN TRAN; ALTER INDEX IX_t_w ON dbo.t DISABLE; ROLLBACK; SELECT name, is_disabled FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.t') ORDER BY index_id
-- @step batch
DROP INDEX UX_t_v ON dbo.t; CREATE INDEX IX_t_new ON dbo.t(v); SELECT name, index_id FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.t') ORDER BY index_id
-- @step batch
ALTER INDEX IX_t_w ON t DISABLE; DROP INDEX IX_t_w ON dbo.t; SELECT @@ROWCOUNT AS r

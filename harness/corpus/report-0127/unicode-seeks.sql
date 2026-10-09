-- Seek eligibility must preserve Unicode collation/padding and long values.
-- @step setup
CREATE TABLE dbo.foo(id int NOT NULL PRIMARY KEY,note nvarchar(50) NULL);
CREATE INDEX foo_note_idx ON dbo.foo(note);
INSERT dbo.foo VALUES(1,N'note'),(2,N'NOTE '),(3,NULL),(4,N'other'),(5,N'nóté');
-- @step batch
SELECT id,note FROM dbo.foo WITH(INDEX(foo_note_idx)) WHERE note=N'note' ORDER BY id;
SELECT id,note FROM dbo.foo WITH(INDEX(foo_note_idx)) WHERE note=N'note ' ORDER BY id;
SELECT id FROM dbo.foo WITH(INDEX(foo_note_idx)) WHERE note=N'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx';
SELECT id FROM dbo.foo WITH(INDEX(foo_note_idx)) WHERE note=N'missing';
SELECT id FROM dbo.foo WITH(INDEX(foo_note_idx)) WHERE note=NULL;
SELECT id FROM dbo.foo WHERE note COLLATE Latin1_General_100_BIN2=N'note' ORDER BY id;
-- @step batch
DECLARE @note nvarchar(4000)=N'note';
SELECT id FROM dbo.foo WITH(INDEX(foo_note_idx)) WHERE note=@note ORDER BY id;

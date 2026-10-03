-- Trap: v1 supports only STATIC, FAST_FORWARD, LOCAL cursors; a STATIC cursor reads a snapshot.
-- @step setup
CREATE TABLE cur (id int NOT NULL PRIMARY KEY);
INSERT INTO cur VALUES (1), (2), (3);
-- @step batch
DECLARE @id int, @seen varchar(100) = '';
DECLARE c CURSOR LOCAL STATIC FOR SELECT id FROM cur ORDER BY id;
OPEN c;
INSERT INTO cur VALUES (4);
FETCH NEXT FROM c INTO @id;
WHILE @@FETCH_STATUS = 0
BEGIN
  SET @seen = @seen + CAST(@id AS varchar(10)) + ',';
  FETCH NEXT FROM c INTO @id;
END
SELECT @seen AS static_seen, @@CURSOR_ROWS AS cursor_rows;
CLOSE c; DEALLOCATE c;
DECLARE f CURSOR LOCAL FAST_FORWARD FOR SELECT id FROM cur ORDER BY id DESC;
OPEN f; FETCH NEXT FROM f INTO @id; SELECT @id AS first_desc; CLOSE f; DEALLOCATE f;

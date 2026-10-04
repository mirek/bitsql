-- Keyset cursors: membership and order are fixed at OPEN, values are read
-- at FETCH. Deleted rows (and rows whose key changed) fetch with
-- @@FETCH_STATUS -2, ROWSTAT 2 and blank values: NULL for nullable
-- columns, else zero / spaces / zero bytes / the type's zero date.
-- Inserted rows are not members.
-- @step setup
CREATE TABLE t (id int NOT NULL PRIMARY KEY, nv nvarchar(5) NOT NULL, ch char(3) NOT NULL, d decimal(5,2) NOT NULL, dt datetime NOT NULL, b bit NOT NULL, g uniqueidentifier NOT NULL, vb varbinary(4) NOT NULL, bn binary(3) NOT NULL, f float NOT NULL, d2 date NOT NULL, tm time NOT NULL, m money NOT NULL, x int NULL, q int NOT NULL);
INSERT t VALUES (1,N'a','a',1.5,'2020-01-01',1,'6F9619FF-8B86-D011-B42D-00C04FC964FF',0x01,0x01,1.5,'2020-01-01','10:00',1,1,10),(2,N'b','b',2.5,'2020-01-02',1,'6F9619FF-8B86-D011-B42D-00C04FC964FF',0x02,0x02,2.5,'2020-01-02','11:00',2,2,20),(3,N'c','c',3.5,'2020-01-03',0,'6F9619FF-8B86-D011-B42D-00C04FC964FF',0x03,0x03,3.5,'2020-01-03','12:00',3,NULL,30);
-- @step batch
DECLARE k CURSOR SCROLL KEYSET FOR SELECT id, nv, ch, d, dt, b, g, vb, bn, f, d2, tm, m, x, q, q * 2 AS q2 FROM t WHERE q < 100 ORDER BY q DESC;
OPEN k;
SELECT @@CURSOR_ROWS AS cursor_rows;
DELETE t WHERE id = 2;
UPDATE t SET q = 500, nv = N'z' WHERE id = 3;
INSERT t VALUES (4,N'd','d',4.5,'2020-01-04',1,'6F9619FF-8B86-D011-B42D-00C04FC964FF',0x04,0x04,4.5,'2020-01-04','13:00',4,4,5);
FETCH FIRST FROM k; SELECT @@FETCH_STATUS AS fs1;
FETCH NEXT FROM k; SELECT @@FETCH_STATUS AS fs2;
FETCH NEXT FROM k; SELECT @@FETCH_STATUS AS fs3;
FETCH NEXT FROM k; SELECT @@FETCH_STATUS AS fs4;
FETCH PRIOR FROM k; SELECT @@FETCH_STATUS AS fs5;
SELECT @@CURSOR_ROWS AS cursor_rows_after, CURSOR_STATUS('global', 'k') AS st;
DEALLOCATE k;
-- @step batch
DECLARE k2 CURSOR KEYSET FOR SELECT id, x FROM t ORDER BY id;
DECLARE @id int = -5, @x int = -5;
OPEN k2;
UPDATE t SET id = 10 WHERE id = 1;
FETCH NEXT FROM k2 INTO @id, @x;
SELECT @@FETCH_STATUS AS fs, @id AS id, @x AS x;
FETCH NEXT FROM k2 INTO @id, @x;
SELECT @@FETCH_STATUS AS fs, @id AS id, @x AS x;
CLOSE k2;
SELECT @@CURSOR_ROWS AS after_close;
DEALLOCATE k2;

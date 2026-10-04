-- Dynamic cursors re-read rows at every FETCH, positioned by the current
-- row's key in the cursor order: deleted rows are skipped, rows inserted
-- after the current position appear, an updated ORDER BY key moves a row.
-- Heaps and forward-only defaults included; ABSOLUTE is 16925.
-- @step setup
CREATE TABLE t (id int NOT NULL PRIMARY KEY, q int NOT NULL, name varchar(10) NOT NULL);
CREATE INDEX ix_q ON t(q);
INSERT t VALUES (1,10,'a'),(2,20,'b'),(3,30,'c'),(4,40,'d'),(5,50,'e');
CREATE TABLE h (v int NOT NULL);
INSERT h VALUES (3),(1),(2);
-- @step batch
DECLARE d CURSOR SCROLL DYNAMIC FOR SELECT id, q, name FROM t ORDER BY q;
OPEN d;
FETCH NEXT FROM d;
FETCH NEXT FROM d;
DELETE t WHERE id = 2;
FETCH NEXT FROM d;
INSERT t VALUES (6,35,'f'),(7,5,'g');
FETCH NEXT FROM d;
FETCH PRIOR FROM d;
FETCH PRIOR FROM d;
UPDATE t SET q = 60 WHERE id = 4;
FETCH NEXT FROM d;
FETCH NEXT FROM d;
FETCH NEXT FROM d;
FETCH NEXT FROM d;
FETCH NEXT FROM d; SELECT @@FETCH_STATUS AS fs_end;
FETCH PRIOR FROM d;
FETCH FIRST FROM d;
FETCH RELATIVE 2 FROM d;
DELETE t WHERE id = 6;
FETCH RELATIVE -1 FROM d;
FETCH LAST FROM d;
FETCH RELATIVE -2 FROM d;
FETCH ABSOLUTE 1 FROM d; SELECT @@FETCH_STATUS AS fs_abs;
SELECT @@CURSOR_ROWS AS cursor_rows, CURSOR_STATUS('global', 'd') AS st;
DEALLOCATE d;
-- @step batch
DECLARE hd CURSOR LOCAL FOR SELECT v FROM h;
OPEN hd;
FETCH NEXT FROM hd;
INSERT h VALUES (0);
DELETE h WHERE v = 1;
FETCH NEXT FROM hd;
FETCH NEXT FROM hd;
FETCH NEXT FROM hd;
-- @step batch
DECLARE ff CURSOR LOCAL FAST_FORWARD FOR SELECT id, name FROM t;
OPEN ff;
FETCH NEXT FROM ff;
DELETE t WHERE id = 3;
INSERT t VALUES (8,80,'h');
FETCH NEXT FROM ff;
FETCH NEXT FROM ff;
FETCH NEXT FROM ff;
FETCH NEXT FROM ff;
FETCH NEXT FROM ff;
FETCH NEXT FROM ff;

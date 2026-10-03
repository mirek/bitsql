-- Filtered unique indexes with comparison predicates: rows outside the
-- filter neither conflict nor block, UPDATE moving a row into the filter
-- is checked, and IGNORE_DUP_KEY skips duplicate INSERT rows with 3604.
-- @step setup
CREATE TABLE t (id int NOT NULL CONSTRAINT pk_t PRIMARY KEY, n int NULL, s varchar(10) NULL);
CREATE UNIQUE INDEX ux_pos ON t (n) WHERE n > 0;
CREATE UNIQUE INDEX ux_s ON t (s) WHERE s >= 'm' AND id < 100;
-- @step batch
INSERT t VALUES (1, 0, 'a'), (2, 0, 'a'), (3, -1, 'z'), (4, 5, 'm');
-- @step batch
INSERT t VALUES (5, 5, NULL);
-- @step batch
INSERT t VALUES (100, 6, 'z');
-- @step batch
INSERT t VALUES (6, 7, 'z');
-- @step batch
UPDATE t SET n = 5 WHERE id = 1;
-- @step batch
SELECT id, n, s FROM t ORDER BY id;
SELECT name, has_filter, filter_definition FROM sys.indexes WHERE object_id = OBJECT_ID('t') AND has_filter = 1 ORDER BY name;
-- @step batch
CREATE TABLE k (id int NOT NULL, v int NULL);
CREATE UNIQUE INDEX ux_k ON k (id) WITH (IGNORE_DUP_KEY = ON, FILLFACTOR = 70);
INSERT k VALUES (1, 1), (1, 2), (2, 3), (2, 4);
SELECT id, v FROM k ORDER BY id;
INSERT k OUTPUT inserted.id VALUES (3, 5), (1, 6);
SELECT name, ignore_dup_key, fill_factor FROM sys.indexes WHERE object_id = OBJECT_ID('k');

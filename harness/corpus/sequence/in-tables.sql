-- NEXT VALUE FOR as a column DEFAULT, in INSERT ... SELECT, and per row.
-- @step setup
CREATE SEQUENCE dbo.ids AS int START WITH 1;
CREATE TABLE t (id int NOT NULL CONSTRAINT df_t_id DEFAULT (NEXT VALUE FOR dbo.ids) CONSTRAINT pk_t PRIMARY KEY, v varchar(5));
-- @step batch
INSERT t (v) VALUES ('a'), ('b');
INSERT t (id, v) SELECT NEXT VALUE FOR dbo.ids, x FROM (VALUES ('c'), ('d')) AS s(x);
SELECT id, v FROM t ORDER BY id;
DECLARE @n int = NEXT VALUE FOR dbo.ids;
SELECT @n AS n;

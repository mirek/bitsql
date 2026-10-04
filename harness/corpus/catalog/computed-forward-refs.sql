-- Computed columns bind against every column of the table, whatever the
-- declaration order (external compatibility report: a PERSISTED JSON_VALUE
-- column declared before the column it reads). Covers SELECT * and
-- sys.columns order (declaration order), result metadata, nullability,
-- a computed column using another computed one (1759, also forward and
-- self references), ALTER TABLE ADD of a computed column using a column of
-- the same ADD list, 2715's column ordinal, and the batch-level 8183 for
-- CHECK / REFERENCES / NULL / NOT NULL on a non-persisted computed column.
-- @step batch
CREATE TABLE items(
  value AS(CONVERT([nvarchar](200),JSON_VALUE(body,N'$.a'))) PERSISTED,
  body nvarchar(max)
);
INSERT INTO items(body) VALUES (N'{"a":"foo"}');
SELECT * FROM items;
SELECT name, column_id, is_computed, is_nullable, system_type_id, max_length FROM sys.columns WHERE object_id = OBJECT_ID('items') ORDER BY column_id;
-- @step batch
CREATE TABLE t2(doubled AS(value*2) PERSISTED, value int NOT NULL, x AS value + 1);
INSERT INTO t2(value) VALUES (21);
SELECT * FROM t2;
SELECT name, column_id, is_computed, is_nullable FROM sys.columns WHERE object_id = OBJECT_ID('t2') ORDER BY column_id;
SELECT name, definition, is_persisted FROM sys.computed_columns WHERE object_id = OBJECT_ID('t2') ORDER BY column_id;
-- @step batch
CREATE TABLE t3(a AS b + 1, b AS c * 2, c int);
-- @step batch
CREATE TABLE t4(a AS c + 1, c int, b AS a * 2);
-- @step batch
CREATE TABLE s1(a AS a + 1, c int);
-- @step batch
CREATE TABLE t5(a AS nosuch + 1, c int);
-- @step batch
CREATE TABLE t6(c int);
ALTER TABLE t6 ADD d AS e + 1, e int;
SELECT name, column_id FROM sys.columns WHERE object_id = OBJECT_ID('t6') ORDER BY column_id;
-- @step batch
CREATE TABLE s2(c int);
ALTER TABLE s2 ADD d AS e + 1, e AS c * 2;
-- @step batch
CREATE TABLE s3(c int);
INSERT INTO s3 VALUES (1);
ALTER TABLE s3 ADD d AS e + 1, e int NOT NULL CONSTRAINT df_s3_e DEFAULT 4 WITH VALUES;
SELECT * FROM s3;
-- @step batch
CREATE TABLE t7(a AS c + 1 PERSISTED NOT NULL, c int NOT NULL);
SELECT name, is_nullable FROM sys.columns WHERE object_id = OBJECT_ID('t7') ORDER BY column_id;
-- @step batch
CREATE TABLE t8(a AS c + 1, c int NOT NULL CONSTRAINT pk_t8 PRIMARY KEY, d AS c * 2 PERSISTED CONSTRAINT uq_t8 UNIQUE);
INSERT INTO t8(c) VALUES (3);
SELECT * FROM t8;
SELECT name, is_nullable FROM sys.columns WHERE object_id = OBJECT_ID('t8') ORDER BY column_id;
-- @step batch
CREATE TABLE s4(a AS c + d, c int NOT NULL, d int IDENTITY);
INSERT INTO s4(c) VALUES (10);
SELECT a, c, d FROM s4;
-- @step batch
CREATE TABLE s5(a AS ISNULL(c, 0), c int NOT NULL, b AS c);
SELECT name, is_nullable FROM sys.columns WHERE object_id = OBJECT_ID('s5') ORDER BY column_id;
SELECT * FROM s5;
-- @step batch
DECLARE @tv TABLE(a AS c + 1, c int);
INSERT INTO @tv(c) VALUES (1);
SELECT * FROM @tv;
-- @step batch
CREATE TABLE e1(a AS nosuch + 1, c nosuchtype);
-- @step batch
CREATE TABLE e2(a AS nosuch + 1, c int, c int);
-- @step batch
CREATE TABLE e3(a AS c + 1, c int, CONSTRAINT ck_e3 CHECK (zz > 0));
-- @step batch
CREATE TABLE e5(a AS c + 1 CONSTRAINT uq_e5 UNIQUE, c nvarchar(max));
SELECT name, is_unique FROM sys.indexes WHERE object_id = OBJECT_ID('e5') ORDER BY index_id;
-- @step batch
CREATE TABLE e6(a AS c CONSTRAINT pk_e6 PRIMARY KEY, c nvarchar(max));
-- @step batch
CREATE TABLE e7(a AS c PERSISTED NOT NULL CONSTRAINT pk_e7 PRIMARY KEY, c int NOT NULL);
SELECT i.name, ic.column_id FROM sys.indexes i JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id WHERE i.object_id = OBJECT_ID('e7');
-- @step batch
CREATE TABLE e9(a AS c + 1 PERSISTED CONSTRAINT ck_e9 CHECK (a > 0), c int);
INSERT INTO e9(c) VALUES (5);
SELECT * FROM e9;
-- @step batch
CREATE TABLE e10(a AS c + NEWID(), c int);
-- @step batch
CREATE TABLE e12(a AS CONVERT(int, c) PERSISTED, c varchar(10));
INSERT INTO e12(c) VALUES ('42');
SELECT * FROM e12;
-- @step batch
CREATE TABLE g1(c int, d int, e nosuchtype);
-- @step batch
CREATE TABLE g2(c int);
ALTER TABLE g2 ADD d int, e nosuchtype;
-- @step batch
DECLARE @t TABLE(c int, d nosuchtype);
-- @step batch
CREATE TABLE f1(c int, a AS c + 1 NOT NULL);
-- @step batch
CREATE TABLE f2p(id int CONSTRAINT pk_f2p PRIMARY KEY);
CREATE TABLE f2(c int, a AS c + 1 REFERENCES f2p(id));
-- @step batch
SELECT OBJECT_ID('f2p') AS f2p_not_created;
-- @step batch
CREATE TABLE f3(c int, a AS c + 1, CONSTRAINT ck_f3 CHECK (a > 0));
-- @step batch
CREATE TABLE f4(a AS c + 1 CHECK (a > 0), c nosuchtype);
-- @step batch
CREATE TABLE f5(c int, a AS c + 1 NULL);
-- @step batch
CREATE TABLE f6(a AS nosuch + 1 CHECK (a > 0), c int);
-- @step batch
CREATE TABLE g3(c int);
ALTER TABLE g3 ADD a AS c + 1 CHECK (a > 0);
-- @step batch
SELECT OBJECT_ID('g3') AS g3_not_created;

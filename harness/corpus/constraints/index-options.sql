-- CREATE INDEX options and diagnostics: DROP_EXISTING keeps the index id,
-- the key length warnings, duplicate key columns, ALTER COLUMN widening an
-- indexed varchar, and DROP INDEX options.
-- @step setup
CREATE TABLE t (id int NOT NULL CONSTRAINT pk_t PRIMARY KEY, a varchar(10) NULL, b nvarchar(1000) NULL, c int NULL);
CREATE INDEX ix_a ON t (a);
CREATE INDEX ix_c ON t (c);
-- @step batch
CREATE UNIQUE INDEX ix_a ON t (a) WITH (DROP_EXISTING = ON);
SELECT name, index_id, is_unique FROM sys.indexes WHERE object_id = OBJECT_ID('t') ORDER BY index_id;
-- @step batch
CREATE INDEX ix_b ON t (b);
-- @step batch
CREATE INDEX ix_bc ON t (b, a, c);
-- @step batch
CREATE INDEX ix_dup ON t (c, a, c);
-- @step batch
CREATE INDEX ix_pad ON t (c) WITH (PAD_INDEX = ON, FILLFACTOR = 101);
-- @step batch
ALTER TABLE t ALTER COLUMN a varchar(20) NULL;
SELECT max_length FROM sys.columns WHERE object_id = OBJECT_ID('t') AND name = 'a';
-- @step batch
ALTER TABLE t ALTER COLUMN a varchar(5) NULL;
-- @step batch
DROP INDEX ix_c ON t WITH (MAXDOP = 1);
SELECT name FROM sys.indexes WHERE object_id = OBJECT_ID('t') ORDER BY index_id;

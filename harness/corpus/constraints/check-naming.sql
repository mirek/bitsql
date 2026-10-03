-- System names and parent_column_id of CHECK, DEFAULT and FOREIGN KEY
-- constraints: a table-level CHECK over one column, over two columns, and
-- name truncation for long table and column names.
-- @step setup
CREATE TABLE p (id int NOT NULL CONSTRAINT pk_p PRIMARY KEY);
CREATE TABLE abcdefghijklmnopqrst (a int NULL, bb int NULL, longcolumnname int NULL DEFAULT 0, c int NULL,
  CHECK (a > 0), CHECK (a > bb), CHECK (longcolumnname <> 3), CHECK (c IS NULL AND c IS NULL),
  FOREIGN KEY (longcolumnname) REFERENCES p (id), FOREIGN KEY (c) REFERENCES p (id));
CREATE TABLE tw (x int NULL CHECK (x > 0) DEFAULT 1);
ALTER TABLE tw ADD CHECK (x < 100);
ALTER TABLE tw ADD CONSTRAINT ck_named CHECK (x <> 5);
-- @step batch
SELECT LEFT(name, LEN(name) - 8) AS prefix, LEN(name) AS length, parent_column_id, definition FROM sys.check_constraints ORDER BY parent_column_id, definition;
SELECT LEFT(name, LEN(name) - 8) AS prefix, LEN(name) AS length, parent_column_id FROM sys.default_constraints ORDER BY prefix;
SELECT LEFT(name, LEN(name) - 8) AS prefix, LEN(name) AS length FROM sys.foreign_keys ORDER BY prefix;
SELECT LEFT(CONSTRAINT_NAME, LEN(CONSTRAINT_NAME) - 8) AS prefix, COLUMN_NAME FROM INFORMATION_SCHEMA.CONSTRAINT_COLUMN_USAGE WHERE TABLE_NAME = 'tw' ORDER BY prefix, COLUMN_NAME;
SELECT CHECK_CLAUSE FROM INFORMATION_SCHEMA.CHECK_CONSTRAINTS WHERE CONSTRAINT_NAME = 'ck_named';

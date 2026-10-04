-- A typed default is checked at CREATE/ALTER like an assignment: 206 when
-- no conversion exists, 257 when only an explicit one does (binary to
-- date is explicit). The untyped NULL constant is covered by
-- default-untyped-null.
-- @step batch
CREATE TABLE a1 (d date DEFAULT (1));
-- @step batch
CREATE TABLE a2 (g uniqueidentifier DEFAULT (1.5));
-- @step batch
CREATE TABLE a3 (d date DEFAULT (0x01));
-- @step batch
CREATE TABLE a4 (i int DEFAULT (GETDATE()));
-- @step batch
CREATE TABLE a5 (t time DEFAULT (1));
-- @step batch
CREATE TABLE a6 (d datetime DEFAULT (1));
-- @step batch
CREATE TABLE a7 (d date DEFAULT ('x'));
-- @step batch
CREATE TABLE a8 (b varbinary(10) DEFAULT ('x'));
-- @step batch
CREATE TABLE a9 (x xml DEFAULT (1));
-- @step batch
CREATE TABLE a10 (i int DEFAULT (CAST(NULL AS date)));
-- @step batch
CREATE TABLE a11 (s sql_variant DEFAULT (CAST(NULL AS xml)));
-- @step batch
CREATE TABLE a12 (id int);
ALTER TABLE a12 ADD CONSTRAINT df_a12 DEFAULT (CAST(NULL AS int)) FOR id;
ALTER TABLE a12 ADD d date NULL CONSTRAINT df_a12d DEFAULT (1);

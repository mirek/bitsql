-- NOT EMULATED (fails on purpose with Emulator errors): objects of another
-- database whose bodies would bind names in the session database or that
-- need DDL there. A trigger fires in its own database (DB_NAME() is that
-- database); views and functions of another database bind in theirs.
-- @step setup
IF DB_ID(N'bitsql_xdb_uns') IS NOT NULL DROP DATABASE bitsql_xdb_uns;
CREATE DATABASE bitsql_xdb_uns;
-- @step setup
EXEC (N'USE bitsql_xdb_uns;
CREATE TABLE t (id int NOT NULL CONSTRAINT t_pk PRIMARY KEY);
CREATE TABLE trg (id int NOT NULL);
EXEC (N''CREATE VIEW dbo.v AS SELECT id, DB_NAME() AS db FROM dbo.t'');
EXEC (N''CREATE FUNCTION dbo.f() RETURNS sysname AS BEGIN RETURN DB_NAME() END'');
EXEC (N''CREATE TRIGGER tr ON dbo.trg AFTER INSERT AS SELECT DB_NAME() AS trigger_db, COUNT(*) AS c FROM inserted'');
INSERT t VALUES (1);');
-- @step batch
INSERT bitsql_xdb_uns.dbo.trg VALUES (1);
-- @step batch
SELECT id, db FROM bitsql_xdb_uns.dbo.v;
-- @step batch
SELECT bitsql_xdb_uns.dbo.f() AS f;
-- @step setup
DROP DATABASE bitsql_xdb_uns;

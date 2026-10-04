-- Tables of another database by three-part name: CREATE TABLE, SELECT
-- INTO, ALTER TABLE, CREATE INDEX, DROP TABLE (IF EXISTS) and TRUNCATE
-- act there; a database that
-- does not exist is 2702 for CREATE, 3701 for DROP and nothing for DROP IF
-- EXISTS. CREATE VIEW / PROCEDURE with any database prefix (even the
-- session's own) is 166 for the whole batch, reported on line 13.
-- @step setup
IF DB_ID(N'bitsql_xdb_ddl') IS NOT NULL DROP DATABASE bitsql_xdb_ddl;
CREATE DATABASE bitsql_xdb_ddl;
-- @step batch
CREATE TABLE bitsql_xdb_nodb.dbo.t (id int);
-- @step batch
DROP TABLE bitsql_xdb_nodb.dbo.t;
-- @step batch
DROP TABLE IF EXISTS bitsql_xdb_nodb.dbo.t;
SELECT 1 AS after_drop;
-- @step batch
DROP TABLE bitsql_xdb_ddl.dbo.nope;
-- @step batch
DROP TABLE IF EXISTS bitsql_xdb_ddl.dbo.nope;
CREATE TABLE bitsql_xdb_ddl.dbo.t (id int IDENTITY(1,1) NOT NULL, v int NULL CONSTRAINT t_v_df DEFAULT (7));
CREATE TABLE bitsql_xdb_ddl.dbo.t (id int);
-- @step batch
INSERT bitsql_xdb_ddl.dbo.t (v) VALUES (5), (6);
INSERT bitsql_xdb_ddl.dbo.t DEFAULT VALUES;
SELECT SCOPE_IDENTITY() AS si, @@IDENTITY AS ii, IDENT_CURRENT(N'bitsql_xdb_ddl.dbo.t') AS ic;
SELECT id, v FROM bitsql_xdb_ddl.dbo.t ORDER BY id;
SELECT id INTO bitsql_xdb_ddl.dbo.copy FROM bitsql_xdb_ddl.dbo.t WHERE id > 1;
SELECT COUNT(*) AS n FROM bitsql_xdb_ddl.dbo.copy;
SELECT OBJECT_ID(N'dbo.copy') AS here, OBJECT_ID(N'dbo.t') AS here_t;
SELECT name FROM bitsql_xdb_ddl.sys.default_constraints;
-- @step batch
ALTER TABLE bitsql_xdb_ddl.dbo.t ADD n int NULL CONSTRAINT t_n_ck CHECK (n > 0);
CREATE INDEX t_n ON bitsql_xdb_ddl.dbo.t (n);
-- @step batch
SELECT name FROM bitsql_xdb_ddl.sys.columns WHERE object_id = OBJECT_ID(N'bitsql_xdb_ddl.dbo.t') ORDER BY column_id;
SELECT name FROM bitsql_xdb_ddl.sys.indexes WHERE object_id = OBJECT_ID(N'bitsql_xdb_ddl.dbo.t') AND index_id > 0;
INSERT bitsql_xdb_ddl.dbo.t (v, n) VALUES (1, 0);
ALTER TABLE bitsql_xdb_ddl.dbo.t DROP CONSTRAINT t_n_ck;
INSERT bitsql_xdb_ddl.dbo.t (v, n) VALUES (1, 0);
SELECT COUNT(*) AS n FROM bitsql_xdb_ddl.dbo.t;
-- @step batch
CREATE TABLE bitsql_xdb_ddl..dflt (id int);
SELECT name FROM bitsql_xdb_ddl.sys.tables ORDER BY name;
TRUNCATE TABLE bitsql_xdb_ddl.dbo.copy;
SELECT COUNT(*) AS n FROM bitsql_xdb_ddl.dbo.copy;
DROP TABLE bitsql_xdb_ddl.dbo.t, bitsql_xdb_ddl.dbo.copy;
SELECT name FROM bitsql_xdb_ddl.sys.tables ORDER BY name;
-- @step batch
DECLARE @s nvarchar(200) = N'CREATE VIEW ' + QUOTENAME(DB_NAME()) + N'.dbo.v AS SELECT 1 AS x';
EXEC (@s);
-- @step batch
CREATE VIEW bitsql_xdb_ddl.dbo.v AS SELECT 1 AS x;
-- @step batch
CREATE PROCEDURE bitsql_xdb_ddl.dbo.p AS SELECT 1 AS x;
-- @step batch
CREATE VIEW bitsql_xdb_nodb.dbo.v AS SELECT 1 AS x;
-- @step setup
DROP DATABASE bitsql_xdb_ddl;

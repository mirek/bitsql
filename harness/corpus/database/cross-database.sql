-- Database discovery is server-wide and three-part names reach tables of
-- another database (external compatibility report: fixtures probing
-- DB_ID / sys.databases before DROP+CREATE DATABASE, then reading and
-- writing foo.dbo.items from master). sys.databases, master.sys.databases,
-- DB_ID and DB_NAME list every database whatever the session database is;
-- SELECT/INSERT/UPDATE/DELETE on db.schema.t work from another database,
-- inside one transaction across both databases too (also through USE in
-- dynamic SQL); another database's
-- catalog views (db.sys.x, db.INFORMATION_SCHEMA.x), OBJECT_ID,
-- OBJECT_NAME(id, db_id), IDENT_CURRENT and COL_LENGTH see its objects.
-- Database ids differ between servers, so only facts about them are
-- selected.
-- @step setup
IF DB_ID(N'bitsql_xdb_case') IS NOT NULL DROP DATABASE bitsql_xdb_case;
-- @step batch
CREATE DATABASE bitsql_xdb_case;
SELECT CASE WHEN DB_ID(N'bitsql_xdb_case') IS NULL THEN 0 ELSE 1 END AS has_id,
  DB_NAME(DB_ID(N'bitsql_xdb_case')) AS by_id, DB_NAME() AS cur;
SELECT name, state_desc, recovery_model_desc, collation_name, compatibility_level
FROM sys.databases WHERE name = N'bitsql_xdb_case';
SELECT COUNT(*) AS count FROM master.sys.databases WHERE name = N'bitsql_xdb_case';
SELECT name, database_id FROM sys.databases WHERE database_id <= 4 ORDER BY database_id;
SELECT COUNT(*) AS listed FROM sys.databases WHERE name IN (N'bitsql_xdb_case', DB_NAME());
SELECT CASE WHEN d.database_id = DB_ID(N'bitsql_xdb_case') THEN 1 ELSE 0 END AS same_id
FROM sys.databases AS d WHERE d.name = N'bitsql_xdb_case';
-- @step rpc
-- @param @n nvarchar(128) = "bitsql_xdb_case"
SELECT COUNT(*) AS count FROM master.sys.databases WHERE name = @n
-- @step batch
IF DB_ID(N'bitsql_xdb_case') IS NOT NULL DROP DATABASE bitsql_xdb_case;
CREATE DATABASE bitsql_xdb_case;
SELECT COUNT(*) AS recreated FROM sys.databases WHERE name = N'bitsql_xdb_case';
-- @step batch
EXEC (N'USE bitsql_xdb_case;
SELECT COUNT(*) AS from_other FROM master.sys.databases WHERE name = N''bitsql_xdb_case'';
SELECT DB_NAME() AS cur, CASE WHEN DB_ID() = DB_ID(N''bitsql_xdb_case'') THEN 1 ELSE 0 END AS same;
CREATE TABLE items (id int NOT NULL CONSTRAINT items_pk PRIMARY KEY, n int IDENTITY(10, 5) NOT NULL);
INSERT items (id) VALUES (1);');
SELECT DB_NAME() AS back_in;
SELECT id FROM bitsql_xdb_case.dbo.items;
INSERT bitsql_xdb_case.dbo.items(id) VALUES (2);
SELECT SCOPE_IDENTITY() AS si, IDENT_CURRENT(N'bitsql_xdb_case.dbo.items') AS ic,
  COL_LENGTH(N'bitsql_xdb_case.dbo.items', N'id') AS cl;
SELECT id, n FROM bitsql_xdb_case..items ORDER BY id;
UPDATE bitsql_xdb_case.dbo.items SET id = 3 WHERE id = 2;
DELETE FROM bitsql_xdb_case.dbo.items WHERE id = 1;
SELECT i.id FROM bitsql_xdb_case.dbo.items AS i;
SELECT items.id FROM bitsql_xdb_case.dbo.items;
SELECT CASE WHEN OBJECT_ID(N'bitsql_xdb_case.dbo.items') IS NULL THEN 0 ELSE 1 END AS there,
  OBJECT_ID(N'dbo.items') AS here,
  OBJECT_NAME(OBJECT_ID(N'bitsql_xdb_case.dbo.items'), DB_ID(N'bitsql_xdb_case')) AS nm,
  OBJECT_SCHEMA_NAME(OBJECT_ID(N'bitsql_xdb_case.dbo.items'), DB_ID(N'bitsql_xdb_case')) AS sch;
SELECT name FROM bitsql_xdb_case.sys.tables;
SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME FROM bitsql_xdb_case.INFORMATION_SCHEMA.TABLES;
SELECT c.name, t.name AS type_name FROM bitsql_xdb_case.sys.columns AS c
JOIN bitsql_xdb_case.sys.types AS t ON t.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID(N'bitsql_xdb_case.dbo.items') ORDER BY c.column_id;
INSERT bitsql_xdb_case.dbo.items(id) VALUES (3);
SELECT id FROM bitsql_xdb_case.dbo.nope;
-- @step batch
SELECT id FROM bitsql_xdb_nodb.dbo.items;
-- @step batch
INSERT bitsql_xdb_nodb.dbo.items VALUES (1);
-- @step batch
SELECT name FROM bitsql_xdb_nodb.sys.tables;
-- @step batch
SELECT DB_NAME(32000) AS a, DB_ID(N'bitsql_xdb_nodb') AS b, OBJECT_NAME(1, 32000) AS c;
-- @step batch
CREATE TABLE here_t (id int NOT NULL CONSTRAINT here_t_pk PRIMARY KEY, m int NULL);
INSERT here_t VALUES (3, 30), (4, 40);
SELECT a.id, b.m FROM bitsql_xdb_case.dbo.items AS a JOIN dbo.here_t AS b ON a.id = b.id;
INSERT bitsql_xdb_case.dbo.items (id) SELECT id FROM here_t WHERE id = 4;
UPDATE x SET id = 5 FROM bitsql_xdb_case.dbo.items AS x JOIN here_t AS h ON h.id = x.id WHERE h.m = 40;
SELECT id FROM bitsql_xdb_case.dbo.items ORDER BY id;
INSERT bitsql_xdb_case.dbo.items (id) OUTPUT inserted.id VALUES (7), (3);
SELECT COUNT(*) AS after_failed FROM bitsql_xdb_case.dbo.items;
-- @step batch
BEGIN TRAN;
INSERT bitsql_xdb_case.dbo.items (id) VALUES (8);
INSERT here_t VALUES (8, 80);
SELECT @@TRANCOUNT AS tc, (SELECT COUNT(*) FROM bitsql_xdb_case.dbo.items) AS there, (SELECT COUNT(*) FROM here_t) AS here;
SAVE TRAN sp;
DELETE FROM bitsql_xdb_case.dbo.items;
ROLLBACK TRAN sp;
SELECT COUNT(*) AS after_sp FROM bitsql_xdb_case.dbo.items;
ROLLBACK;
SELECT (SELECT COUNT(*) FROM bitsql_xdb_case.dbo.items) AS there, (SELECT COUNT(*) FROM here_t) AS here;
BEGIN TRAN;
INSERT bitsql_xdb_case.dbo.items (id) VALUES (9);
DELETE FROM here_t WHERE id = 3;
COMMIT;
SELECT (SELECT COUNT(*) FROM bitsql_xdb_case.dbo.items) AS there, (SELECT COUNT(*) FROM here_t) AS here;
-- @step batch
BEGIN TRAN;
EXEC (N'USE bitsql_xdb_case; DELETE FROM items WHERE id = 9;');
SELECT COUNT(*) AS in_tran FROM bitsql_xdb_case.dbo.items;
ROLLBACK;
SELECT COUNT(*) AS rolled_back FROM bitsql_xdb_case.dbo.items;
TRUNCATE TABLE bitsql_xdb_case.dbo.items;
SELECT COUNT(*) AS truncated FROM bitsql_xdb_case.dbo.items;
-- @step setup
DROP TABLE here_t;
DROP DATABASE bitsql_xdb_case;

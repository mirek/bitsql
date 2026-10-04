-- Identity overflow is 8115 + INFO 3606, ends the batch, rolls back an open
-- transaction, is catchable, and does not advance the counter. An INSERT
-- (or SELECT INTO) into a table without identity makes SCOPE_IDENTITY()
-- and @@IDENTITY NULL; a nested EXEC only resets @@IDENTITY. Explicit
-- decimal identity values move the counter. Timestamp INSERT/UPDATE rules.
-- @step setup
CREATE TABLE t(id tinyint IDENTITY(254,1), value int);
CREATE TABLE p(v int);
CREATE TABLE d(id decimal(10,0) IDENTITY(1,1), v int);
CREATE TABLE r(id int, rv timestamp);
-- @step batch
INSERT t(value) VALUES(1),(2); SELECT 'after' AS a
-- @step batch
INSERT t(value) VALUES(3); SELECT 'not reached' AS a
-- @step batch
SELECT IDENT_CURRENT('t') AS c, SCOPE_IDENTITY() AS s
-- @step batch
BEGIN TRY INSERT t(value) VALUES(1) END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS n, ERROR_STATE() AS st END CATCH
-- @step batch
BEGIN TRAN; INSERT t(value) VALUES(1); SELECT 'not reached' AS a
-- @step batch
SELECT @@TRANCOUNT AS tc
-- @step batch
INSERT d(v) VALUES(1); SET IDENTITY_INSERT d ON; INSERT d(id, v) VALUES(50, 2); SET IDENTITY_INSERT d OFF; INSERT d(v) VALUES(3); SELECT IDENT_CURRENT('d') AS c, SCOPE_IDENTITY() AS s
-- @step batch
INSERT d(v) VALUES(9); INSERT p VALUES(1); SELECT SCOPE_IDENTITY() AS s, @@IDENTITY AS i
-- @step batch
INSERT d(v) VALUES(9); INSERT p SELECT 1 WHERE 1=0; SELECT SCOPE_IDENTITY() AS s, @@IDENTITY AS i
-- @step batch
INSERT d(v) VALUES(9); INSERT d(v) SELECT 1 WHERE 1=0; SELECT SCOPE_IDENTITY() AS s, @@IDENTITY AS i
-- @step batch
INSERT d(v) VALUES(9); DELETE p; UPDATE p SET v = 2; SELECT SCOPE_IDENTITY() AS s
-- @step batch
INSERT d(v) VALUES(9); SELECT 1 AS one INTO #x; SELECT SCOPE_IDENTITY() AS s, @@IDENTITY AS i
-- @step batch
INSERT d(v) VALUES(9); DECLARE @tv TABLE(a int); INSERT @tv VALUES(1); SELECT SCOPE_IDENTITY() AS s, @@IDENTITY AS i
-- @step batch
INSERT d(v) VALUES(9); EXEC('INSERT p VALUES(1)'); SELECT SCOPE_IDENTITY() AS s, @@IDENTITY AS i
-- @step batch
INSERT r VALUES(1, NULL); INSERT r VALUES(2, DEFAULT); INSERT r(id, rv) SELECT 3, NULL; SELECT id FROM r ORDER BY id
-- @step batch
INSERT r(id, rv) VALUES(4, CAST(0x01 AS binary(8)))
-- @step batch
INSERT r(id, rv) SELECT id, rv FROM r
-- @step batch
UPDATE r SET rv = NULL
-- @step batch
SET IDENTITY_INSERT d ON; SET IDENTITY_INSERT t ON
-- @step batch
SET IDENTITY_INSERT d OFF; SET IDENTITY_INSERT p OFF
-- @step batch
CREATE TABLE bad(id money IDENTITY, v int)
-- @step batch
CREATE TABLE bad2(id int IDENTITY NULL, v int)
-- @step batch
CREATE TABLE bad3(id int IDENTITY CONSTRAINT df_bad3 DEFAULT 1, v int)
-- @step batch
CREATE TABLE bad4(id int, a rowversion, b rowversion)

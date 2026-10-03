-- CREATE/DROP TYPE errors: duplicate (219), missing (218), unknown type
-- names (2715 + 2724, 243 in CAST), DROP of a type in use (3732), and a
-- user type name used as a table (208).
-- @step setup
CREATE TYPE dbo.IdList AS TABLE (id int NOT NULL PRIMARY KEY);
-- @step batch
CREATE TYPE dbo.IdList AS TABLE (x int);
-- @step batch
CREATE TYPE IdList FROM int;
-- @step batch
DROP TYPE dbo.Nope;
-- @step batch
DROP TYPE IF EXISTS dbo.Nope;
SELECT 1 AS ok;
-- @step batch
DECLARE @t dbo.NoSuch;
-- @step batch
DECLARE @t NoSuch;
-- @step batch
SELECT CAST(1 AS dbo.Nope);
-- @step batch
SELECT CAST(1 AS Nope);
-- @step batch
DECLARE @x int;
SELECT @x = 1 FROM dbo.IdList;
-- @step batch
CREATE PROCEDURE dbo.p @ids dbo.IdList READONLY AS SELECT COUNT(*) AS n FROM @ids;
-- @step batch
DROP TYPE dbo.IdList;
-- @step batch
DROP PROCEDURE dbo.p;
DROP TYPE dbo.IdList;
SELECT TYPE_ID('dbo.IdList');
-- @step batch
CREATE TYPE nope.T AS TABLE (x int);
-- @step batch
CREATE TABLE dbo.t (x dbo.IdList);
-- @step batch
CREATE TYPE dbo.T2 AS TABLE (x int, x int);
-- @step batch
CREATE TYPE dbo.T3 AS TABLE (x int PRIMARY KEY, y int PRIMARY KEY);

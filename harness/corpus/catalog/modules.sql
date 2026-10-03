-- CREATE/ALTER/DROP VIEW, PROCEDURE, FUNCTION, TRIGGER: completions (207,
-- 222, 221, 208, 223, 179, 225), sql_modules definitions (ALTER stored as
-- CREATE), and errors 2714 / 208 / 8197 / 4511.
-- @step setup
CREATE TABLE dbo.p (id int NOT NULL CONSTRAINT pk_p PRIMARY KEY, a int NULL);
-- @step batch
CREATE VIEW dbo.v AS SELECT id FROM dbo.p
-- @step batch
ALTER VIEW dbo.v AS SELECT id, a FROM dbo.p
-- @step batch
CREATE PROCEDURE dbo.pr AS SELECT 1 AS one
-- @step batch
ALTER PROCEDURE dbo.pr AS SELECT 2 AS two
-- @step batch
CREATE OR ALTER PROCEDURE dbo.pr AS SELECT 3 AS three
-- @step batch
CREATE FUNCTION dbo.f (@x int) RETURNS int AS BEGIN RETURN @x END
-- @step batch
ALTER FUNCTION dbo.f (@x int) RETURNS int AS BEGIN RETURN @x + 1 END
-- @step batch
CREATE FUNCTION dbo.tf (@x int) RETURNS TABLE AS RETURN SELECT @x AS x
-- @step batch
CREATE TRIGGER dbo.tr ON dbo.p AFTER INSERT AS SET NOCOUNT ON
-- @step batch
ALTER TRIGGER dbo.tr ON dbo.p AFTER INSERT, UPDATE AS SET NOCOUNT ON
-- @step batch
ALTER TABLE dbo.p DISABLE TRIGGER tr;
SELECT name, is_disabled FROM sys.triggers;
ALTER TABLE dbo.p ENABLE TRIGGER ALL;
SELECT name, is_disabled FROM sys.triggers;
-- @step batch
SELECT OBJECT_NAME(object_id) AS o, definition FROM sys.sql_modules ORDER BY 1;
SELECT name, type FROM sys.objects WHERE is_ms_shipped = 0 ORDER BY name;
-- @step batch
CREATE VIEW dbo.v AS SELECT 1 AS one
-- @step batch
CREATE VIEW dbo.p AS SELECT 1 AS one
-- @step batch
CREATE PROCEDURE dbo.v AS SELECT 1
-- @step batch
ALTER VIEW dbo.nosuch AS SELECT 1 AS one
-- @step batch
ALTER PROCEDURE dbo.nosuch AS SELECT 1
-- @step batch
CREATE TRIGGER dbo.tr2 ON dbo.nosuch AFTER INSERT AS SET NOCOUNT ON
-- @step batch
CREATE VIEW dbo.v2 AS SELECT 1
-- @step batch
DROP TRIGGER dbo.tr;
DROP FUNCTION dbo.f, dbo.tf;
DROP VIEW IF EXISTS dbo.v;
DROP VIEW IF EXISTS dbo.v;
DROP PROCEDURE dbo.pr;
SELECT name FROM sys.objects WHERE is_ms_shipped = 0 ORDER BY name;

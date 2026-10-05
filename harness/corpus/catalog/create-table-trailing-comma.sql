-- Trailing comma in CREATE TABLE element lists: one is accepted (after a
-- column, constraint or index), two or a leading one are 102; table variables,
-- table types, TVF return tables and ALTER TABLE ADD reject it.
-- @step batch
CREATE TABLE dbo.foo(id int,);
-- @step batch
CREATE TABLE dbo.bar(year int NOT NULL CONSTRAINT foo_year_unique UNIQUE(year), payload nvarchar(max) NOT NULL DEFAULT N'{}' CONSTRAINT foo_payload_json CHECK(ISJSON(payload)>0),);
INSERT INTO dbo.bar(year) VALUES (2020); SELECT * FROM dbo.bar;
-- @step batch
CREATE TABLE dbo.b2(id int,,);
-- @step batch
CREATE TABLE dbo.b3(id int, CONSTRAINT pk PRIMARY KEY(id),);
-- @step batch
DECLARE @t TABLE(id int,); INSERT @t VALUES(1); SELECT * FROM @t;
-- @step batch
CREATE TABLE #t(id int,); SELECT 1 FROM #t;
-- @step batch
CREATE TYPE dbo.tt AS TABLE(id int,);
-- @step batch
ALTER TABLE dbo.foo ADD x int,;
-- @step batch
CREATE FUNCTION dbo.f() RETURNS @r TABLE(id int,) AS BEGIN RETURN END;
-- @step batch
CREATE TABLE dbo.b4(id int, INDEX ix (id),);
-- @step batch
CREATE TABLE dbo.b5(id int,  -- comment
);
-- @step batch
CREATE TABLE dbo.b6(,id int);

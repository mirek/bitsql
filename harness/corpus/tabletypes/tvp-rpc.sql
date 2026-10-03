-- Table-valued parameters over TDS (TVP_TYPE 0xF3) as tedious sends
-- TYPES.TVP: sp_executesql (execSql) and procedure calls (callProcedure),
-- several column types, empty and NULL tables, schema-less type names,
-- a READONLY violation. (A duplicate key inside the TVP is 2627 naming a
-- random constraint name, so it is not captured here.)
-- @step setup
CREATE TYPE dbo.IdList AS TABLE (id int NOT NULL PRIMARY KEY, label nvarchar(10) NULL);
CREATE TYPE dbo.Mixed AS TABLE (b bigint NULL, d decimal(9, 2) NULL, s varchar(20) NULL, dt datetime2(3) NULL, g uniqueidentifier NULL, f bit NULL);
CREATE TABLE dbo.items (id int NOT NULL PRIMARY KEY, v nvarchar(10) NOT NULL);
INSERT INTO dbo.items VALUES (1, N'one'), (2, N'two'), (3, N'three');
-- @step setup
CREATE PROCEDURE dbo.pick @ids dbo.IdList READONLY AS
SELECT i.id, i.v, x.label FROM dbo.items i JOIN @ids x ON x.id = i.id ORDER BY i.id;
-- @step rpc
-- @param @ids table = {"schema":"dbo","name":"IdList","columns":[{"name":"id","type":"int"},{"name":"label","type":"nvarchar(10)"}],"rows":[[1,"a"],[3,null]]}
SELECT id, label FROM @ids ORDER BY id;
SELECT COUNT(*) AS n FROM @ids;
-- @step proc dbo.pick
-- @param @ids table = {"schema":"dbo","name":"IdList","columns":[{"name":"id","type":"int"},{"name":"label","type":"nvarchar(10)"}],"rows":[[2,"x"],[3,"y"]]}
-- @step proc dbo.pick
-- @param @ids table = {"schema":"dbo","name":"IdList","columns":[{"name":"id","type":"int"},{"name":"label","type":"nvarchar(10)"}],"rows":[]}
-- @step rpc
-- @param @ids table = {"name":"IdList","columns":[{"name":"id","type":"int"},{"name":"label","type":"nvarchar(10)"}],"rows":[[5,"z"]]}
SELECT id, label FROM @ids;
-- @step rpc
-- @param @m table = {"schema":"dbo","name":"Mixed","columns":[{"name":"b","type":"bigint"},{"name":"d","type":"decimal(9,2)"},{"name":"s","type":"varchar(20)"},{"name":"dt","type":"datetime2(3)"},{"name":"g","type":"uniqueidentifier"},{"name":"f","type":"bit"}],"rows":[["9007199254740993",12.5,"abc","2024-01-02T03:04:05.678Z","6F9619FF-8B86-D011-B42D-00C04FC964FF",true],[null,null,null,null,null,null]]}
SELECT b, d, s, dt, g, f FROM @m ORDER BY b;
-- @step rpc
-- @param @ids table = {"schema":"dbo","name":"IdList","columns":[{"name":"id","type":"int"},{"name":"label","type":"nvarchar(10)"}],"rows":[[1,"a"]]}
DELETE FROM @ids;
-- @step rpc
-- @param @ids table = {"schema":"dbo","name":"IdList","columns":[{"name":"id","type":"int"},{"name":"label","type":"nvarchar(10)"}],"rows":[[1,"a"]]}
-- @param @n int = 5
SELECT @n + COUNT(*) AS n FROM @ids;
-- @step rpc
-- @param @ids table = {"schema":"dbo","name":"IdList","columns":[{"name":"id","type":"bigint"},{"name":"label","type":"nvarchar(30)"}],"rows":[[7,"wide"]]}
SELECT id, label FROM @ids;

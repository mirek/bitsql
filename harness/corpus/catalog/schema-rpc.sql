-- CREATE / DROP SCHEMA completions in a batch and through RPC
-- (sp_executesql): CurCmd 253, no DONEINPROC in RPC.
-- @step batch
CREATE SCHEMA s1;
-- @step rpc
CREATE SCHEMA s2
-- @step batch
SELECT name FROM sys.schemas WHERE name IN ('s1', 's2') ORDER BY name;
DROP SCHEMA s1;
-- @step rpc
DROP SCHEMA s2
-- @step rpc
CREATE TABLE dbo.t (i int)
-- @step rpc
CREATE INDEX ix ON dbo.t (i)
-- @step rpc
ALTER TABLE dbo.t ADD j int

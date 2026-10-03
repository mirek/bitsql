-- sp_helpindex as Sequelize's showIndex calls it.
-- @step setup
CREATE TABLE dbo.people (id int NOT NULL CONSTRAINT pk_people PRIMARY KEY, email nvarchar(100) NOT NULL CONSTRAINT uq_people_email UNIQUE, last nvarchar(50), first nvarchar(50), age int);
CREATE INDEX ix_people_name ON dbo.people (last, first DESC);
CREATE UNIQUE INDEX ux_people_age ON dbo.people (age) WHERE age IS NOT NULL;
CREATE TABLE dbo.heap (a int);
-- @step batch
EXEC sys.sp_helpindex @objname = N'[dbo].[people]';
-- @step batch
EXEC sp_helpindex 'people';
-- @step batch
EXEC sp_helpindex 'heap';
-- @step batch
EXEC sp_helpindex 'nope';
-- @step rpc
EXEC sys.sp_helpindex @objname = N'people';

-- DDL error numbers, states and completions: 2714/1750, 1779, 4902, 4924,
-- 3728/3727, 5074/4922, 2705, 3725, 4917/4916, 4920, 1088, 1911, 1913,
-- 3723, 3701 (per object kind), 15151, 2759, 3729.
-- @step setup
CREATE TABLE dbo.a (id int NOT NULL CONSTRAINT pk_a PRIMARY KEY, x int NULL CONSTRAINT ck_a_x CHECK (x > 0), y int NULL CONSTRAINT df_a_y DEFAULT 1);
CREATE TABLE dbo.r (id int NOT NULL, aid int NULL CONSTRAINT fk_r_a REFERENCES dbo.a (id));
CREATE INDEX ix_a_y ON dbo.a (y) WHERE y IS NOT NULL;
-- @step batch
CREATE TABLE dbo.b (id int NOT NULL CONSTRAINT pk_a PRIMARY KEY);
-- @step batch
CREATE TABLE dbo.pk_a (id int);
-- @step batch
CREATE TABLE dbo.a (id int);
-- @step batch
ALTER TABLE dbo.a ADD CONSTRAINT pk_a2 PRIMARY KEY (x);
-- @step batch
ALTER TABLE dbo.nosuch ADD y int;
-- @step batch
ALTER TABLE dbo.a DROP COLUMN nosuch;
-- @step batch
ALTER TABLE dbo.a ALTER COLUMN nosuch int;
-- @step batch
ALTER TABLE dbo.a DROP CONSTRAINT nosuch;
-- @step batch
ALTER TABLE dbo.a DROP COLUMN id;
-- @step batch
ALTER TABLE dbo.a DROP COLUMN y;
-- @step batch
ALTER TABLE dbo.a DROP COLUMN x;
-- @step batch
ALTER TABLE dbo.a ALTER COLUMN x bigint;
-- @step batch
ALTER TABLE dbo.a ALTER COLUMN y bigint;
-- @step batch
ALTER TABLE dbo.a ADD x int;
-- @step batch
ALTER TABLE dbo.a DROP CONSTRAINT pk_a;
-- @step batch
ALTER TABLE dbo.a NOCHECK CONSTRAINT nosuch;
-- @step batch
ALTER TABLE dbo.a ENABLE TRIGGER nosuch;
-- @step batch
CREATE INDEX ix ON dbo.nosuch (x);
-- @step batch
CREATE INDEX ix ON dbo.a (nosuch);
-- @step batch
CREATE INDEX ix_a_y ON dbo.a (x);
-- @step batch
DROP INDEX pk_a ON dbo.a;
-- @step batch
DROP INDEX nosuch ON dbo.a;
-- @step batch
DROP TABLE dbo.nosuch;
-- @step batch
DROP VIEW dbo.nosuch;
-- @step batch
DROP PROCEDURE dbo.nosuch;
-- @step batch
DROP FUNCTION dbo.nosuch;
-- @step batch
DROP TRIGGER dbo.nosuch;
-- @step batch
DROP SCHEMA nosuch;
-- @step batch
DROP TABLE dbo.a;
-- @step batch
CREATE SCHEMA s1;
-- @step batch
CREATE SCHEMA s1;
-- @step batch
CREATE TABLE s1.t (i int);
-- @step batch
DROP SCHEMA s1;
-- @step batch
CREATE TABLE nosuch.t (i int);
-- @step batch
DROP TABLE s1.t;
DROP SCHEMA s1;
SELECT SCHEMA_ID('s1') AS s1;

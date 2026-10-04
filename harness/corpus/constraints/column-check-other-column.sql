-- A column-level CHECK may only name its own column: naming another one is
-- 8141 + 1750 for the whole batch (CREATE TABLE, temp tables, table
-- variables, ALTER TABLE ADD); an unknown name is 207 instead and a
-- subquery 1046. Two column CHECKs on one column are 8148. An ALTER of a
-- table created in the same batch compiles when it runs.
-- @step batch
SELECT 1 AS before;
CREATE TABLE dbo.ck1 (a int NULL, b int NULL CONSTRAINT ck_ck1 CHECK (a > 0));
SELECT 2 AS after;
-- @step batch
CREATE TABLE dbo.ck2 (a int NULL CHECK (a > 0 AND b > 0), b int NULL);
-- @step batch
CREATE TABLE dbo.ck3 (a int NULL CHECK (zz > 0));
-- @step batch
CREATE TABLE s.ck4 (a int NULL, b int CHECK (a > 0));
-- @step batch
CREATE TABLE #ck5 (a int NULL, b int CHECK (a > 0));
-- @step batch
DECLARE @t TABLE (a int NULL, b int CHECK (a > 0));
-- @step batch
SELECT 1;
CREATE TABLE
  dbo.ck7 (
  a int NULL,
  b int NULL
    CONSTRAINT ck_ck7 CHECK (A > 0));
-- @step batch
CREATE TABLE dbo.ck8 (a int NULL CHECK (a > 0 AND zz > 0 AND b > 0), b int NULL, c int CHECK (a > 1));
-- @step batch
CREATE TABLE dbo.ck9 (a int NULL CHECK (EXISTS (SELECT b FROM sys.objects)), b int NULL);
-- @step batch
CREATE TABLE dbo.ck10 (a int NULL CHECK (a > 0) CHECK (b > 0), b int NULL);
-- @step batch
CREATE TABLE dbo.ck6 (a int NULL);
ALTER TABLE dbo.ck6 ADD b int NULL CONSTRAINT ck_ck6 CHECK (a > 0);
-- @step batch
SELECT CASE WHEN OBJECT_ID('dbo.ck6') IS NULL THEN 0 ELSE 1 END AS created, @@TRANCOUNT AS tc;
-- @step batch
SELECT 1 AS x;
ALTER TABLE dbo.ck6 ADD c int NULL CONSTRAINT ck_ck6c CHECK (a > 0);
SELECT 2 AS y;
-- @step batch
ALTER TABLE dbo.ck6 ADD e int NULL CONSTRAINT ck_ck6e CHECK (e > 0), f int NULL CHECK (a > 0);
-- @step batch
CREATE TABLE dbo.ok (a int NULL CHECK (a > 0), b int NULL CONSTRAINT ck_ok CHECK (B < 10));
INSERT dbo.ok VALUES (1, 20);

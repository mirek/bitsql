-- sp_help: tables (columns, identity, rowguidcol, filegroup, indexes,
-- constraints incl. FK REFERENCES rows, referencing FKs), views,
-- procedures with parameters, alias and table types, a missing object.
-- Created_datetime reads the clock and is masked.
-- @step setup
CREATE TABLE dbo.parent (id int NOT NULL CONSTRAINT pk_parent PRIMARY KEY, name nvarchar(50) NULL);
CREATE TABLE dbo.child (cid int IDENTITY(1,1) NOT NULL CONSTRAINT pk_child PRIMARY KEY, pid int NOT NULL CONSTRAINT fk_child_parent REFERENCES dbo.parent(id), amount decimal(10,2) NULL CONSTRAINT df_amount DEFAULT 0, CONSTRAINT ck_amount CHECK (amount >= 0));
CREATE TABLE dbo.heap (a int, b varchar(10) COLLATE Latin1_General_BIN2, c nvarchar(max), d AS a + 1, e rowversion, f char(4) NOT NULL, g datetime2(3), h money);
-- @step setup
CREATE TABLE dbo.extra (a int NOT NULL, b int NOT NULL, c nvarchar(10) NULL, d int NULL CONSTRAINT ck_d CHECK NOT FOR REPLICATION (d > 0), e int NULL,
  CONSTRAINT pk_extra PRIMARY KEY NONCLUSTERED (a, b DESC),
  CONSTRAINT uq_extra_c UNIQUE (c),
  CONSTRAINT fk_extra_parent FOREIGN KEY (e) REFERENCES dbo.parent (id) ON DELETE CASCADE ON UPDATE SET NULL,
  CONSTRAINT ck_extra CHECK (a < b));
CREATE UNIQUE CLUSTERED INDEX cx_extra ON dbo.extra (e);
CREATE INDEX ix_extra_d ON dbo.extra (d) INCLUDE (c);
ALTER TABLE dbo.extra NOCHECK CONSTRAINT ck_extra;
-- @step setup
CREATE TABLE dbo.kinds (a bit, b tinyint, c smallint NOT NULL, d bigint, e real, f float, g smallmoney, h numeric(7,3), i date, j time(2), k datetime, l smalldatetime, m datetimeoffset(4), n uniqueidentifier, o binary(3) NOT NULL, p varbinary(max), q nchar(2), r sql_variant, s char(3) COLLATE Latin1_General_CS_AS, t varchar(20) NOT NULL, u decimal(38,10), v varbinary(16), w nvarchar(5) NOT NULL);
-- @step setup
CREATE VIEW dbo.v AS SELECT a, b FROM dbo.heap;
-- @step setup
CREATE PROCEDURE dbo.p1 @a int, @b nvarchar(20) = N'x' OUTPUT, @c decimal(5,2) = NULL, @d varchar(max), @e bigint, @f datetime2(3), @g bit, @h varbinary(10), @i uniqueidentifier, @j char(2), @k float, @l date AS SELECT @a AS a;
-- @step setup
CREATE PROCEDURE dbo.p0 AS SELECT 1 AS one;
-- @step setup
CREATE TYPE dbo.Email FROM nvarchar(256) NOT NULL;
CREATE TYPE dbo.Amount FROM decimal(12, 3) NULL;
CREATE TYPE dbo.IdList AS TABLE (id int);
-- @step batch
-- @mask sets/0/rows/*/3
EXEC sp_help 'dbo.child';
-- @step batch
-- @mask sets/0/rows/*/3
EXEC sp_help 'heap';
-- @step batch
-- @mask sets/0/rows/*/3
EXEC sp_help 'parent';
-- @step batch
-- @mask sets/0/rows/*/3
EXEC sp_help 'dbo.extra';
-- @step batch
-- @mask sets/0/rows/*/3
EXEC sp_help 'kinds';
-- @step batch
-- @mask sets/0/rows/*/3
EXEC sp_help 'dbo.v';
-- @step batch
-- @mask sets/0/rows/*/3
EXEC sp_help 'dbo.p1';
-- @step batch
-- @mask sets/0/rows/*/3
EXEC sp_help @objname = N'p0';
-- @step batch
EXEC sp_help 'dbo.Email';
EXEC sp_help 'Amount';
EXEC sp_help 'dbo.IdList';
-- @step batch
EXEC sp_help 'nothing';
-- @step rpc
-- @mask sets/0/rows/*/3
EXEC sp_help N'dbo.parent';

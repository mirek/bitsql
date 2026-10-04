-- What the non-default SET options change, for the record; bitsql raises
-- Emulator errors for these (bind/set_options.mbt,
-- session/set_options.mbt): ANSI_PADDING OFF columns drop trailing
-- blanks/zeros (nullable char too); CONCAT_NULL_YIELDS_NULL OFF makes
-- 'a' + NULL 'a'; QUOTED_IDENTIFIER OFF reads "x" as a string;
-- NUMERIC_ROUNDABORT ON makes rounding 8115 state 7; XML methods and DML
-- on filtered indexes need the default options (1934, batch ends).
-- @step setup
CREATE TABLE dbo.f(id int, a int NULL); CREATE UNIQUE INDEX ix_f ON dbo.f(a) WHERE a IS NOT NULL;
-- @step batch
SET ANSI_PADDING OFF; CREATE TABLE dbo.pad(c char(5) NULL, v varchar(5), b varbinary(5), cn char(5) NOT NULL, n nvarchar(5)); SET ANSI_PADDING ON;
INSERT dbo.pad VALUES ('a ', 'a  ', 0x0100, 'b ', N'n  '); SELECT DATALENGTH(c), DATALENGTH(v), DATALENGTH(b), DATALENGTH(cn), DATALENGTH(n), c + '|' FROM dbo.pad;
SELECT name, is_ansi_padded FROM sys.columns WHERE object_id = OBJECT_ID('dbo.pad') ORDER BY column_id
-- @step batch
SET CONCAT_NULL_YIELDS_NULL OFF; SELECT 'a' + NULL, NULL + 'b', N'x' + NULL, 'a' + CAST(NULL AS varchar(5)); SET CONCAT_NULL_YIELDS_NULL ON
-- @step batch
SET QUOTED_IDENTIFIER OFF; SELECT "abc", "it""s"; SET QUOTED_IDENTIFIER ON
-- @step batch
SET NUMERIC_ROUNDABORT ON; SELECT CAST(1.25 AS decimal(3,1)); SET NUMERIC_ROUNDABORT OFF
-- @step batch
SET NUMERIC_ROUNDABORT OFF
-- @step batch
SET ANSI_PADDING OFF; DECLARE @x xml = '<a>1</a>'; SELECT @x.value('(/a)[1]', 'int'); SET ANSI_PADDING ON
-- @step batch
SET ANSI_PADDING ON
-- @step batch
SET CONCAT_NULL_YIELDS_NULL OFF; INSERT dbo.f VALUES (1, 1); SET CONCAT_NULL_YIELDS_NULL ON
-- @step batch
SET CONCAT_NULL_YIELDS_NULL ON; SELECT id, a FROM dbo.f

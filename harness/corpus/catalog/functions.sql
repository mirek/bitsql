-- Catalog/metadata functions: result types and values, including temp
-- tables through tempdb.., IDENT_* and missing objects.
-- @step setup
CREATE TABLE dbo.t (id int IDENTITY(10,5) NOT NULL CONSTRAINT pk_t PRIMARY KEY, n nvarchar(20) NULL, d decimal(9,2) NULL, c AS id + 1);
CREATE INDEX ix ON dbo.t (n);
INSERT INTO dbo.t (n) VALUES (N'a');
CREATE TABLE dbo.e (id int IDENTITY(3,7) NOT NULL);
-- @step batch
SELECT OBJECT_NAME(OBJECT_ID('t')) AS b, OBJECT_SCHEMA_NAME(OBJECT_ID('t')) AS c, SCHEMA_ID('dbo') AS d, SCHEMA_NAME(1) AS e,
 COL_LENGTH('t','n') AS f, COL_NAME(OBJECT_ID('t'), 2) AS g, COLUMNPROPERTY(OBJECT_ID('t'), 'id', 'IsIdentity') AS h,
 OBJECTPROPERTY(OBJECT_ID('t'), 'IsUserTable') AS i, TYPE_ID('int') AS j, TYPE_NAME(56) AS k, DB_NAME(3) AS m,
 IDENT_CURRENT('t') AS n, IDENT_SEED('t') AS o, IDENT_INCR('t') AS p, INDEXPROPERTY(OBJECT_ID('t'), 'ix', 'IsUnique') AS q,
 OBJECT_ID(NULL) AS s, OBJECT_NAME(NULL) AS t2, SCHEMA_NAME() AS u, SCHEMA_ID() AS v,
 DB_ID('master') AS w, HAS_PERMS_BY_NAME('t', 'OBJECT', 'SELECT') AS y,
 OBJECT_DEFINITION(OBJECT_ID('t')) AS z, IDENT_CURRENT('nosuch') AS aa, COL_LENGTH('t', 'd') AS ab, COLUMNPROPERTY(OBJECT_ID('t'), 'n', 'Precision') AS ac,
 IDENT_CURRENT('dbo.e') AS ad;
SELECT COLUMNPROPERTY(OBJECT_ID('t'), 'c', 'IsComputed') AS a, COLUMNPROPERTY(OBJECT_ID('t'), 'n', 'AllowsNull') AS b, COLUMNPROPERTY(OBJECT_ID('t'), 'id', 'AllowsNull') AS c, COLUMNPROPERTY(OBJECT_ID('t'), 'n', 'ColumnId') AS d, COLUMNPROPERTY(OBJECT_ID('t'), 'd', 'Scale') AS e, COLUMNPROPERTY(OBJECT_ID('t'), 'nosuch', 'AllowsNull') AS f, COLUMNPROPERTY(OBJECT_ID('t'), 'id', 'bogus') AS g;
SELECT OBJECTPROPERTY(OBJECT_ID('t'), 'IsTable') AS a, OBJECTPROPERTY(OBJECT_ID('t'), 'IsView') AS b, OBJECTPROPERTY(OBJECT_ID('t'), 'IsProcedure') AS c, OBJECTPROPERTY(OBJECT_ID('t'), 'TableHasIdentity') AS d, OBJECTPROPERTY(OBJECT_ID('t'), 'TableHasPrimaryKey') AS e, OBJECTPROPERTY(OBJECT_ID('t'), 'OwnerId') AS f, OBJECTPROPERTY(OBJECT_ID('t'), 'SchemaId') AS g, OBJECTPROPERTY(OBJECT_ID('t'), 'IsMSShipped') AS h, OBJECTPROPERTY(OBJECT_ID('t'), 'bogus') AS i, OBJECTPROPERTY(12345, 'IsTable') AS j, OBJECTPROPERTY(OBJECT_ID('t'), 'IsPrimaryKey') AS k, OBJECTPROPERTY(OBJECT_ID('t'), 'IsConstraint') AS l, OBJECTPROPERTY(OBJECT_ID('pk_t'), 'IsConstraint') AS m;
SELECT INDEXPROPERTY(OBJECT_ID('t'), 'ix', 'IsClustered') AS a, INDEXPROPERTY(OBJECT_ID('t'), 'ix', 'IndexID') AS b, INDEXPROPERTY(OBJECT_ID('t'), 'nosuch', 'IsUnique') AS c, INDEXPROPERTY(OBJECT_ID('t'), 'ix', 'IsDisabled') AS d;
SELECT CASE WHEN OBJECT_ID('dbo.t') = OBJECT_ID('[dbo].[t]') THEN 1 ELSE 0 END AS a, OBJECT_ID('tempdb..#nosuch') AS b, OBJECT_ID('x.y.z.t') AS c, CASE WHEN OBJECT_ID('t', 'U ') = OBJECT_ID('t') THEN 1 ELSE 0 END AS d, OBJECT_ID('t', 'P') AS e, OBJECT_ID(' t') AS f, CASE WHEN OBJECT_ID('T') = OBJECT_ID('t') THEN 1 ELSE 0 END AS g, CASE WHEN OBJECT_ID('pk_t', 'PK') IS NOT NULL THEN 1 ELSE 0 END AS h;
CREATE TABLE #tmp (i int);
SELECT CASE WHEN OBJECT_ID('tempdb..#tmp') IS NOT NULL THEN 1 ELSE 0 END AS a, CASE WHEN OBJECT_ID('tempdb.dbo.#tmp') IS NOT NULL THEN 1 ELSE 0 END AS b, CASE WHEN OBJECT_ID('#tmp') IS NOT NULL THEN 1 ELSE 0 END AS c, CASE WHEN OBJECT_ID('tempdb..#tmp', 'U') IS NOT NULL THEN 1 ELSE 0 END AS d, COL_LENGTH('tempdb..#tmp', 'i') AS e;
IF OBJECT_ID('tempdb..#tmp') IS NOT NULL DROP TABLE #tmp;
SELECT OBJECT_ID('tempdb..#tmp') AS gone;
SELECT TYPE_NAME(9999) AS a, SCHEMA_NAME(999) AS b, DB_NAME(999) AS c, COL_NAME(OBJECT_ID('t'), 99) AS d, OBJECT_SCHEMA_NAME(999) AS e, COL_LENGTH('t', 'id') AS f, COL_LENGTH('t', 'c') AS g;

-- Inline INDEX options in CREATE TABLE: UNIQUE (enforced), CLUSTERED (wins
-- over a default-clustered PRIMARY KEY, which becomes nonclustered), INCLUDE,
-- WHERE (filtered, also UNIQUE), WITH options, and the two-clustered error.
-- @step batch
CREATE TABLE dbo.u(id int, v int, INDEX ix UNIQUE NONCLUSTERED (v));
INSERT dbo.u VALUES (1, 1);
INSERT dbo.u VALUES (2, 1);
SELECT name, index_id, type_desc, is_unique FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.u') ORDER BY index_id;
-- @step batch
CREATE TABLE dbo.a(id int PRIMARY KEY, v int, INDEX ix CLUSTERED (v));
SELECT LEFT(name, 6) AS name, index_id, type_desc, is_primary_key FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.a') ORDER BY index_id;
-- @step batch
CREATE TABLE dbo.a2(v int, INDEX ix CLUSTERED (v), id int PRIMARY KEY);
SELECT LEFT(name, 6) AS name, index_id, type_desc, is_primary_key FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.a2') ORDER BY index_id;
-- @step batch
CREATE TABLE dbo.a3(id int PRIMARY KEY NONCLUSTERED, v int, INDEX ix CLUSTERED (v));
SELECT LEFT(name, 6) AS name, index_id, type_desc FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.a3') ORDER BY index_id;
-- @step batch
CREATE TABLE dbo.a4(id int, v int, INDEX ix1 CLUSTERED (v), INDEX ix2 CLUSTERED (id));
-- @step batch
CREATE TABLE dbo.a6(id int PRIMARY KEY CLUSTERED, v int, INDEX ix CLUSTERED (v));
-- @step batch
CREATE TABLE dbo.a5(id int, v int, w int, INDEX ixu UNIQUE (v), INDEX ixf UNIQUE (w) WHERE w > 0, INDEX ixi NONCLUSTERED (id) INCLUDE (w) WITH (FILLFACTOR = 80));
SELECT name, index_id, is_unique, has_filter, filter_definition, fill_factor FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.a5') ORDER BY index_id;
SELECT i.name, ic.column_id, ic.key_ordinal, ic.is_included_column FROM sys.index_columns AS ic JOIN sys.indexes AS i ON i.object_id = ic.object_id AND i.index_id = ic.index_id WHERE ic.object_id = OBJECT_ID(N'dbo.a5') ORDER BY i.index_id, ic.index_column_id;
INSERT dbo.a5 VALUES (1, 1, 0), (2, 2, 0);
INSERT dbo.a5 VALUES (3, 3, 5), (4, 4, 5);
-- @step batch
CREATE TABLE dbo.a7(id int, v int, INDEX ixf (v) WHERE v IS NOT NULL);
INSERT dbo.a7 VALUES (1, NULL), (2, 3);
SELECT p.rows FROM sys.partitions AS p JOIN sys.indexes AS i ON i.object_id = p.object_id AND i.index_id = p.index_id WHERE i.name = N'ixf' ORDER BY p.rows;
-- @step batch
DECLARE @t TABLE (id int, v int, INDEX ix UNIQUE (v));
INSERT @t VALUES (1, 1), (2, 1);

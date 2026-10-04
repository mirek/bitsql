-- DEFAULT NULL / DEFAULT (NULL) is the untyped NULL constant: it is
-- assignable to every column type (date, datetimeoffset, time, guid, xml…)
-- on every path that applies a default (omitted column, DEFAULT VALUES,
-- INSERT…SELECT, UPDATE SET c = DEFAULT, MERGE, ALTER ADD … WITH VALUES,
-- ON DELETE SET DEFAULT). A typed int NULL default still fails (529).
-- @step batch
CREATE TABLE dbo.items (
  id int NULL,
  d date NULL DEFAULT NULL,
  dto datetimeoffset NULL DEFAULT (NULL),
  d2 datetime2 NULL CONSTRAINT df_d2 DEFAULT ((NULL)),
  t time NULL DEFAULT (NULL),
  g uniqueidentifier NULL DEFAULT NULL,
  x xml NULL DEFAULT (NULL),
  vb varbinary(100) NULL DEFAULT (NULL),
  b bit NULL DEFAULT NULL,
  sv sql_variant NULL DEFAULT (NULL)
);
INSERT dbo.items (id) VALUES (1);
INSERT dbo.items (id) SELECT s.id FROM (VALUES (2)) s (id);
INSERT dbo.items DEFAULT VALUES;
SELECT id, d, dto, d2, t, g, CAST(x AS nvarchar(10)) AS x, vb, b, sv FROM dbo.items ORDER BY id;
-- @step batch
UPDATE dbo.items SET d = '2020-01-02', g = NEWID() WHERE id = 1;
UPDATE dbo.items SET d = DEFAULT, g = DEFAULT WHERE id = 1;
MERGE dbo.items AS t USING (VALUES (3)) AS s (id) ON t.id = s.id
WHEN NOT MATCHED THEN INSERT (id) VALUES (s.id);
SELECT id, d, g FROM dbo.items ORDER BY id;
-- @step batch
ALTER TABLE dbo.items ADD extra date NULL CONSTRAINT df_extra DEFAULT (NULL) WITH VALUES;
-- @step batch
SELECT id, extra FROM dbo.items ORDER BY id;
-- @step batch
CREATE TABLE dbo.parent (id int PRIMARY KEY);
CREATE TABLE dbo.child (
  id int PRIMARY KEY,
  p int NULL CONSTRAINT df_child_p DEFAULT (NULL)
    CONSTRAINT fk_child_p REFERENCES dbo.parent (id) ON DELETE SET DEFAULT,
  at date NULL DEFAULT (NULL)
);
INSERT dbo.parent VALUES (1);
INSERT dbo.child (id, p) VALUES (1, 1);
DELETE dbo.parent;
SELECT id, p, at FROM dbo.child;
-- @step batch
CREATE TABLE dbo.typed (id int, d date NULL DEFAULT (CAST(NULL AS int)));
-- @step batch
INSERT dbo.typed (id) VALUES (1);
-- @step batch
CREATE TABLE dbo.neg (id int, d date NULL DEFAULT (-NULL));
INSERT dbo.neg (id) VALUES (1);
SELECT id, d FROM dbo.neg;
-- @step batch
CREATE TABLE dbo.xtyped (id int, x xml NULL DEFAULT (CAST(NULL AS int)));

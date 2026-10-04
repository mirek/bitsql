-- A column definition may carry FOREIGN KEY with its own column list
-- (`v int CONSTRAINT fk FOREIGN KEY (v) REFERENCES p (v)`): it binds the
-- listed column, even another one or one declared later; more than one is
-- compile error 8140, an unknown one 1769 + 1750.
-- @step setup
CREATE TABLE dbo.parent (value int PRIMARY KEY, v2 int NOT NULL, CONSTRAINT uq_p UNIQUE (value, v2));
INSERT dbo.parent VALUES (1, 10), (2, 20);
-- @step batch
CREATE TABLE dbo.items (
  value int NOT NULL
    CONSTRAINT fk_foo FOREIGN KEY(value) REFERENCES dbo.parent(value)
    ON DELETE CASCADE ON UPDATE CASCADE
);
INSERT dbo.items VALUES (1), (2);
DELETE dbo.parent WHERE value = 2;
SELECT value FROM dbo.items;
SELECT f.name, COL_NAME(c.parent_object_id, c.parent_column_id) AS col, f.delete_referential_action_desc FROM sys.foreign_keys f JOIN sys.foreign_key_columns c ON c.constraint_object_id = f.object_id WHERE f.name = 'fk_foo';
-- @step batch
CREATE TABLE dbo.other (
  a int NULL,
  b int NULL CONSTRAINT fk_other FOREIGN KEY (a) REFERENCES dbo.parent (value)
);
SELECT COL_NAME(c.parent_object_id, c.parent_column_id) AS col FROM sys.foreign_key_columns c WHERE OBJECT_NAME(c.constraint_object_id) = 'fk_other';
-- @step batch
CREATE TABLE dbo.multi (
  a int NULL,
  b int NULL CONSTRAINT fk_multi FOREIGN KEY (a, b) REFERENCES dbo.parent (value, v2)
);
SELECT COL_NAME(c.parent_object_id, c.parent_column_id) AS col FROM sys.foreign_key_columns c WHERE OBJECT_NAME(c.constraint_object_id) = 'fk_multi' ORDER BY c.constraint_column_id;
-- @step batch
CREATE TABLE dbo.unnamed (a int NULL FOREIGN KEY (a) REFERENCES dbo.parent (value));
SELECT COUNT(*) FROM sys.foreign_keys WHERE parent_object_id = OBJECT_ID('dbo.unnamed');
-- @step batch
CREATE TABLE dbo.pk1 (a int NOT NULL CONSTRAINT pk_pk1 PRIMARY KEY (a));
-- @step batch
CREATE TABLE dbo.pk2 (a int NOT NULL, b int NOT NULL CONSTRAINT pk_pk2 PRIMARY KEY (a, b));
SELECT COL_NAME(ic.object_id, ic.column_id) FROM sys.index_columns ic WHERE ic.object_id = OBJECT_ID('dbo.pk2') ORDER BY ic.key_ordinal;
-- @step batch
CREATE TABLE dbo.uq1 (a int NULL, b int NULL CONSTRAINT uq_uq1 UNIQUE (a));
-- @step batch
CREATE TABLE dbo.bad (a int NULL CONSTRAINT fk_bad FOREIGN KEY (zz) REFERENCES dbo.parent (value));
-- @step batch
SELECT 1 AS before;
CREATE TABLE dbo.multi3 (a int NULL, b int NULL CONSTRAINT fk_multi3 FOREIGN KEY (a, b) REFERENCES dbo.parent (value, v2));
SELECT 2 AS after;
-- @step batch
CREATE TABLE dbo.late (a int NULL CONSTRAINT fk_late FOREIGN KEY (b) REFERENCES dbo.parent (value), b int NULL);
SELECT COL_NAME(c.parent_object_id, c.parent_column_id) AS col FROM sys.foreign_key_columns c WHERE OBJECT_NAME(c.constraint_object_id) = 'fk_late';
-- @step batch
CREATE TABLE dbo.fk7 (a int NULL);
ALTER TABLE dbo.fk7 ADD b int NULL CONSTRAINT fk_fk7 FOREIGN KEY (a) REFERENCES dbo.parent (value);
SELECT COL_NAME(c.parent_object_id, c.parent_column_id) AS col FROM sys.foreign_key_columns c WHERE OBJECT_NAME(c.constraint_object_id) = 'fk_fk7';
-- @step batch
SELECT 1;
CREATE TABLE
  multi4 (
  a int NULL,
  b int NULL
    CONSTRAINT fk_multi4 FOREIGN KEY (a, b) REFERENCES dbo.parent (value, v2));

-- Index and constraint catalog rows (named constraints; ids compared via
-- OBJECT_NAME / COL_NAME only).
-- @step setup
CREATE TABLE dbo.p (id int NOT NULL CONSTRAINT pk_p PRIMARY KEY, a int NULL, b int NULL, CONSTRAINT uq_p_ab UNIQUE (a, b));
CREATE TABLE dbo.c (id int NOT NULL, pa int NULL, pb int NULL, v int NULL CONSTRAINT df_c_v DEFAULT (5) CONSTRAINT ck_c_v CHECK (v > 0),
  CONSTRAINT fk_c_p FOREIGN KEY (pa, pb) REFERENCES dbo.p (a, b) ON UPDATE SET NULL,
  CONSTRAINT fk_c_id FOREIGN KEY (id) REFERENCES dbo.p (id),
  CONSTRAINT ck_c_t CHECK (pa IS NULL OR pb IS NOT NULL));
CREATE INDEX ix_c_v ON dbo.c (v DESC, pa) INCLUDE (pb) WHERE v IS NOT NULL;
CREATE UNIQUE CLUSTERED INDEX cx_c ON dbo.c (id);
-- @step batch
SELECT OBJECT_NAME(object_id) AS t, name, index_id, type, type_desc, is_unique, data_space_id, ignore_dup_key, is_primary_key, is_unique_constraint, fill_factor, is_padded, is_disabled, is_hypothetical, allow_row_locks, allow_page_locks, has_filter, filter_definition FROM sys.indexes WHERE object_id IN (OBJECT_ID('dbo.p'), OBJECT_ID('dbo.c')) ORDER BY 1, index_id;
SELECT OBJECT_NAME(object_id) AS t, index_id, index_column_id, COL_NAME(object_id, column_id) AS col, key_ordinal, partition_ordinal, is_descending_key, is_included_column FROM sys.index_columns WHERE object_id IN (OBJECT_ID('dbo.p'), OBJECT_ID('dbo.c')) ORDER BY 1, index_id, index_column_id;
SELECT name, type, type_desc, OBJECT_NAME(parent_object_id) AS t, unique_index_id, is_system_named, is_enforced FROM sys.key_constraints ORDER BY name;
SELECT name, OBJECT_NAME(parent_object_id) AS t, OBJECT_NAME(referenced_object_id) AS r, key_index_id, is_disabled, is_not_for_replication, is_not_trusted, delete_referential_action, delete_referential_action_desc, update_referential_action, update_referential_action_desc, is_system_named FROM sys.foreign_keys ORDER BY name;
SELECT OBJECT_NAME(constraint_object_id) AS fk, constraint_column_id, COL_NAME(parent_object_id, parent_column_id) AS pc, COL_NAME(referenced_object_id, referenced_column_id) AS rc FROM sys.foreign_key_columns ORDER BY 1, 2;
SELECT name, OBJECT_NAME(parent_object_id) AS t, is_disabled, is_not_for_replication, is_not_trusted, parent_column_id, definition, uses_database_collation, is_system_named FROM sys.check_constraints ORDER BY name;
SELECT name, OBJECT_NAME(parent_object_id) AS t, parent_column_id, definition, is_system_named FROM sys.default_constraints ORDER BY name;
SELECT * FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS ORDER BY CONSTRAINT_NAME;
SELECT * FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE ORDER BY CONSTRAINT_NAME, ORDINAL_POSITION;
SELECT * FROM INFORMATION_SCHEMA.REFERENTIAL_CONSTRAINTS ORDER BY CONSTRAINT_NAME;
SELECT INDEXPROPERTY(OBJECT_ID('dbo.c'), 'cx_c', 'IsClustered') AS a, INDEXPROPERTY(OBJECT_ID('dbo.c'), 'ix_c_v', 'IsUnique') AS b, INDEXPROPERTY(OBJECT_ID('dbo.c'), 'ix_c_v', 'IndexID') AS c, INDEXPROPERTY(OBJECT_ID('dbo.c'), 'nosuch', 'IsUnique') AS d;

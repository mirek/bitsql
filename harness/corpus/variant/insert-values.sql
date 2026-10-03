-- Implicit conversion into sql_variant columns: a multi-row VALUES list
-- converts every row to the common type of its column first, so the stored
-- base types are the unified type (or the statement fails with 206/245);
-- INSERT ... SELECT and UPDATE keep the source type; DEFAULTs.
-- @step setup
CREATE TABLE dbo.t (id int NOT NULL PRIMARY KEY, v sql_variant NULL, d sql_variant NULL CONSTRAINT df_t_d DEFAULT (N'dflt'));
-- @step batch
INSERT INTO dbo.t (id, v) VALUES (1, 1), (2, 2.5);
INSERT INTO dbo.t (id, v) VALUES (3, 'abc');
INSERT INTO dbo.t (id, v) VALUES (4, N'x'), (5, NULL);
INSERT INTO dbo.t (id, v) SELECT 6, CAST(1 AS tinyint) UNION ALL SELECT 7, 300;
INSERT INTO dbo.t (id, v) SELECT 15, CAST(CAST('2024-01-01' AS date) AS sql_variant) UNION ALL SELECT 16, CAST(CAST(2 AS tinyint) AS sql_variant);
INSERT INTO dbo.t (id, v, d) VALUES (8, CAST(1 AS bit), DEFAULT);
INSERT INTO dbo.t (id, v) VALUES (9, CAST(1 AS sql_variant)), (10, N'mixed');
SELECT id, v, SQL_VARIANT_PROPERTY(v, 'BaseType') AS bt, SQL_VARIANT_PROPERTY(v, 'Precision') AS p,
       SQL_VARIANT_PROPERTY(v, 'Scale') AS s, SQL_VARIANT_PROPERTY(v, 'MaxLength') AS ml, d
FROM dbo.t ORDER BY id;
-- @step batch
INSERT INTO dbo.t (id, v) VALUES (11, 1), (12, 'abc');
-- @step batch
INSERT INTO dbo.t (id, v) VALUES (13, 1), (14, CAST('2024-01-01' AS date));
-- @step batch
UPDATE dbo.t SET v = CAST(5 AS smallint) WHERE id = 1;
UPDATE dbo.t SET v = d WHERE id = 2;
SELECT id, v, SQL_VARIANT_PROPERTY(v, 'BaseType') AS bt FROM dbo.t WHERE id IN (1, 2) ORDER BY id;
SELECT COUNT(*) AS n FROM dbo.t;

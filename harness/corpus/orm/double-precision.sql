-- Sequelize's DataTypes.DOUBLE creates columns as DOUBLE PRECISION, the ISO
-- synonym of float(53) (sequelize sync failed with 2715 on the emulator).
-- @step batch
CREATE TABLE t (id int NOT NULL, d DOUBLE PRECISION NULL, f float NULL);
INSERT INTO t VALUES (1, 2.5, 0.1);
SELECT id, d, f FROM t;
SELECT c.name, TYPE_NAME(c.system_type_id) AS type_name, c.max_length, c.precision, c.scale
FROM sys.columns c WHERE c.object_id = OBJECT_ID('t') ORDER BY c.column_id;
SELECT CAST(1.5 AS double precision) AS x;
DECLARE @v DOUBLE PRECISION = 3.25;
SELECT @v AS v;

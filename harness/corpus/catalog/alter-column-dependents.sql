-- Which dependents block ALTER COLUMN, and the order SQL Server lists them
-- in (5074 per dependent, then 4922): defaults, computed columns, filtered
-- index predicates, check constraints, then index/key columns in index
-- order, then foreign keys. Computed columns block every ALTER COLUMN;
-- a CHECK only another type or collation; a DEFAULT only another type;
-- index keys and INCLUDE columns NULL to NOT NULL, another type, a new
-- collation or precision, or a shorter length; foreign keys any type change.
-- @step setup
CREATE TABLE dp_all (id int, value int CONSTRAINT df_dp_all DEFAULT 1, CONSTRAINT uq_dp_all UNIQUE (value), CONSTRAINT ck_dp_all CHECK (value > 0));
CREATE TABLE dp_child (v int CONSTRAINT fk_dp_child REFERENCES dp_all (value));
CREATE INDEX ix_dp_all_f ON dp_all (id) WHERE value > 0;
CREATE INDEX ix_dp_all_k ON dp_all (value);
ALTER TABLE dp_all ADD c AS value + 1;
CREATE TABLE dp_ord (value int, CONSTRAINT ck_dp_ord_b CHECK (value > 0), CONSTRAINT ck_dp_ord_a CHECK (value < 9), c2 AS value * 2, c1 AS value + 1);
CREATE TABLE dp_comp (value nvarchar(100) NOT NULL, c AS UPPER(value));
CREATE TABLE dp_ck (value nvarchar(100), d decimal(10,2), CONSTRAINT ck_dp_ck CHECK (value <> N''), CONSTRAINT ck_dp_ck_d CHECK (d > 0));
CREATE TABLE dp_ix (id int, value int NULL, s nvarchar(100) NULL, d decimal(10,2) NULL);
CREATE INDEX ix_dp_ix_i ON dp_ix (id) INCLUDE (value);
CREATE INDEX ix_dp_ix_s ON dp_ix (s);
CREATE INDEX ix_dp_ix_d ON dp_ix (d);
CREATE TABLE dp_uq (value int NULL, w int NOT NULL, CONSTRAINT uq_dp_uq UNIQUE (value), CONSTRAINT uq_dp_uq_w UNIQUE (w));
CREATE TABLE dp_pk (id int NOT NULL CONSTRAINT pk_dp_pk PRIMARY KEY);
CREATE TABLE dp_ref (pid int NULL CONSTRAINT fk_dp_ref REFERENCES dp_pk (id));
-- @step batch
ALTER TABLE dp_all ALTER COLUMN value bigint NULL;
-- @step batch
ALTER TABLE dp_all ALTER COLUMN value int NOT NULL;
-- @step batch
ALTER TABLE dp_all DROP COLUMN value;
-- @step batch
ALTER TABLE dp_ord ALTER COLUMN value bigint NULL;
-- @step batch
ALTER TABLE dp_comp ALTER COLUMN value nvarchar(100) NOT NULL;
-- @step batch
ALTER TABLE dp_comp ALTER COLUMN value nvarchar(200) NOT NULL;
-- @step batch
ALTER TABLE dp_ck ALTER COLUMN value nvarchar(200) NULL;
-- @step batch
ALTER TABLE dp_ck ALTER COLUMN value nvarchar(50) NOT NULL;
-- @step batch
ALTER TABLE dp_ck ALTER COLUMN value nvarchar(50) COLLATE Latin1_General_BIN2 NULL;
-- @step batch
ALTER TABLE dp_ck ALTER COLUMN d decimal(12,2) NULL;
-- @step batch
ALTER TABLE dp_ck ALTER COLUMN d int NULL;
-- @step batch
ALTER TABLE dp_ix ALTER COLUMN value int NOT NULL;
-- @step batch
ALTER TABLE dp_ix ALTER COLUMN s nvarchar(100) NOT NULL;
-- @step batch
ALTER TABLE dp_ix ALTER COLUMN s nvarchar(200) NOT NULL;
-- @step batch
ALTER TABLE dp_ix ALTER COLUMN s nvarchar(100) COLLATE Latin1_General_BIN2 NULL;
-- @step batch
ALTER TABLE dp_ix ALTER COLUMN s nvarchar(max) NULL;
-- @step batch
ALTER TABLE dp_ix ALTER COLUMN d decimal(12,2) NULL;
-- @step batch
ALTER TABLE dp_ix ALTER COLUMN s nvarchar(300) NULL;
-- @step batch
ALTER TABLE dp_uq ALTER COLUMN value int NOT NULL;
-- @step batch
ALTER TABLE dp_uq ALTER COLUMN w int NULL;
-- @step batch
ALTER TABLE dp_pk ALTER COLUMN id int NULL;
-- @step batch
ALTER TABLE dp_ref ALTER COLUMN pid int NOT NULL;
-- @step batch
ALTER TABLE dp_ref ALTER COLUMN pid bigint NOT NULL;
-- @step batch
ALTER TABLE dp_pk ALTER COLUMN id bigint NOT NULL;
-- @step batch
SELECT OBJECT_NAME(c.object_id) AS tbl, c.name, TYPE_NAME(c.system_type_id) AS t, c.max_length, c.precision, c.scale, c.is_nullable, c.collation_name
FROM sys.columns c WHERE OBJECT_NAME(c.object_id) LIKE 'dp[_]%' ORDER BY tbl, c.column_id;

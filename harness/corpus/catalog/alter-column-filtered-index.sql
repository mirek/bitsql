-- ALTER COLUMN on a column named in a filtered index predicate is always
-- 5074 + 4922, even when it only widens the column, changes nullability or
-- changes nothing; the same ALTER under an ordinary index succeeds (external
-- compatibility report). A column that is both a key and in the filter is
-- listed twice when the key also blocks the change (narrowing, another type,
-- NULL to NOT NULL, collation). Filters naming other columns do not block.
-- @step setup
CREATE TABLE fi_items (value nvarchar(100));
CREATE INDEX ix_fi_items ON fi_items (value) WHERE value IS NOT NULL;
CREATE TABLE fi_plain (value nvarchar(100));
CREATE INDEX ix_fi_plain ON fi_plain (value);
CREATE TABLE fi_pred (id int, value nvarchar(100));
CREATE INDEX ix_fi_pred ON fi_pred (id) WHERE value IS NOT NULL;
CREATE TABLE fi_incl (id int, value nvarchar(100));
CREATE INDEX ix_fi_incl ON fi_incl (id) INCLUDE (value) WHERE value IS NOT NULL;
CREATE TABLE fi_other (id int, value nvarchar(100));
CREATE INDEX ix_fi_other ON fi_other (value) WHERE id > 0;
CREATE INDEX ix_fi_other2 ON fi_other (id) INCLUDE (value) WHERE id > 0;
CREATE TABLE fi_int (id int, value int);
CREATE INDEX ix_fi_int_a ON fi_int (id) WHERE value > 0;
CREATE INDEX ix_fi_int_b ON fi_int (id) WHERE value < 0;
CREATE INDEX ix_fi_int_c ON fi_int (value) WHERE value < 9;
CREATE UNIQUE INDEX ux_fi_int ON fi_int (id) WHERE value IS NOT NULL AND id > 0;
CREATE TABLE fi_vc (value varchar(100));
CREATE INDEX ix_fi_vc ON fi_vc (value) WHERE value IS NOT NULL;
-- @step batch
ALTER TABLE fi_items ALTER COLUMN value nvarchar(200) NULL;
-- @step batch
ALTER TABLE fi_plain ALTER COLUMN value nvarchar(200) NULL;
-- @step batch
ALTER TABLE fi_pred ALTER COLUMN value nvarchar(200) NULL;
-- @step batch
ALTER TABLE fi_incl ALTER COLUMN value nvarchar(200) NULL;
-- @step batch
ALTER TABLE fi_other ALTER COLUMN value nvarchar(200) NULL;
-- @step batch
ALTER TABLE fi_items ALTER COLUMN value nvarchar(100) NULL;
-- @step batch
ALTER TABLE fi_items ALTER COLUMN value nvarchar(100) NOT NULL;
-- @step batch
ALTER TABLE fi_items ALTER COLUMN value nvarchar(50) NULL;
-- @step batch
ALTER TABLE fi_items ALTER COLUMN value nvarchar(100) COLLATE Latin1_General_BIN2 NULL;
-- @step batch
ALTER TABLE fi_vc ALTER COLUMN value varchar(200) NULL;
-- @step batch
ALTER TABLE fi_vc ALTER COLUMN value nvarchar(100) NULL;
-- @step batch
ALTER TABLE fi_int ALTER COLUMN value int;
-- @step batch
ALTER TABLE fi_int ALTER COLUMN value bigint NULL;
-- @step batch
ALTER TABLE fi_int ALTER COLUMN id bigint NULL;
-- @step batch
ALTER TABLE fi_int DROP COLUMN value;
-- @step batch
SELECT OBJECT_NAME(c.object_id) AS tbl, c.name, TYPE_NAME(c.system_type_id) AS t, c.max_length, c.is_nullable
FROM sys.columns c WHERE OBJECT_NAME(c.object_id) LIKE 'fi[_]%' ORDER BY tbl, c.column_id;

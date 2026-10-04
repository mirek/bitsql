-- ALTER COLUMN under a DEFAULT constraint: a new length, precision, scale
-- or nullability of the same type is allowed (Sequelize changeColumn on a
-- column with a default), another type or (max) is 5074 + 4922.
-- @step setup
CREATE TABLE tg (id int, color nvarchar(20) CONSTRAINT df_color DEFAULT N'none', n int CONSTRAINT df_n DEFAULT 0, d decimal(5,2) CONSTRAINT df_d DEFAULT 1.5, v varchar(10) CONSTRAINT df_v DEFAULT 'x');
-- @step batch
ALTER TABLE tg ALTER COLUMN color nvarchar(30) NULL;
-- @step batch
ALTER TABLE tg ALTER COLUMN color nvarchar(10) NULL;
-- @step batch
ALTER TABLE tg ALTER COLUMN color nvarchar(10) NOT NULL;
-- @step batch
ALTER TABLE tg ALTER COLUMN n bigint;
-- @step batch
ALTER TABLE tg ALTER COLUMN n int NOT NULL;
-- @step batch
ALTER TABLE tg ALTER COLUMN d decimal(8,3);
-- @step batch
ALTER TABLE tg ALTER COLUMN v nvarchar(10);
-- @step batch
ALTER TABLE tg ALTER COLUMN v varchar(max);
-- @step batch
ALTER TABLE tg ALTER COLUMN color nvarchar(max);
-- @step batch
SELECT c.name, TYPE_NAME(c.system_type_id) AS t, c.max_length, c.precision, c.scale, c.is_nullable FROM sys.columns c WHERE c.object_id = OBJECT_ID('tg') ORDER BY c.column_id;

-- Prisma 7 schema engine (prisma db pull / db push / migrate diff)
-- introspection queries, as embedded in schema-engine 7.10.0, over the
-- schema harness/orm/prisma/migrations creates. OBJECT_DEFINITION of a
-- default constraint must be its parenthesized text ("Couldn't parse
-- default value" panics otherwise), ODBCSCALE must exist.
-- @step setup
BEGIN TRY

BEGIN TRAN;

-- CreateSchema
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = N'dbo') EXEC sp_executesql N'CREATE SCHEMA [dbo];';

-- CreateTable
CREATE TABLE [dbo].[users] (
    [id] INT NOT NULL IDENTITY(1,1),
    [email] NVARCHAR(120) NOT NULL,
    [name] NVARCHAR(100) NOT NULL,
    [age] INT,
    [karma] BIGINT NOT NULL CONSTRAINT [users_karma_df] DEFAULT 0,
    [balance] DECIMAL(10,2) NOT NULL CONSTRAINT [users_balance_df] DEFAULT 0,
    [active] BIT NOT NULL CONSTRAINT [users_active_df] DEFAULT 1,
    [born] DATE,
    [seenAt] DATETIME2,
    [bio] NVARCHAR(500),
    [avatar] VARBINARY(max),
    [token] UNIQUEIDENTIFIER,
    [createdAt] DATETIME2 NOT NULL CONSTRAINT [users_createdAt_df] DEFAULT CURRENT_TIMESTAMP,
    [updatedAt] DATETIME2 NOT NULL,
    CONSTRAINT [users_pkey] PRIMARY KEY CLUSTERED ([id]),
    CONSTRAINT [users_email_key] UNIQUE NONCLUSTERED ([email])
);

-- CreateTable
CREATE TABLE [dbo].[posts] (
    [id] INT NOT NULL IDENTITY(1,1),
    [title] NVARCHAR(200) NOT NULL,
    [body] NVARCHAR(max),
    [views] INT NOT NULL CONSTRAINT [posts_views_df] DEFAULT 0,
    [authorId] INT NOT NULL,
    CONSTRAINT [posts_pkey] PRIMARY KEY CLUSTERED ([id])
);

-- CreateTable
CREATE TABLE [dbo].[tags] (
    [id] INT NOT NULL IDENTITY(1,1),
    [name] NVARCHAR(50) NOT NULL,
    CONSTRAINT [tags_pkey] PRIMARY KEY CLUSTERED ([id]),
    CONSTRAINT [tags_name_key] UNIQUE NONCLUSTERED ([name])
);

-- CreateTable
CREATE TABLE [dbo].[_PostTags] (
    [A] INT NOT NULL,
    [B] INT NOT NULL,
    CONSTRAINT [_PostTags_AB_unique] UNIQUE NONCLUSTERED ([A],[B])
);

-- CreateIndex
CREATE NONCLUSTERED INDEX [users_name_age_idx] ON [dbo].[users]([name], [age]);

-- CreateIndex
CREATE NONCLUSTERED INDEX [posts_authorId_idx] ON [dbo].[posts]([authorId]);

-- CreateIndex
CREATE NONCLUSTERED INDEX [_PostTags_B_index] ON [dbo].[_PostTags]([B]);

-- AddForeignKey
ALTER TABLE [dbo].[posts] ADD CONSTRAINT [posts_authorId_fkey] FOREIGN KEY ([authorId]) REFERENCES [dbo].[users]([id]) ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE [dbo].[_PostTags] ADD CONSTRAINT [_PostTags_A_fkey] FOREIGN KEY ([A]) REFERENCES [dbo].[posts]([id]) ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE [dbo].[_PostTags] ADD CONSTRAINT [_PostTags_B_fkey] FOREIGN KEY ([B]) REFERENCES [dbo].[tags]([id]) ON DELETE CASCADE ON UPDATE CASCADE;

COMMIT TRAN;

END TRY
BEGIN CATCH

IF @@TRANCOUNT > 0
BEGIN
    ROLLBACK TRAN;
END;
THROW

END CATCH
-- @step setup
BEGIN TRY

BEGIN TRAN;

-- AlterTable
ALTER TABLE [dbo].[users] ALTER COLUMN [bio] NVARCHAR(max) NULL;
ALTER TABLE [dbo].[users] ADD [score] FLOAT(53);

-- AlterTable
ALTER TABLE [dbo].[posts] ADD [published] BIT NOT NULL CONSTRAINT [posts_published_df] DEFAULT 0;

-- CreateTable
CREATE TABLE [dbo].[profiles] (
    [id] INT NOT NULL IDENTITY(1,1),
    [website] NVARCHAR(200),
    [userId] INT NOT NULL,
    CONSTRAINT [profiles_pkey] PRIMARY KEY CLUSTERED ([id]),
    CONSTRAINT [profiles_userId_key] UNIQUE NONCLUSTERED ([userId])
);

-- AddForeignKey
ALTER TABLE [dbo].[profiles] ADD CONSTRAINT [profiles_userId_fkey] FOREIGN KEY ([userId]) REFERENCES [dbo].[users]([id]) ON DELETE CASCADE ON UPDATE CASCADE;

COMMIT TRAN;

END TRY
BEGIN CATCH

IF @@TRANCOUNT > 0
BEGIN
    ROLLBACK TRAN;
END;
THROW

END CATCH
-- @step setup
CREATE TYPE dbo.Email FROM nvarchar(200) NOT NULL;
-- @step setup
CREATE TABLE dbo.chk (id int NOT NULL CONSTRAINT chk_pk PRIMARY KEY, n int CONSTRAINT chk_n CHECK (n > 0), s nvarchar(10) CONSTRAINT chk_s_df DEFAULT (N'x'), d datetime2 CONSTRAINT chk_d_df DEFAULT (sysdatetime()), g uniqueidentifier CONSTRAINT chk_g_df DEFAULT (newid()), m decimal(9,3) CONSTRAINT chk_m_df DEFAULT (1.5));
-- @step setup
CREATE VIEW dbo.v_users AS SELECT email, name FROM dbo.users;
-- @step setup
CREATE PROCEDURE dbo.p_one AS SELECT 1 AS one;
-- @step batch
SELECT name FROM sys.schemas ORDER BY name
-- @step batch
SELECT
                tbl.name AS table_name,
                SCHEMA_NAME(tbl.schema_id) AS namespace
            FROM sys.tables tbl
            WHERE tbl.is_ms_shipped = 0 AND tbl.type = 'U'
            ORDER BY tbl.name;
-- @step batch
SELECT c.name                                                       AS column_name,
    CASE typ.is_assembly_type
            WHEN 1 THEN TYPE_NAME(c.user_type_id)
            ELSE TYPE_NAME(c.system_type_id)
    END                                                             AS data_type,
    COLUMNPROPERTY(c.object_id, c.name, 'charmaxlen')               AS character_maximum_length,
    OBJECT_DEFINITION(c.default_object_id)                          AS column_default,
    c.is_nullable                                                   AS is_nullable,
    COLUMNPROPERTY(c.object_id, c.name, 'IsIdentity')               AS is_identity,
    OBJECT_NAME(c.object_id)                                        AS table_name,
    OBJECT_NAME(c.default_object_id)                                AS constraint_name,
    convert(tinyint, CASE
        WHEN c.system_type_id IN (48, 52, 56, 59, 60, 62, 106, 108, 122, 127) THEN c.precision
        END) AS numeric_precision,
    convert(int, CASE
        WHEN c.system_type_id IN (40, 41, 42, 43, 58, 61) THEN NULL
        ELSE ODBCSCALE(c.system_type_id, c.scale) END) AS numeric_scale,
    OBJECT_SCHEMA_NAME(c.object_id) AS namespace
FROM sys.columns c
        INNER JOIN sys.objects obj ON c.object_id = obj.object_id
        INNER JOIN sys.types typ ON c.user_type_id = typ.user_type_id
WHERE obj.is_ms_shipped = 0
ORDER BY table_name, COLUMNPROPERTY(c.object_id, c.name, 'ordinal');
-- @step batch
SELECT DISTINCT
    ind.name AS index_name,
    ind.is_unique AS is_unique,
    ind.is_unique_constraint AS is_unique_constraint,
    ind.is_primary_key AS is_primary_key,
    ind.type_desc AS clustering,
    ind.filter_definition AS predicate,
    col.name AS column_name,
    ic.key_ordinal AS seq_in_index,
    ic.is_descending_key AS is_descending,
    t.name AS table_name,
    SCHEMA_NAME(t.schema_id) AS namespace
FROM
    sys.indexes ind
INNER JOIN sys.index_columns ic
    ON ind.object_id = ic.object_id AND ind.index_id = ic.index_id
INNER JOIN sys.columns col
    ON ic.object_id = col.object_id AND ic.column_id = col.column_id
INNER JOIN
    sys.tables t ON ind.object_id = t.object_id
WHERE t.is_ms_shipped = 0
    AND ic.key_ordinal != 0
    AND ind.name IS NOT NULL
    AND ind.type_desc IN (
        'CLUSTERED',
        'NONCLUSTERED',
        'CLUSTERED COLUMNSTORE',
        'NONCLUSTERED COLUMNSTORE'
    )
ORDER BY table_name, index_name, seq_in_index
-- @step batch
SELECT OBJECT_NAME(fkc.constraint_object_id) AS constraint_name,
    parent_table.name                        AS table_name,
    referenced_table.name                    AS referenced_table_name,
    SCHEMA_NAME(referenced_table.schema_id)  AS referenced_schema_name,
    parent_column.name                       AS column_name,
    referenced_column.name                   AS referenced_column_name,
    fk.delete_referential_action             AS delete_referential_action,
    fk.update_referential_action             AS update_referential_action,
    fkc.constraint_column_id                 AS ordinal_position,
    OBJECT_SCHEMA_NAME(fkc.parent_object_id) AS schema_name
FROM sys.foreign_key_columns AS fkc
        INNER JOIN sys.tables AS parent_table
                    ON fkc.parent_object_id = parent_table.object_id
        INNER JOIN sys.tables AS referenced_table
                    ON fkc.referenced_object_id = referenced_table.object_id
        INNER JOIN sys.columns AS parent_column
                    ON fkc.parent_object_id = parent_column.object_id
                        AND fkc.parent_column_id = parent_column.column_id
        INNER JOIN sys.columns AS referenced_column
                    ON fkc.referenced_object_id = referenced_column.object_id
                        AND fkc.referenced_column_id = referenced_column.column_id
        INNER JOIN sys.foreign_keys AS fk
                    ON fkc.constraint_object_id = fk.object_id
                        AND fkc.parent_object_id = fk.parent_object_id
WHERE parent_table.is_ms_shipped = 0
AND referenced_table.is_ms_shipped = 0
ORDER BY table_name, constraint_name, ordinal_position
-- @step batch
SELECT
	tc.table_schema AS namespace,
	tc.table_name AS table_name,
	tc.constraint_name AS constraint_name,
	LOWER(tc.constraint_type) AS constraint_type,
	cc.check_clause AS constraint_definition
FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
LEFT JOIN INFORMATION_SCHEMA.CHECK_CONSTRAINTS cc
	ON cc.constraint_schema = tc.table_schema
	AND cc.constraint_name = tc.constraint_name
WHERE constraint_type = 'CHECK'
ORDER BY namespace, table_name, constraint_type, constraint_name;
-- @step batch
SELECT
                name,
                OBJECT_DEFINITION(object_id) AS definition,
                SCHEMA_NAME(schema_id) AS namespace
            FROM sys.objects
            WHERE is_ms_shipped = 0 AND type = 'P'
            ORDER BY name;
-- @step batch
SELECT
    name AS view_name,
    OBJECT_DEFINITION(object_id) AS view_sql,
    SCHEMA_NAME(schema_id) AS namespace
FROM sys.views
WHERE is_ms_shipped = 0
-- @step batch
SELECT
    udt.name AS user_type_name,
    systyp.name AS system_type_name,
    CONVERT(SMALLINT,
            CASE
                WHEN udt.system_type_id IN (231, 239) AND udt.max_length = -1 THEN -1
                WHEN udt.system_type_id IN (231, 239) THEN udt.max_length / 2.0
                WHEN udt.system_type_id IN (165, 167, 173, 175) THEN udt.max_length
                ELSE null
                END) AS max_length,
    CONVERT(tinyint,
            CASE
                WHEN udt.system_type_id IN (106, 108) THEN udt.precision
                ELSE null
                END) AS precision,
    CONVERT(tinyint,
            CASE
                WHEN udt.system_type_id IN (106, 108) THEN udt.scale
                ELSE null
                END) AS scale,
    SCHEMA_NAME(udt.schema_id) AS namespace
FROM sys.types udt
        LEFT JOIN sys.types systyp
                ON udt.system_type_id = systyp.user_type_id
WHERE udt.is_user_defined = 1

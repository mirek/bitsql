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

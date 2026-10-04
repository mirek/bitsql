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

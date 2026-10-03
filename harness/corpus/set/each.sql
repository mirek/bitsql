-- CurCmd of each SET statement, one per batch (no ambiguity about which
-- statements emit no DONE).
-- @step setup
CREATE TABLE dbo.t (id int IDENTITY);
-- @step batch
SET QUOTED_IDENTIFIER ON;
-- @step batch
SET ANSI_NULLS ON;
-- @step batch
SET NOCOUNT ON;
-- @step batch
SET NOCOUNT OFF;
-- @step batch
SET XACT_ABORT ON;
-- @step batch
SET XACT_ABORT OFF;
-- @step batch
SET ARITHABORT OFF;
-- @step batch
SET ARITHABORT ON;
-- @step batch
SET ANSI_WARNINGS ON;
-- @step batch
SET ANSI_PADDING ON;
-- @step batch
SET ANSI_NULL_DFLT_ON ON;
-- @step batch
SET CONCAT_NULL_YIELDS_NULL ON;
-- @step batch
SET NUMERIC_ROUNDABORT OFF;
-- @step batch
SET IMPLICIT_TRANSACTIONS OFF;
-- @step batch
SET CURSOR_CLOSE_ON_COMMIT OFF;
-- @step batch
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
-- @step batch
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
-- @step batch
SET DATEFIRST 1;
-- @step batch
SET DATEFIRST 7;
-- @step batch
SET DATEFORMAT mdy;
-- @step batch
SET LANGUAGE us_english;
-- @step batch
SET LOCK_TIMEOUT 1000;
-- @step batch
SET LOCK_TIMEOUT -1;
-- @step batch
SET ROWCOUNT 0;
-- @step batch
SET TEXTSIZE 2147483647;
-- @step batch
SET DEADLOCK_PRIORITY NORMAL;
-- @step batch
SET STATISTICS IO OFF;
-- @step batch
SET STATISTICS TIME OFF;
-- @step batch
SET NOEXEC OFF;
-- @step batch
SET FMTONLY OFF;
-- @step batch
SET CONTEXT_INFO 0x00;
-- @step batch
SET IDENTITY_INSERT dbo.t ON;
-- @step batch
SET IDENTITY_INSERT dbo.t OFF;

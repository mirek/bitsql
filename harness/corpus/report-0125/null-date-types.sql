-- Mixed row constructors: temporal targets, typed-NULL controls, and typed-int rejection.
-- @step setup
CREATE TABLE dbo.t_date (v date NULL);
-- @step batch
INSERT dbo.t_date VALUES (NULL),(N'2026-01-01');
SELECT v FROM dbo.t_date ORDER BY v;
-- @step batch
TRUNCATE TABLE dbo.t_date;
INSERT dbo.t_date VALUES (NULL),(CAST(N'2026-01-01' AS date));
SELECT v FROM dbo.t_date ORDER BY v;
-- @step setup
CREATE TABLE dbo.t_time (v time NULL);
-- @step batch
INSERT dbo.t_time VALUES (NULL),(N'12:34:56');
SELECT v FROM dbo.t_time ORDER BY v;
-- @step batch
TRUNCATE TABLE dbo.t_time;
INSERT dbo.t_time VALUES (NULL),(CAST(N'12:34:56' AS time));
SELECT v FROM dbo.t_time ORDER BY v;
-- @step setup
CREATE TABLE dbo.t_datetime (v datetime NULL);
-- @step batch
INSERT dbo.t_datetime VALUES (NULL),(N'2026-01-01');
SELECT v FROM dbo.t_datetime ORDER BY v;
-- @step batch
TRUNCATE TABLE dbo.t_datetime;
INSERT dbo.t_datetime VALUES (NULL),(CAST(N'2026-01-01' AS datetime));
SELECT v FROM dbo.t_datetime ORDER BY v;
-- @step setup
CREATE TABLE dbo.t_smalldatetime (v smalldatetime NULL);
-- @step batch
INSERT dbo.t_smalldatetime VALUES (NULL),(N'2026-01-01');
SELECT v FROM dbo.t_smalldatetime ORDER BY v;
-- @step batch
TRUNCATE TABLE dbo.t_smalldatetime;
INSERT dbo.t_smalldatetime VALUES (NULL),(CAST(N'2026-01-01' AS smalldatetime));
SELECT v FROM dbo.t_smalldatetime ORDER BY v;
-- @step setup
CREATE TABLE dbo.t_datetime2 (v datetime2 NULL);
-- @step batch
INSERT dbo.t_datetime2 VALUES (NULL),(N'2026-01-01');
SELECT v FROM dbo.t_datetime2 ORDER BY v;
-- @step batch
TRUNCATE TABLE dbo.t_datetime2;
INSERT dbo.t_datetime2 VALUES (NULL),(CAST(N'2026-01-01' AS datetime2));
SELECT v FROM dbo.t_datetime2 ORDER BY v;
-- @step setup
CREATE TABLE dbo.t_datetimeoffset (v datetimeoffset NULL);
-- @step batch
INSERT dbo.t_datetimeoffset VALUES (NULL),(N'2026-01-01');
SELECT v FROM dbo.t_datetimeoffset ORDER BY v;
-- @step batch
TRUNCATE TABLE dbo.t_datetimeoffset;
INSERT dbo.t_datetimeoffset VALUES (NULL),(CAST(N'2026-01-01' AS datetimeoffset));
SELECT v FROM dbo.t_datetimeoffset ORDER BY v;
-- @step batch
INSERT dbo.t_datetime2 VALUES (CAST(NULL AS int)),(CAST(N'2026-01-01' AS datetime2));

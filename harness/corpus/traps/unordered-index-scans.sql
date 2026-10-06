-- Observed SQL Server scan choices, not a guaranteed order contract.
-- Applications requiring an order must use ORDER BY.
-- @step setup
CREATE TABLE dbo.g (name nvarchar(450) NOT NULL, multiplier float NOT NULL DEFAULT 1.0, CONSTRAINT g_pk PRIMARY KEY CLUSTERED (name));
INSERT dbo.g (name) VALUES (N'H'),(N'G'),(N'F'),(N'E'),(N'D'),(N'C'),(N'B'),(N'A');
CREATE TABLE dbo.ints (id int PRIMARY KEY CLUSTERED);
INSERT dbo.ints VALUES (5),(3),(9),(1);
CREATE TABLE dbo.covered (a int NOT NULL, b int NOT NULL, payload nvarchar(100), UNIQUE NONCLUSTERED(a,b));
INSERT dbo.covered VALUES (3,1,N'c'),(1,2,N'b'),(1,1,N'a');
-- @step batch
SELECT * FROM dbo.g;
UPDATE dbo.g SET multiplier = 2 WHERE name = N'D';
SELECT * FROM dbo.g;
DELETE dbo.g WHERE name = N'D';
INSERT dbo.g (name) VALUES (N'D');
SELECT * FROM dbo.g;
SELECT * FROM dbo.g WHERE name > N'D';
SELECT * FROM dbo.ints;
SELECT a,b FROM dbo.covered;
-- @step batch
SELECT * FROM dbo.g ORDER BY name;
SELECT * FROM dbo.ints ORDER BY id;
SELECT a,b FROM dbo.covered ORDER BY a,b;

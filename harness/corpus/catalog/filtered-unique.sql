-- Filtered unique index WHERE col IS NOT NULL: many NULLs allowed,
-- duplicates of non-NULL values rejected (2601); unfiltered unique index
-- allows a single NULL.
-- @step setup
CREATE TABLE dbo.u (id int NOT NULL CONSTRAINT pk_u PRIMARY KEY, code nvarchar(10) NULL, k int NULL);
CREATE UNIQUE INDEX ux_u_code ON dbo.u (code) WHERE code IS NOT NULL;
CREATE UNIQUE INDEX ux_u_k ON dbo.u (k);
-- @step batch
INSERT INTO dbo.u (id, code) VALUES (1, NULL);
INSERT INTO dbo.u (id, code, k) VALUES (2, NULL, 1);
INSERT INTO dbo.u (id, code, k) VALUES (3, N'a', 2);
SELECT id, code, k FROM dbo.u ORDER BY id;
-- @step batch
INSERT INTO dbo.u (id, code, k) VALUES (4, N'a', 3);
-- @step batch
INSERT INTO dbo.u (id, code, k) VALUES (5, N'b', NULL);
-- @step batch
UPDATE dbo.u SET code = N'c' WHERE id = 1;
UPDATE dbo.u SET code = N'c' WHERE id = 2;
-- @step batch
SELECT id, code, k FROM dbo.u ORDER BY id;

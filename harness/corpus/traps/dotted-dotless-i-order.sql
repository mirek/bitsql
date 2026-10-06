-- Pre-existing default-collation ordering gap; outside the compact ASCII domain.
-- @step setup
CREATE TABLE words(id int NOT NULL, v nvarchar(32) COLLATE SQL_Latin1_General_CP1_CI_AS);
INSERT words VALUES (1,N'İ'),(2,N'ı');
-- @step batch
SELECT id FROM words ORDER BY v,id;

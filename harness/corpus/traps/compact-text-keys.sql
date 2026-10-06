-- Exact short ASCII key domain and fallback boundaries for grouping/sorting.
-- @step setup
CREATE TABLE words(id int NOT NULL, v nvarchar(32) COLLATE SQL_Latin1_General_CP1_CI_AS NULL);
INSERT words VALUES (1,N''),(2,N' '),(3,N'0'),(4,N'00'),(5,N'00000000'),(6,N'1'),(7,N'10'),(8,N'9'),(9,N'A'),(10,N'a'),(11,N'A0'),(12,N'a0 '),(13,N'I'),(14,N'i'),(15,N'Z'),(16,N'zzzzzzzz'),(17,NULL),(18,N'ZZZZZZZZ');
-- @step batch
SELECT MIN(id) AS first_id, COUNT(*) AS n FROM words GROUP BY v ORDER BY first_id;
-- @step batch
SELECT COUNT(DISTINCT v) AS n FROM words;
-- @step batch
SELECT id, ROW_NUMBER() OVER(PARTITION BY v ORDER BY id) AS r FROM words ORDER BY v, id;
-- @step batch
SELECT id FROM words ORDER BY v DESC, id;
-- @step setup
INSERT words VALUES (19,N'123456789'),(20,N'a-b'),(21,N'a b'),(22,N'é'),(25,NCHAR(0)),(26,N'a''b');
-- @step batch
SELECT MIN(id) AS first_id, COUNT(*) AS n FROM words GROUP BY v ORDER BY first_id;
-- @step batch
SELECT id, ROW_NUMBER() OVER(PARTITION BY v ORDER BY id) AS r FROM words ORDER BY v, id;
-- @step batch
SELECT id FROM words ORDER BY v COLLATE Latin1_General_100_BIN2, id;

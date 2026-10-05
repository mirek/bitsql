-- 2627 / 2601 on a table variable and temp tables name the object with its
-- schema: 'dbo.@t', 'dbo.#t'.
-- @step batch
DECLARE @t TABLE (id int, INDEX ix UNIQUE (id)); INSERT @t VALUES (1), (1);
-- @step batch
CREATE TABLE #t (id int CONSTRAINT pk_t PRIMARY KEY); INSERT #t VALUES (1), (1);
-- @step batch
CREATE TABLE #u (id int, v int, CONSTRAINT uq_v UNIQUE (v)); INSERT #u VALUES (1, 1), (2, 1);
-- @step batch
CREATE TABLE #w (id int); CREATE UNIQUE INDEX ix ON #w (id); INSERT #w VALUES (1), (1);

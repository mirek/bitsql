-- MERGE fires AFTER triggers per action: which ones, in which order, with
-- what inserted/deleted rows, and for actions that touched no rows.
-- @step setup
CREATE TABLE m (id int CONSTRAINT pk_m PRIMARY KEY, v int);
CREATE TABLE mlog (seq int IDENTITY, act varchar(10), ins int, del int);
INSERT m VALUES (1, 10), (2, 20), (3, 30);
-- @step setup
CREATE TRIGGER m_ins ON m AFTER INSERT AS BEGIN SET NOCOUNT ON; INSERT mlog (act, ins, del) SELECT 'insert', (SELECT COUNT(*) FROM inserted), (SELECT COUNT(*) FROM deleted); END
-- @step setup
CREATE TRIGGER m_upd ON m AFTER UPDATE AS BEGIN SET NOCOUNT ON; INSERT mlog (act, ins, del) SELECT 'update', (SELECT COUNT(*) FROM inserted), (SELECT COUNT(*) FROM deleted); END
-- @step setup
CREATE TRIGGER m_del ON m AFTER DELETE AS BEGIN SET NOCOUNT ON; INSERT mlog (act, ins, del) SELECT 'delete', (SELECT COUNT(*) FROM inserted), (SELECT COUNT(*) FROM deleted); END
-- @step batch
MERGE m AS t USING (VALUES (1, 11), (4, 40)) AS s(id, v) ON t.id = s.id
WHEN MATCHED THEN UPDATE SET v = s.v
WHEN NOT MATCHED THEN INSERT (id, v) VALUES (s.id, s.v)
WHEN NOT MATCHED BY SOURCE AND t.id = 3 THEN DELETE;
SELECT seq, act, ins, del FROM mlog ORDER BY seq;
-- @step batch
DELETE FROM mlog;
MERGE m AS t USING (VALUES (99, 1)) AS s(id, v) ON t.id = s.id
WHEN MATCHED THEN DELETE;
SELECT act, ins, del FROM mlog ORDER BY seq;

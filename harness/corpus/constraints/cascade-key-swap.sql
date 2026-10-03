-- Referential actions when an UPDATE swaps key values: CASCADE maps each
-- old key to its row's new key, SET NULL fires even though the old key
-- still exists afterwards, NO ACTION is checked against the final state.
-- @step setup
CREATE TABLE p (id int NOT NULL CONSTRAINT pk_p PRIMARY KEY, tag char(1) NOT NULL);
CREATE TABLE c_cascade (id int NOT NULL CONSTRAINT pk_cc PRIMARY KEY, pid int NULL CONSTRAINT fk_cc REFERENCES p (id) ON UPDATE CASCADE);
CREATE TABLE c_null (id int NOT NULL CONSTRAINT pk_cn PRIMARY KEY, pid int NULL CONSTRAINT fk_cn REFERENCES p (id) ON UPDATE SET NULL);
CREATE TABLE p2 (id int NOT NULL CONSTRAINT pk_p2 PRIMARY KEY);
CREATE TABLE c_none (id int NOT NULL CONSTRAINT pk_cx PRIMARY KEY, pid int NULL CONSTRAINT fk_cx REFERENCES p2 (id));
INSERT p VALUES (1, 'a'), (2, 'b'), (3, 'c');
INSERT c_cascade VALUES (10, 1), (20, 2), (30, 3);
INSERT c_null VALUES (10, 1), (20, 2), (30, NULL);
INSERT p2 VALUES (1), (2), (3);
INSERT c_none VALUES (10, 1), (20, 2);
-- @step batch
UPDATE p SET id = CASE id WHEN 1 THEN 2 WHEN 2 THEN 1 ELSE id END WHERE id IN (1, 2);
SELECT id, pid FROM c_cascade ORDER BY id;
SELECT id, pid FROM c_null ORDER BY id;
-- @step batch
UPDATE p2 SET id = CASE id WHEN 1 THEN 2 WHEN 2 THEN 1 ELSE id END WHERE id IN (1, 2);
SELECT id FROM p2 ORDER BY id;
-- @step batch
UPDATE p2 SET id = id + 10 WHERE id = 1;
SELECT id FROM p2 ORDER BY id;
-- @step batch
DECLARE @o TABLE (new_id int, old_id int);
UPDATE p SET id = id + 100 OUTPUT inserted.id, deleted.id INTO @o;
SELECT new_id, old_id FROM @o ORDER BY new_id;
SELECT id, pid FROM c_cascade ORDER BY id;

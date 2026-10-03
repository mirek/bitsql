-- Rows changed by referential actions: computed columns are recomputed,
-- CHECK constraints over the changed column apply, unique keys of the
-- child are enforced, a NO ACTION grandchild blocks the cascade, and an
-- OUTPUT of the parent statement shows only the parent rows.
-- @step setup
CREATE TABLE p (id int NOT NULL CONSTRAINT pk_p PRIMARY KEY);
CREATE TABLE c (id int NOT NULL CONSTRAINT pk_c PRIMARY KEY,
  pid int NULL CONSTRAINT fk_c REFERENCES p (id) ON UPDATE CASCADE ON DELETE SET NULL,
  twice AS pid * 2,
  CONSTRAINT ck_c CHECK (pid IS NULL OR pid < 50));
CREATE TABLE u (id int NOT NULL CONSTRAINT pk_u PRIMARY KEY,
  pid int NULL CONSTRAINT uq_u UNIQUE CONSTRAINT fk_u REFERENCES p (id) ON DELETE SET NULL);
CREATE TABLE g (id int NOT NULL CONSTRAINT pk_g PRIMARY KEY, cid int NULL CONSTRAINT fk_g REFERENCES c (id));
CREATE TABLE d (id int NOT NULL CONSTRAINT pk_d PRIMARY KEY, pid int NULL CONSTRAINT fk_d REFERENCES p (id) ON DELETE CASCADE);
CREATE TABLE dg (id int NOT NULL CONSTRAINT pk_dg PRIMARY KEY, did int NULL CONSTRAINT fk_dg REFERENCES d (id));
INSERT p VALUES (1), (2), (3), (4);
INSERT c VALUES (10, 1), (20, 2);
INSERT u VALUES (1, 1), (2, 2);
INSERT d VALUES (100, 3), (200, 4);
INSERT dg VALUES (1, 200);
-- @step batch
UPDATE p SET id = 5 WHERE id = 1;
SELECT id, pid, twice FROM c ORDER BY id;
-- @step batch
UPDATE p SET id = 60 WHERE id = 2;
SELECT id, pid FROM c ORDER BY id;
SELECT id FROM p ORDER BY id;
-- @step batch
DELETE p OUTPUT deleted.id WHERE id IN (5, 2);
SELECT id, pid FROM u ORDER BY id;
SELECT id, pid, twice FROM c ORDER BY id;
-- @step batch
DELETE p WHERE id = 3;
SELECT id, pid FROM d ORDER BY id;
-- @step batch
DELETE p WHERE id = 4;
SELECT id, pid FROM d ORDER BY id;
SELECT id FROM p ORDER BY id;

-- UPDATE checks only the CHECK and FOREIGN KEY constraints over the columns
-- it sets (or computed columns over them); untrusted rows elsewhere do not
-- block it.
-- @step setup
CREATE TABLE p (id int NOT NULL CONSTRAINT pk_p PRIMARY KEY);
CREATE TABLE t (id int NOT NULL CONSTRAINT pk_t PRIMARY KEY, a int NULL, b int NULL, pid int NULL, s AS a + 1);
INSERT p VALUES (1);
INSERT t VALUES (1, -5, -5, 99), (2, 1, 1, 1);
ALTER TABLE t WITH NOCHECK ADD CONSTRAINT ck_a CHECK (a > 0),
  CONSTRAINT fk_t FOREIGN KEY (pid) REFERENCES p (id);
-- @step batch
UPDATE t SET b = 7 WHERE id = 1;
SELECT id, a, b, pid FROM t ORDER BY id;
-- @step batch
UPDATE t SET a = -2 WHERE id = 1;
-- @step batch
UPDATE t SET pid = pid WHERE id = 1;
-- @step batch
UPDATE t SET a = a WHERE id = 2;
UPDATE t SET b = b + 1, pid = 1 WHERE id = 1;
SELECT id, a, b, pid FROM t ORDER BY id;

-- FOREIGN KEY definition errors: column type and length matching,
-- SET NULL / SET DEFAULT on NOT NULL columns, the cascade-path analysis
-- for ALTER TABLE ADD and for actions on one side only.
-- @step setup
CREATE TABLE p (id int NOT NULL CONSTRAINT pk_p PRIMARY KEY, d decimal(10, 2) NOT NULL CONSTRAINT uq_pd UNIQUE,
  n numeric(10, 2) NOT NULL CONSTRAINT uq_pn UNIQUE, c char(5) NOT NULL CONSTRAINT uq_pc UNIQUE,
  v varchar(5) NOT NULL CONSTRAINT uq_pv UNIQUE);
-- @step batch
CREATE TABLE c1 (d numeric(10, 2) CONSTRAINT f1 REFERENCES p (d));
-- @step batch
CREATE TABLE c2 (d decimal(12, 2) CONSTRAINT f2 REFERENCES p (d));
-- @step batch
CREATE TABLE c3 (c varchar(5) CONSTRAINT f3 REFERENCES p (c));
-- @step batch
CREATE TABLE c4 (v varchar(10) CONSTRAINT f4 REFERENCES p (v));
-- @step batch
CREATE TABLE c5 (v nvarchar(5) CONSTRAINT f5 REFERENCES p (v));
-- @step batch
CREATE TABLE c6 (id smallint CONSTRAINT f6 REFERENCES p (id));
-- @step batch
CREATE TABLE c7 (id int NOT NULL CONSTRAINT df7 DEFAULT 1 CONSTRAINT f7 REFERENCES p (id) ON UPDATE SET DEFAULT);
SELECT name, update_referential_action_desc FROM sys.foreign_keys WHERE name = 'f7';
-- @step batch
CREATE TABLE c8 (id int NOT NULL CONSTRAINT f8 REFERENCES p (id) ON UPDATE SET NULL);
-- @step batch
CREATE TABLE a (id int NOT NULL CONSTRAINT pk_a PRIMARY KEY, pid int NULL CONSTRAINT fa REFERENCES p (id) ON DELETE CASCADE);
CREATE TABLE b (id int NOT NULL CONSTRAINT pk_b PRIMARY KEY, aid int NULL, pid int NULL);
-- @step batch
ALTER TABLE b ADD CONSTRAINT fba FOREIGN KEY (aid) REFERENCES a (id) ON DELETE CASCADE;
-- @step batch
ALTER TABLE b ADD CONSTRAINT fbp FOREIGN KEY (pid) REFERENCES p (id) ON UPDATE CASCADE;
-- @step batch
ALTER TABLE b ADD CONSTRAINT fbp2 FOREIGN KEY (pid) REFERENCES p (id) ON DELETE SET NULL;
-- @step batch
SELECT name, delete_referential_action_desc, update_referential_action_desc FROM sys.foreign_keys ORDER BY name;
SELECT COUNT(*) AS tables FROM sys.tables WHERE name LIKE 'c[0-9]';

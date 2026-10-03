-- AFTER INSERT trigger writing an audit row: tokens, @@ROWCOUNT, SCOPE_IDENTITY vs @@IDENTITY.
-- @step setup
CREATE TABLE items (id int IDENTITY(1,1) PRIMARY KEY, name varchar(20) NOT NULL);
CREATE TABLE audit (aid int IDENTITY(100,1) PRIMARY KEY, item_id int, action varchar(10));
-- @step setup
CREATE TRIGGER trg_items_ins ON items AFTER INSERT AS
BEGIN
  INSERT INTO audit (item_id, action) SELECT id, 'insert' FROM inserted;
END
-- @step batch
INSERT INTO items (name) VALUES ('a'), ('b');
SELECT @@ROWCOUNT AS rc, SCOPE_IDENTITY() AS si, @@IDENTITY AS ident;
SELECT aid, item_id, action FROM audit ORDER BY aid;

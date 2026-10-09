-- Filtered index predicates keep IN; CHECK constraints expand it.
-- @step setup
CREATE TABLE dbo.foo (id int NOT NULL PRIMARY KEY, category nvarchar(20) NOT NULL, removedAt datetime2 NULL);
CREATE INDEX foo_category_idx ON dbo.foo (category) WHERE removedAt IS NULL AND category IN (N'alpha', N'beta', N'gamma');
CREATE INDEX foo_single_idx ON dbo.foo(category) WHERE category IN (N'alpha');
CREATE INDEX foo_number_idx ON dbo.foo(id) WHERE id IN (1,2,3);
ALTER TABLE dbo.foo ADD CONSTRAINT foo_check CHECK(category IN (N'alpha', N'beta', N'gamma'));
-- @step batch
SELECT name, filter_definition FROM sys.indexes WHERE object_id=OBJECT_ID(N'dbo.foo') AND has_filter=1 ORDER BY name;
SELECT definition FROM sys.check_constraints WHERE parent_object_id=OBJECT_ID(N'dbo.foo');

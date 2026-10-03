///|
test "create table with constraints" {
  inspect(
    sx(
      (
        #|CREATE TABLE dbo.users (
        #|  id INT IDENTITY(1, 1) NOT NULL PRIMARY KEY,
        #|  name NVARCHAR(100) NOT NULL,
        #|  email NVARCHAR(255) NULL UNIQUE,
        #|  age INT CHECK (age >= 0),
        #|  team_id INT REFERENCES teams (id) ON DELETE CASCADE,
        #|  created DATETIME2 DEFAULT SYSDATETIME(),
        #|  CONSTRAINT uq_users_name UNIQUE (name),
        #|  FOREIGN KEY (team_id) REFERENCES teams (id)
        #|)
      ),
    ),
    content=(
      #|(create-table dbo.users (column id INT not-null (identity 1 1) (primary-key)) (column name NVARCHAR(100) not-null) (column email NVARCHAR(255) null (unique)) (column age INT (check (>= age 0))) (column team_id INT (references teams (id) (on-delete cascade))) (column created DATETIME2 (default (call SYSDATETIME))) (constraint uq_users_name (unique (name))) (foreign-key (team_id) (references teams (id))))
    ),
  )
  inspect(
    sx(
      (
        #|CREATE TABLE [dbo].[orders] (
        #|  [id] BIGINT IDENTITY(-1, -1) NOT FOR REPLICATION NOT NULL,
        #|  [guid] UNIQUEIDENTIFIER ROWGUIDCOL NOT NULL CONSTRAINT [df_guid] DEFAULT (NEWSEQUENTIALID()),
        #|  [total] DECIMAL(18, 2) NOT NULL CONSTRAINT df_total DEFAULT ((0)),
        #|  [note] NVARCHAR(MAX) COLLATE Latin1_General_100_CS_AI NULL,
        #|  [ver] ROWVERSION,
        #|  CONSTRAINT [pk_orders] PRIMARY KEY CLUSTERED ([id] ASC) WITH (PAD_INDEX = OFF, FILLFACTOR = 90) ON [PRIMARY],
        #|  CONSTRAINT fk_o_c FOREIGN KEY (cid, cx) REFERENCES dbo.c (id, x) ON DELETE SET NULL ON UPDATE NO ACTION,
        #|  CONSTRAINT ck CHECK NOT FOR REPLICATION ([total] >= 0),
        #|  INDEX ix_total NONCLUSTERED (total DESC)
        #|) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
      ),
    ),
    content=(
      #|(create-table [dbo].[orders] (column [id] BIGINT not-null (identity -1 -1)) (column [guid] UNIQUEIDENTIFIER not-null rowguidcol (constraint [df_guid] (default (paren (call NEWSEQUENTIALID))))) (column [total] DECIMAL(18,2) not-null (constraint df_total (default (paren (paren 0))))) (column [note] NVARCHAR(max) (collate Latin1_General_100_CS_AI) null) (column [ver] ROWVERSION) (constraint [pk_orders] (primary-key clustered ([id]) (with PAD_INDEX=OFF FILLFACTOR=90))) (constraint fk_o_c (foreign-key (cid cx) (references dbo.c (id x) (on-delete set-null) (on-update no-action)))) (constraint ck (check (>= [total] 0))) (index ix_total ((desc total))) (on [PRIMARY]))
    ),
  )
  inspect(
    sx(
      (
        #|CREATE TABLE totals (
        #|  quantity INT,
        #|  price DECIMAL(10,2),
        #|  total AS quantity * price PERSISTED NOT NULL,
        #|  doubled AS (quantity * 2)
        #|)
      ),
    ),
    content=(
      #|(create-table totals (column quantity INT) (column price DECIMAL(10,2)) (column total (as (* quantity price)) persisted not-null) (column doubled (as (paren (* quantity 2)))))
    ),
  )
  inspect(
    sx("CREATE TABLE t (a INT, b INT, PRIMARY KEY NONCLUSTERED (a, b DESC))"),
    content=(
      #|(create-table t (column a INT) (column b INT) (primary-key nonclustered (a (desc b))))
    ),
  )
  inspect(
    sx("CREATE TABLE #tmp (a INT)"),
    content=(
      #|(create-table #tmp (column a INT))
    ),
  )
  inspect(
    sx("CREATE TABLE t ("),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near '('.
    ),
  )
  inspect(
    sx("CREATE TABLE t (a INT,)"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near ')'.
    ),
  )
}

///|
test "alter table" {
  inspect(
    sx("ALTER TABLE t ADD c INT NULL"),
    content=(
      #|(alter-table t (add (column c INT null)))
    ),
  )
  inspect(
    sx(
      "ALTER TABLE t ADD c INT NULL, d NVARCHAR(10) CONSTRAINT df_d DEFAULT N'x' NOT NULL",
    ),
    content=(
      #|(alter-table t (add (column c INT null) (column d NVARCHAR(10) not-null (constraint df_d (default N'x')))))
    ),
  )
  inspect(
    sx(
      "ALTER TABLE t ALTER COLUMN c NVARCHAR(40) COLLATE Latin1_General_100_CS_AS NOT NULL",
    ),
    content=(
      #|(alter-table t (alter-column c NVARCHAR(40) (collate Latin1_General_100_CS_AS) not-null))
    ),
  )
  inspect(
    sx("ALTER TABLE t ALTER COLUMN c BIGINT"),
    content=(
      #|(alter-table t (alter-column c BIGINT))
    ),
  )
  inspect(
    sx("ALTER TABLE t DROP COLUMN c, d"),
    content=(
      #|(alter-table t (drop (column c) (column d)))
    ),
  )
  inspect(
    sx("ALTER TABLE t DROP CONSTRAINT IF EXISTS ck, COLUMN IF EXISTS c"),
    content=(
      #|(alter-table t (drop (constraint if-exists ck) (column if-exists c)))
    ),
  )
  inspect(
    sx("ALTER TABLE t DROP fk_x"),
    content=(
      #|(alter-table t (drop (constraint fk_x)))
    ),
  )
  inspect(
    sx(
      "ALTER TABLE [dbo].[t] WITH CHECK ADD CONSTRAINT [fk] FOREIGN KEY ([a]) REFERENCES [dbo].[p] ([id])",
    ),
    content=(
      #|(alter-table [dbo].[t] (add with-check (constraint [fk] (foreign-key ([a]) (references [dbo].[p] ([id]))))))
    ),
  )
  inspect(
    sx("ALTER TABLE [dbo].[t] CHECK CONSTRAINT [fk]"),
    content=(
      #|(alter-table [dbo].[t] (check-constraint [fk]))
    ),
  )
  inspect(
    sx("ALTER TABLE t NOCHECK CONSTRAINT ALL"),
    content=(
      #|(alter-table t (nocheck-constraint all))
    ),
  )
  inspect(
    sx("ALTER TABLE t WITH NOCHECK CHECK CONSTRAINT ALL"),
    content=(
      #|(alter-table t (check-constraint with-nocheck all))
    ),
  )
  inspect(
    sx("ALTER TABLE t ADD CONSTRAINT df_a DEFAULT 0 FOR a"),
    content=(
      #|(alter-table t (add (constraint df_a (default 0 (for a)))))
    ),
  )
  inspect(
    sx("ALTER TABLE t ADD CONSTRAINT pk PRIMARY KEY (id)"),
    content=(
      #|(alter-table t (add (constraint pk (primary-key (id)))))
    ),
  )
  inspect(
    sx(
      "ALTER TABLE t ADD CONSTRAINT ck CHECK (a > 0), CONSTRAINT uq UNIQUE (b)",
    ),
    content=(
      #|(alter-table t (add (constraint ck (check (> a 0))) (constraint uq (unique (b)))))
    ),
  )
  inspect(
    sx("ALTER TABLE t DISABLE TRIGGER ALL"),
    content=(
      #|(alter-table t (disable-trigger all))
    ),
  )
  inspect(
    sx("ALTER TABLE t ENABLE TRIGGER tr1, tr2"),
    content=(
      #|(alter-table t (enable-trigger tr1 tr2))
    ),
  )
  inspect(
    sx("ALTER TABLE t SET (LOCK_ESCALATION = TABLE)"),
    content=(
      #|(alter-table t (set (with LOCK_ESCALATION=TABLE)))
    ),
  )
}

///|
test "indexes" {
  inspect(
    sx("CREATE UNIQUE INDEX ix ON t (a, b DESC) WHERE a > 0"),
    content=(
      #|(create-index unique ix t (a (desc b)) (where (> a 0)))
    ),
  )
  inspect(
    sx(
      "CREATE NONCLUSTERED INDEX [ix_t_a] ON [dbo].[t] ([a] ASC) INCLUDE ([b], [c]) WITH (ONLINE = ON, DATA_COMPRESSION = PAGE) ON [PRIMARY]",
    ),
    content=(
      #|(create-index nonclustered [ix_t_a] [dbo].[t] ([a]) (include ([b] [c])) (with ONLINE=ON DATA_COMPRESSION=PAGE))
    ),
  )
  inspect(
    sx("CREATE UNIQUE CLUSTERED INDEX ix ON t (a)"),
    content=(
      #|(create-index unique clustered ix t (a))
    ),
  )
  inspect(
    sx("CREATE CLUSTERED COLUMNSTORE INDEX cci ON t"),
    content=(
      #|(create-index clustered columnstore cci t)
    ),
  )
  inspect(
    sx("DROP INDEX ix ON t"),
    content=(
      #|(drop-index (ix t))
    ),
  )
  inspect(
    sx("DROP INDEX IF EXISTS ix ON dbo.t, ix2 ON dbo.u"),
    content=(
      #|(drop-index if-exists (ix dbo.t) (ix2 dbo.u))
    ),
  )
  inspect(
    sx("DROP INDEX t.ix"),
    content=(
      #|(drop-index t.ix)
    ),
  )
  inspect(
    sx("DROP INDEX dbo.ix ON dbo.a"),
    content=(
      #|Msg 156, Level 15, State 1, Line 1: Incorrect syntax near the keyword 'ON'.
    ),
  )
}

///|
test "drops" {
  inspect(
    sx("DROP TABLE IF EXISTS a, dbo.b"),
    content=(
      #|(drop-table if-exists a dbo.b)
    ),
  )
  inspect(
    sx("DROP VIEW v"),
    content=(
      #|(drop-view v)
    ),
  )
  inspect(
    sx("DROP PROCEDURE IF EXISTS p, q"),
    content=(
      #|(drop-procedure if-exists p q)
    ),
  )
  inspect(
    sx("DROP PROC p"),
    content=(
      #|(drop-procedure p)
    ),
  )
  inspect(
    sx("DROP FUNCTION IF EXISTS dbo.add_tax"),
    content=(
      #|(drop-function if-exists dbo.add_tax)
    ),
  )
  inspect(
    sx("DROP TRIGGER IF EXISTS dbo.t, dbo.u"),
    content=(
      #|(drop-trigger if-exists dbo.t dbo.u)
    ),
  )
  inspect(
    sx("DROP SCHEMA s"),
    content=(
      #|(drop-schema s)
    ),
  )
  inspect(
    sx("DROP TYPE dbo.ids"),
    content=(
      #|(drop-type dbo.ids)
    ),
  )
  inspect(
    sx("DROP SEQUENCE IF EXISTS dbo.seq"),
    content=(
      #|(drop-sequence if-exists dbo.seq)
    ),
  )
  inspect(
    sx("DROP DATABASE x"),
    content=(
      #|(drop-database x)
    ),
  )
}

///|
test "views" {
  inspect(
    sx("CREATE VIEW v (a) AS SELECT 1"),
    content=(
      #|(create-view v (a) (select 1))
    ),
  )
  inspect(
    sx(
      "CREATE OR ALTER VIEW dbo.v WITH SCHEMABINDING AS WITH c AS (SELECT a FROM dbo.t) SELECT a FROM c WITH CHECK OPTION",
    ),
    content=(
      #|(create-or-alter-view dbo.v (with 'SCHEMABINDING') (query (with (c (select a (from (table dbo.t))))) (select a (from (table c)))) check-option)
    ),
  )
  inspect(
    sx("ALTER VIEW v AS SELECT 2;"),
    content=(
      #|(alter-view v (select 2))
    ),
  )
  inspect(
    sx("SELECT 1\nCREATE VIEW v AS SELECT 1"),
    content=(
      #|Msg 111, Level 15, State 1, Line 2: 'CREATE VIEW' must be the first statement in a query batch.
    ),
  )
  inspect(
    sx("CREATE VIEW v AS SELECT 1\nSELECT 2"),
    content=(
      #|Msg 156, Level 15, State 1, Line 2: Incorrect syntax near the keyword 'SELECT'.
    ),
  )
}

///|
test "procedures" {
  inspect(
    sx(
      (
        #|CREATE PROCEDURE dbo.p @a INT, @b NVARCHAR(50) = N'x', @c INT OUTPUT AS
        #|BEGIN
        #|  SET NOCOUNT ON;
        #|  SET @c = @a
        #|END
      ),
    ),
    content=(
      #|(create-procedure dbo.p (params (@a INT) (@b NVARCHAR(50) (default N'x')) (@c INT output)) (block (set-option (NOCOUNT) ON) (set @c = @a)))
    ),
  )
  inspect(
    sx("CREATE OR ALTER PROC p AS SELECT 1 SELECT 2"),
    content=(
      #|(create-or-alter-procedure p (select 1) (select 2))
    ),
  )
  inspect(
    sx(
      "ALTER PROCEDURE p (@x INT = NULL, @t dbo.ids READONLY, @o INT OUT) WITH RECOMPILE, EXECUTE AS OWNER AS SELECT 2",
    ),
    content=(
      #|(alter-procedure p (params (@x INT (default NULL)) (@t dbo.ids readonly) (@o INT output)) (with 'RECOMPILE' 'EXECUTE AS OWNER') (select 2))
    ),
  )
  inspect(
    sx("CREATE PROC p AS"),
    content=(
      #|Msg 156, Level 15, State 1, Line 1: Incorrect syntax near the keyword 'AS'.
    ),
  )
  inspect(
    sx("SELECT 1; CREATE PROC p AS SELECT 1"),
    content=(
      #|Msg 111, Level 15, State 1, Line 1: 'CREATE/ALTER PROCEDURE' must be the first statement in a query batch.
    ),
  )
  inspect(
    sx(";CREATE PROC p AS SELECT 1"),
    content=(
      #|(create-procedure p (select 1))
    ),
  )
}

///|
test "functions" {
  inspect(
    sx(
      (
        #|CREATE FUNCTION dbo.add_tax(@amount DECIMAL(10,2), @rate INT = 20)
        #|RETURNS DECIMAL(10,2) AS
        #|BEGIN
        #|  DECLARE @result DECIMAL(10,2) = @amount + @amount * @rate / 100
        #|  RETURN @result
        #|END
      ),
    ),
    content=(
      #|(create-function dbo.add_tax (params (@amount DECIMAL(10,2)) (@rate INT (default 20))) (returns DECIMAL(10,2)) (declare (@result DECIMAL(10,2) (+ @amount (/ (* @amount @rate) 100)))) (return @result))
    ),
  )
  inspect(
    sx(
      (
        #|CREATE OR ALTER FUNCTION dbo.orders_for(@customer INT)
        #|RETURNS TABLE AS RETURN (
        #|  SELECT id, amount FROM orders WHERE customer_id = @customer
        #|)
      ),
    ),
    content=(
      #|(create-or-alter-function dbo.orders_for (params (@customer INT)) (returns-table (select id amount (from (table orders)) (where (= customer_id @customer)))))
    ),
  )
  inspect(
    sx("CREATE FUNCTION f() RETURNS TABLE RETURN SELECT 1 AS a"),
    content=(
      #|(create-function f (returns-table (select (as 1 a))))
    ),
  )
  inspect(
    sx(
      "CREATE FUNCTION dbo.mt(@n int) RETURNS @t TABLE(i int NOT NULL, s varchar(5) DEFAULT 'd') AS BEGIN INSERT @t VALUES (@n, 'a'); IF @n > 5 INSERT INTO @t(i) SELECT @n + 1; RETURN; END",
    ),
    content=(
      #|(create-function dbo.mt (params (@n int)) (returns @t (table (column i int not-null) (column s varchar(5) (default 'd')))) (insert (table @t) (values (@n 'a'))) (if (> @n 5) (insert (table @t) (i) (select (+ @n 1)))) (return))
    ),
  )
  inspect(
    sx(
      "CREATE FUNCTION dbo.nn(@x int) RETURNS int WITH RETURNS NULL ON NULL INPUT AS BEGIN RETURN ISNULL(@x, 42) END",
    ),
    content=(
      #|(create-function dbo.nn (params (@x int)) (with 'RETURNS NULL ON NULL INPUT') (returns int) (return (call ISNULL @x 42)))
    ),
  )
  inspect(
    sx(
      "CREATE FUNCTION dbo.cn(@x int) RETURNS int WITH SCHEMABINDING, CALLED ON NULL INPUT, EXECUTE AS CALLER AS BEGIN RETURN ISNULL(@x, 42) END",
    ),
    content=(
      #|(create-function dbo.cn (params (@x int)) (with 'SCHEMABINDING' 'CALLED ON NULL INPUT' 'EXECUTE AS CALLER') (returns int) (return (call ISNULL @x 42)))
    ),
  )
  inspect(
    sx("CREATE FUNCTION f() RETURNS INT AS RETURN 1"),
    content=(
      #|Msg 156, Level 15, State 1, Line 1: Incorrect syntax near the keyword 'RETURN'.
    ),
  )
  inspect(
    sx("CREATE FUNCTION f() RETURNS INT AS BEGIN RETURN 1 END SELECT 1"),
    content=(
      #|Msg 156, Level 15, State 1, Line 1: Incorrect syntax near the keyword 'SELECT'.
    ),
  )
  inspect(
    sx("PRINT 1\nCREATE FUNCTION f() RETURNS INT AS BEGIN RETURN 1 END"),
    content=(
      #|Msg 111, Level 15, State 1, Line 2: 'CREATE FUNCTION' must be the first statement in a query batch.
    ),
  )
}

///|
test "triggers" {
  inspect(
    sx(
      (
        #|CREATE OR ALTER TRIGGER dbo.audit_orders ON dbo.orders
        #|WITH EXECUTE AS OWNER
        #|AFTER INSERT, UPDATE WITH APPEND NOT FOR REPLICATION AS
        #|BEGIN
        #|  INSERT INTO audit (id) SELECT id FROM inserted
        #|END
      ),
    ),
    content=(
      #|(create-or-alter-trigger dbo.audit_orders (on dbo.orders) after (insert update) (with 'EXECUTE AS OWNER' 'APPEND') not-for-replication (block (insert (table audit) (id) (select id (from (table inserted))))))
    ),
  )
  inspect(
    sx(
      "ALTER TRIGGER t ON dbo.orders INSTEAD OF DELETE AS SELECT * FROM deleted",
    ),
    content=(
      #|(alter-trigger t (on dbo.orders) instead-of (delete) (select * (from (table deleted))))
    ),
  )
  inspect(
    sx(
      "CREATE TRIGGER tr ON t FOR INSERT, UPDATE, DELETE AS IF UPDATE(a) BEGIN RAISERROR('no', 16, 1); ROLLBACK TRANSACTION; END",
    ),
    content=(
      #|(create-trigger tr (on t) for (insert update delete) (if (call UPDATE a) (block (raiserror 'no' 16 1) (rollback))))
    ),
  )
}

///|
test "schema type sequence permissions" {
  inspect(
    sx("CREATE SCHEMA app AUTHORIZATION dbo"),
    content=(
      #|(create-schema app (authorization dbo))
    ),
  )
  inspect(
    sx("SELECT 1\nCREATE SCHEMA app"),
    content=(
      #|Msg 111, Level 15, State 1, Line 2: 'CREATE SCHEMA' must be the first statement in a query batch.
    ),
  )
  inspect(
    sx("CREATE TYPE dbo.ids AS TABLE (id INT NOT NULL PRIMARY KEY)"),
    content=(
      #|(create-type dbo.ids (table (column id INT not-null (primary-key))))
    ),
  )
  inspect(
    sx("CREATE TYPE dbo.phone FROM varchar(20) NOT NULL"),
    content=(
      #|(create-type dbo.phone (from varchar(20)) not-null)
    ),
  )
  inspect(
    sx(
      "CREATE SEQUENCE dbo.s AS INT START WITH 10 INCREMENT BY -5 MINVALUE 10 MAXVALUE 100 NO CYCLE CACHE 8",
    ),
    content=(
      #|(create-sequence dbo.s (as INT) 'START WITH 10' 'INCREMENT BY -5' 'MINVALUE 10' 'MAXVALUE 100' 'NO CYCLE' 'CACHE 8')
    ),
  )
  inspect(
    sx(
      "GRANT SELECT, INSERT ON dbo.t TO app_user, [other role] WITH GRANT OPTION",
    ),
    content=(
      #|(grant 'SELECT' 'INSERT' (on dbo.t) (to app_user [other role]) with-grant-option)
    ),
  )
  inspect(
    sx("GRANT EXECUTE ON SCHEMA::dbo TO app_user"),
    content=(
      #|(grant 'EXECUTE' (on SCHEMA::dbo) (to app_user))
    ),
  )
  inspect(
    sx("GRANT VIEW DEFINITION TO public"),
    content=(
      #|(grant 'VIEW DEFINITION' (to public))
    ),
  )
  inspect(
    sx("DENY DELETE ON OBJECT::dbo.t TO app_user CASCADE"),
    content=(
      #|(deny 'DELETE' (on OBJECT::dbo.t) (to app_user) cascade)
    ),
  )
  inspect(
    sx("REVOKE GRANT OPTION FOR SELECT ON t FROM app_user CASCADE"),
    content=(
      #|(revoke 'SELECT' (on t) (to app_user) cascade)
    ),
  )
  inspect(
    sx("GRANT CREATE TABLE, ALTER ANY SCHEMA TO dev"),
    content=(
      #|(grant 'CREATE TABLE' 'ALTER ANY SCHEMA' (to dev))
    ),
  )
}

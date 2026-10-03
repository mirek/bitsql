///|
/// Typical migration / generated-script shapes, split on GO first.
fn script(src : String) -> String {
  @lex.split_go_batches(src).map(sx).join("\n--\n")
}

///|
test "SSMS-style generated script" {
  inspect(
    script(
      (
        #|SET ANSI_NULLS ON
        #|GO
        #|SET QUOTED_IDENTIFIER ON
        #|GO
        #|IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[t]') AND type in (N'U'))
        #|BEGIN
        #|CREATE TABLE [dbo].[t](
        #|	[id] [int] IDENTITY(1,1) NOT NULL,
        #|	[name] [nvarchar](50) NULL,
        #| CONSTRAINT [PK_t] PRIMARY KEY CLUSTERED
        #|(
        #|	[id] ASC
        #|)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
        #|) ON [PRIMARY]
        #|END
        #|GO
        #|ALTER TABLE [dbo].[t] ADD  CONSTRAINT [DF_t_name]  DEFAULT (N'') FOR [name]
        #|GO
        #|IF OBJECT_ID(N'dbo.p') IS NULL EXEC('CREATE PROCEDURE dbo.p AS RETURN 0')
        #|GO
        #|ALTER PROCEDURE dbo.p
        #|  @id INT
        #|AS
        #|BEGIN
        #|  SET NOCOUNT ON;
        #|  ;WITH c AS (SELECT id, ROW_NUMBER() OVER (ORDER BY id) AS rn FROM dbo.t)
        #|  SELECT id FROM c WHERE rn = 1 AND id = @id;
        #|  IF @@ROWCOUNT = 0 RAISERROR('missing %d', 16, 1, @id);
        #|  RETURN
        #|END
        #|GO
      ),
    ),
    content=(
      #|(set-option (ANSI_NULLS) ON)
      #|--
      #|(set-option (QUOTED_IDENTIFIER) ON)
      #|--
      #|(if (not (exists (select * (from (table sys.objects)) (where (and (= object_id (call OBJECT_ID N'[dbo].[t]')) (in type N'U')))))) (block (create-table [dbo].[t] (column [id] int not-null (identity 1 1)) (column [name] nvarchar(50) null) (constraint [PK_t] (primary-key clustered ([id]) (with PAD_INDEX=OFF STATISTICS_NORECOMPUTE=OFF IGNORE_DUP_KEY=OFF ALLOW_ROW_LOCKS=ON ALLOW_PAGE_LOCKS=ON))) (on [PRIMARY]))))
      #|--
      #|(alter-table [dbo].[t] (add (constraint [DF_t_name] (default (paren N'') (for [name])))))
      #|--
      #|(if (is-null (call OBJECT_ID N'dbo.p')) (exec-string 'CREATE PROCEDURE dbo.p AS RETURN 0'))
      #|--
      #|(alter-procedure dbo.p (params (@id INT)) (block (set-option (NOCOUNT) ON) (query (with (c (select id (as (call ROW_NUMBER (over (order-by id))) rn) (from (table dbo.t))))) (select id (from (table c)) (where (and (= rn 1) (= id @id))))) (if (= @@ROWCOUNT 0) (raiserror 'missing %d' 16 1 @id)) (return)))
    ),
  )
}

///|
test "misc shapes" {
  inspect(
    sx("SELECT COUNT(*) OVER () AS total, @@IDENTITY, SCOPE_IDENTITY()"),
    content=(
      #|(select (as (call COUNT * (over)) total) @@IDENTITY (call SCOPE_IDENTITY))
    ),
  )
  inspect(
    sx("SELECT COALESCE((SELECT MAX(id) FROM t), 0) + 1"),
    content=(
      #|(select (+ (call COALESCE (subquery (select (call MAX id) (from (table t)))) 0) 1))
    ),
  )
  inspect(
    sx(
      "SELECT CASE WHEN EXISTS (SELECT 1 FROM t) THEN 1 ELSE 0 END AS has_rows",
    ),
    content=(
      #|(select (as (case (when (exists (select 1 (from (table t)))) 1) (else 0)) has_rows))
    ),
  )
  inspect(
    sx("SELECT offset FROM t ORDER BY offset OFFSET 1 ROWS"),
    content=(
      #|(query (select offset (from (table t))) (order-by offset) (offset 1))
    ),
  )
  inspect(
    sx("SELECT a FROM t WHERE NOT (a = 1) AND b LIKE '%' + @p + '%'"),
    content=(
      #|(select a (from (table t)) (where (and (not (paren (= a 1))) (like b (+ (+ '%' @p) '%')))))
    ),
  )
  inspect(
    sx(
      "UPDATE t SET x = x + 1 OUTPUT inserted.x INTO @o(x) WHERE id = @id OPTION (RECOMPILE)",
    ),
    content=(
      #|(update (table t) (set (= x (+ x 1))) (output inserted.x (into (table @o) (x))) (where (= id @id)) (option 'RECOMPILE'))
    ),
  )
  inspect(
    sx("EXEC sys.sp_rename 'dbo.t.a', 'b', 'COLUMN'"),
    content=(
      #|(exec sys.sp_rename 'dbo.t.a' 'b' 'COLUMN')
    ),
  )
  inspect(
    sx("SELECT a.b.c.d.e FROM t"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near 'e'.
    ),
  )
  inspect(
    sx("IF @x = 1 RETURN\nSELECT 1"),
    content=(
      #|(if (= @x 1) (return))
      #|(select 1)
    ),
  )
  inspect(
    sx("SELECT TOP (1) WITH TIES a FROM t ORDER BY a"),
    content=(
      #|(query (select (top 1 with-ties) a (from (table t))) (order-by a))
    ),
  )
}

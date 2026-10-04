// knex 3 (mssql dialect, tedious): migrations with the lock tables, the schema
// builder (every column type, indexes, foreign keys, alterTable, dropTable),
// introspection helpers, CRUD with `returning`, batch inserts, joins,
// aggregates, raw queries, transactions with savepoints and isolation levels.
import knexFactory from 'knex'

const migrations = {
  '001_create_core': {
    async up(knex) {
      await knex.schema.createTable('accounts', t => {
        t.increments('id').primary()
        t.string('email', 120).notNullable().unique({ indexName: 'accounts_email_unique' })
        t.string('name').notNullable()
        t.text('bio')
        t.integer('age').unsigned()
        t.bigInteger('big')
        t.tinyint('tiny')
        t.smallint('small')
        t.mediumint('medium')
        t.float('ratio')
        t.double('score')
        t.decimal('balance', 12, 2).notNullable().defaultTo(0)
        t.boolean('active').notNullable().defaultTo(true)
        t.date('born')
        t.datetime('seen_at', { precision: 3 })
        t.time('alarm')
        t.timestamp('stamped', { useTz: true })
        t.binary('blob', 16)
        t.enu('role', ['admin', 'member', 'guest']).defaultTo('member')
        t.json('prefs')
        t.jsonb('meta')
        t.uuid('external_id')
        t.specificType('wallet', 'money')
        t.string('code', 10).comment('short code')
        t.timestamps(true, true)
        t.index(['name', 'age'], 'accounts_name_age_index')
      })
      await knex.schema.createTable('projects', t => {
        t.bigIncrements('id')
        t.integer('owner_id').unsigned().notNullable()
          .references('id').inTable('accounts').onDelete('CASCADE').withKeyName('projects_owner_fk')
        t.string('title', 200).notNullable()
        t.integer('stars').notNullable().defaultTo(0)
        t.index('owner_id', 'projects_owner_index')
      })
      await knex.schema.createTable('labels', t => {
        t.increments('id')
        t.string('name', 50).notNullable()
      })
      await knex.schema.createTable('project_labels', t => {
        t.bigInteger('project_id').notNullable().references('projects.id').onDelete('CASCADE')
        t.integer('label_id').unsigned().notNullable().references('labels.id')
        t.primary(['project_id', 'label_id'])
      })
    },
    async down(knex) {
      await knex.schema.dropTable('project_labels')
      await knex.schema.dropTable('labels')
      await knex.schema.dropTable('projects')
      await knex.schema.dropTable('accounts')
    },
  },
  '002_alter': {
    async up(knex) {
      await knex.schema.alterTable('accounts', t => {
        t.string('nickname', 40).nullable()
        t.renameColumn('bio', 'about')
        t.dropColumn('medium')
        t.string('code', 20).alter()
        t.dropIndex(['name', 'age'], 'accounts_name_age_index')
        t.index(['email', 'name'], 'accounts_email_name_index')
      })
      await knex.schema.alterTable('projects', t => {
        t.dropForeign('owner_id', 'projects_owner_fk')
        t.foreign('owner_id', 'projects_owner_fk2').references('accounts.id').onDelete('NO ACTION')
        t.dropColumn('stars')
      })
      await knex.schema.createTable('scratch', t => { t.increments(); t.string('x') })
    },
    async down(knex) {
      await knex.schema.dropTable('scratch')
    },
  },
  '003_drop_scratch': {
    async up(knex) { await knex.schema.dropTableIfExists('scratch') },
    async down() {},
  },
}

function source(names) {
  return {
    getMigrations: async () => names,
    getMigrationName: m => m,
    getMigration: async m => migrations[m],
  }
}

let knexRaw

export default async function knexWorkload(t, trace) {
  const db = knexFactory({
    client: 'mssql',
    connection: {
      server: t.host, port: t.port, user: t.user, password: t.password, database: t.database,
      options: { encrypt: t.encrypt, trustServerCertificate: true },
      requestTimeout: 60000,
    },
    pool: { min: 0, max: 3 },
  })
  db.on('query', q => trace.logSql(q.sql))
  const step = trace.step.bind(trace)
  knexRaw = sql => db.raw(sql)
  try {
    await step('server version', () => db.raw("SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS int) AS major"))
    await step('migrate.latest 001', () => db.migrate.latest({ migrationSource: source(['001_create_core']) }))
    await step('migrate.status', () => db.migrate.currentVersion({ migrationSource: source(['001_create_core']) }))
    await step('hasTable accounts', () => db.schema.hasTable('accounts'))
    await step('hasTable missing', () => db.schema.hasTable('nope'))
    await step('hasColumn', () => db.schema.hasColumn('accounts', 'email'))
    await step('columnInfo accounts', () => db('accounts').columnInfo())
    await step('columnInfo projects.owner_id', () => db('projects').columnInfo('owner_id'))
    await step('migrate.latest 002+003', () => db.migrate.latest({ migrationSource: source(['001_create_core', '002_alter', '003_drop_scratch']) }))
    await step('columnInfo after alter', () => db('accounts').columnInfo())
    await step('migrations table', () => db('knex_migrations').select('id', 'name', 'batch').orderBy('id'))
    await step('migrations lock', () => db('knex_migrations_lock').select('*'))
    await step('forceFreeMigrationsLock', () => db.migrate.forceFreeMigrationsLock({ migrationSource: source([]) }))

    // CRUD with returning
    await step('insert returning *', () => db('accounts').insert({
      email: 'ada@example.com', name: 'Ada', about: 'first', age: 36, big: '9007199254740993', tiny: 7, small: -3,
      ratio: 0.5, score: 1.25, balance: '10.50', active: true, born: '1815-12-10', seen_at: new Date('2020-01-02T03:04:05.678Z'),
      alarm: '07:30:00', stamped: new Date('2021-06-01T12:00:00Z'), blob: knexRaw('0x00ff10'), role: 'admin',
      prefs: JSON.stringify({ theme: 'dark' }), meta: JSON.stringify([1, 2]), external_id: '7d444840-9dc0-11d1-b245-5ffdce74fad2',
      wallet: 12.3456, code: 'A1', nickname: 'ada',
    }).returning('*'))
    await step('batch insert returning id', () => db('accounts').insert([
      { email: 'bob@example.com', name: 'Bob', age: 40, balance: 5 },
      { email: 'cy@example.com', name: 'Cy', age: 22, balance: 7.25, role: 'guest' },
      { email: 'di@example.com', name: 'Di', age: null, balance: 0, active: false },
    ]).returning(['id', 'email']))
    await step('batchInsert chunked', () => db.batchInsert('labels', Array.from({ length: 7 }, (_, i) => ({ name: `label-${i}` })), 3).returning('id'))
    await step('insert projects', () => db('projects').insert([
      { owner_id: 1, title: 'Engine' }, { owner_id: 1, title: 'Notes' }, { owner_id: 2, title: 'Boat' },
    ]).returning(['id', 'owner_id']))
    await step('insert project_labels', () => db('project_labels').insert([
      { project_id: 1, label_id: 1 }, { project_id: 1, label_id: 2 }, { project_id: 2, label_id: 2 }, { project_id: 3, label_id: 3 },
    ]))
    await step('unique violation', () => db('accounts').insert({ email: 'ada@example.com', name: 'dup' }))
    await step('fk violation', () => db('projects').insert({ owner_id: 999, title: 'orphan' }))
    await step('enum check violation', () => db('accounts').insert({ email: 'x@example.com', name: 'X', role: 'root' }))
    await step('select all', () => db('accounts').select('id', 'email', 'name', 'about', 'age', 'big', 'tiny', 'small', 'ratio', 'score', 'balance', 'active', 'born', 'seen_at', 'alarm', 'stamped', 'blob', 'role', 'prefs', 'meta', 'external_id', 'wallet', 'code', 'nickname').orderBy('id'))
    await step('first', () => db('accounts').where({ email: 'bob@example.com' }).first('id', 'name'))
    await step('where in / not null / like', () => db('accounts').whereIn('id', [1, 2, 3]).whereNotNull('age').where('name', 'like', '%a%').select('id'))
    await step('limit offset', () => db('accounts').select('id', 'name').orderBy('name', 'desc').limit(2).offset(1))
    await step('limit only', () => db('accounts').select('id').orderBy('id').limit(2))
    await step('offset only', () => db('accounts').select('id').orderBy('id').offset(2))
    await step('join + groupBy + having', () => db('accounts as a')
      .join('projects as p', 'p.owner_id', 'a.id')
      .leftJoin('project_labels as pl', 'pl.project_id', 'p.id')
      .groupBy('a.id', 'a.name')
      .having(db.raw('count(pl.label_id)'), '>', 0)
      .select('a.id', 'a.name')
      .count({ labels: 'pl.label_id' })
      .countDistinct({ projects: 'p.id' })
      .orderBy('a.id'))
    await step('aggregates', () => db('accounts').sum({ total: 'balance' }).avg({ mean: 'age' }).min({ lo: 'age' }).max({ hi: 'age' }).count({ n: '*' }))
    await step('distinct + subquery', () => db('accounts').distinct('role').whereIn('id', db('projects').select('owner_id')).orderBy('role'))
    await step('union', () => db('accounts').select('name').where('id', 1).union(db('labels').select('name').where('id', 1)).orderBy('name'))
    await step('cte', () => db.with('rich', qb => qb.select('id', 'balance').from('accounts').where('balance', '>', 1)).select('*').from('rich').orderBy('id'))
    await step('json path', () => db('accounts').select(db.raw("JSON_VALUE(prefs, '$.theme') AS theme")).where('id', 1))
    await step('update returning', () => db('accounts').where({ id: 2 }).update({ balance: db.raw('balance + ?', [1]), nickname: 'bobby' }, ['id', 'balance', 'nickname']))
    await step('increment', () => db('accounts').where('id', 3).increment('age', 2))
    await step('decrement returning', () => db('accounts').where('id', 3).decrement({ age: 1 }).returning('age'))
    await step('delete returning', () => db('labels').where('id', '>', 5).del(['id', 'name']))
    await step('upsert onConflict (unsupported by knex mssql)', () => db('labels').insert([{ id: 1, name: 'one' }]).onConflict('id').merge())
    // knex binds a Buffer in a way tedious 20 serializes as a truncated RPC
    // parameter: SQL Server answers 4002 (protocol stream incorrect).
    await step('buffer binding (malformed RPC)', () => db.raw('SELECT ? AS b', [Buffer.from('00ff10', 'hex')]))
    await step('connection usable after 4002', () => db.raw('SELECT 1 AS ok'))
    await step('raw select with bindings', () => db.raw('SELECT ? AS a, ? AS b, CAST(? AS decimal(10,3)) AS c, ? AS d', [1, 'two', 3.5, null]))
    await step('raw named bindings', () => db.raw('SELECT :x AS x, :y AS y', { x: 10, y: 'why' }))
    await step('raw multi statement', () => db.raw('SELECT 1 AS one; SELECT 2 AS two'))
    await step('raw error', () => db.raw('SELECT * FROM does_not_exist'))
    await step('raw syntax error', () => db.raw('SELEC 1'))

    // transactions
    await step('transaction commit', () => db.transaction(async trx => {
      await trx('labels').insert({ name: 'trx-1' })
      const [{ n }] = await trx('labels').count({ n: '*' })
      return n
    }))
    await step('transaction rollback on throw', async () => {
      try {
        await db.transaction(async trx => {
          await trx('labels').insert({ name: 'trx-2' })
          throw new Error('boom')
        })
      } catch (error) { return { rolledBack: error.message } }
    })
    await step('after rollback', () => db('labels').where('name', 'like', 'trx-%').select('name').orderBy('name'))
    await step('nested savepoint', () => db.transaction(async trx => {
      await trx('labels').insert({ name: 'outer' })
      try {
        await trx.transaction(async inner => {
          await inner('labels').insert({ name: 'inner' })
          throw new Error('inner boom')
        })
      } catch {}
      return trx('labels').whereIn('name', ['outer', 'inner']).select('name').orderBy('name')
    }))
    await step('transaction sql error', async () => {
      try {
        await db.transaction(async trx => {
          await trx('labels').insert({ name: 'before-error' })
          await trx('accounts').insert({ email: 'ada@example.com', name: 'dup' })
        })
      } catch (error) { return { number: error.number } }
    })
    await step('isolation serializable', () => db.transaction(async trx => {
      const r = await trx.raw("SELECT CASE transaction_isolation_level WHEN 4 THEN 'serializable' ELSE 'other' END AS level FROM sys.dm_exec_sessions WHERE session_id = @@SPID")
      return r
    }, { isolationLevel: 'serializable' }))
    await step('isolation read committed restored', () => db.raw('SELECT transaction_isolation_level AS level FROM sys.dm_exec_sessions WHERE session_id = @@SPID'))
    await step('explicit trx object', async () => {
      const trx = await db.transaction()
      try { await trx('labels').insert({ name: 'manual' }) } finally { await trx.rollback() }
      return db('labels').where('name', 'manual').count({ n: '*' })
    })

    // schema helpers on populated tables
    await step('renameTable', () => db.schema.renameTable('labels', 'tags'))
    await step('hasTable renamed', () => db.schema.hasTable('tags'))
    await step('createView', () => db.schema.createView('account_names', v => { v.columns(['id', 'name']); v.as(db('accounts').select('id', 'name')) }))
    await step('select view', () => db('account_names').orderBy('id'))
    await step('dropView', () => db.schema.dropView('account_names'))
    await step('createTableLike', () => db.schema.createTableLike('accounts_copy', 'accounts'))
    await step('copy columns', () => db('accounts_copy').columnInfo())
    await step('dropTableIfExists', () => db.schema.dropTableIfExists('accounts_copy'))
    await step('createSchema + table in schema', async () => {
      await db.raw('CREATE SCHEMA audit')
      await db.schema.withSchema('audit').createTable('events', t => { t.increments(); t.string('kind').notNullable() })
      await db.withSchema('audit').table('events').insert({ kind: 'login' })
      return db.withSchema('audit').from('events').select('*')
    })
    await step('hasTable in schema', () => db.schema.withSchema('audit').hasTable('events'))
    await step('renameTable back', () => db.schema.renameTable('tags', 'labels'))
    await step('truncate', () => db('project_labels').truncate())
    await step('migrate.rollback all', () => db.migrate.rollback({ migrationSource: source(['001_create_core', '002_alter', '003_drop_scratch']) }, true))
    // tedious sets the isolation level for the transaction and does not reset
    // it: the pooled connection keeps SNAPSHOT afterwards (3952 on next use).
    await step('snapshot isolation not allowed', () => db.transaction(async trx => trx.raw('SELECT 1 AS x'), { isolationLevel: 'snapshot' }))
    await step('tables left', () => db.raw("SELECT TABLE_SCHEMA, TABLE_NAME FROM INFORMATION_SCHEMA.TABLES ORDER BY TABLE_SCHEMA, TABLE_NAME"))
  } finally {
    await db.destroy()
  }
}

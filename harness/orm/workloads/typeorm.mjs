// TypeORM (mssql driver over the `mssql` package): migration generation
// (the schema builder's diff against the live catalog, i.e. what
// `typeorm migration:generate` writes), running migrations, a second diff
// that must come out empty, `synchronize`, repositories with relations,
// the query builder (joins, pagination, OUTPUT returning), transactions with
// isolation levels, query runners, soft delete, upsert (MERGE) and raw SQL.
import 'reflect-metadata'
import { DataSource, EntitySchema } from 'typeorm'

function entities(version) {
  const v2 = version >= 2
  const v3 = version >= 3
  const Author = new EntitySchema({
    name: 'Author', tableName: 'authors',
    columns: {
      id: { type: 'int', primary: true, generated: 'increment' },
      name: { type: 'nvarchar', length: 100 },
      email: { type: 'varchar', length: 120, unique: true },
      bio: { type: 'nvarchar', length: 'MAX', nullable: true },
      active: { type: 'bit', default: true },
      rating: { type: 'decimal', precision: 5, scale: 2, default: 0 },
      score: { type: 'float', nullable: true },
      born: { type: 'date', nullable: true },
      wakeUp: { type: 'time', nullable: true },
      seenAt: { type: 'datetime2', precision: 3, nullable: true },
      zoned: { type: 'datetimeoffset', nullable: true },
      legacy: { type: 'datetime', nullable: true },
      big: { type: 'bigint', nullable: true },
      small: { type: 'smallint', nullable: true },
      tiny: { type: 'tinyint', nullable: true },
      avatar: { type: 'varbinary', length: 64, nullable: true },
      token: { type: 'uniqueidentifier', nullable: true },
      kind: { type: 'simple-enum', enum: ['admin', 'member'], default: 'member' },
      prefs: { type: 'simple-json', nullable: true },
      tags: { type: 'simple-array', nullable: true },
      createdAt: { type: 'datetime2', createDate: true },
      updatedAt: { type: 'datetime2', updateDate: true },
      deletedAt: { type: 'datetime2', deleteDate: true, nullable: true },
      version: { type: 'int', version: true },
      ...(v2 ? { nickname: { type: 'nvarchar', length: 40, nullable: true }, money: { type: 'money', nullable: true } } : {}),
    },
    indices: [{ name: 'IDX_author_name', columns: ['name'] }, ...(v2 ? [{ name: 'IDX_author_name_email', columns: ['name', 'email'], unique: true }] : [])],
    relations: {
      books: { type: 'one-to-many', target: 'Book', inverseSide: 'author', cascade: true },
      profile: { type: 'one-to-one', target: 'Profile', joinColumn: { name: 'profileId' }, nullable: true, cascade: true, onDelete: 'SET NULL' },
    },
  })
  const Profile = new EntitySchema({
    name: 'Profile', tableName: 'profiles',
    columns: {
      id: { type: 'int', primary: true, generated: 'increment' },
      website: { type: 'nvarchar', length: v2 ? 300 : 200, nullable: true },
    },
  })
  const Book = new EntitySchema({
    name: 'Book', tableName: 'books',
    columns: {
      id: { type: 'int', primary: true, generated: 'increment' },
      title: { type: 'nvarchar', length: 200 },
      pages: { type: 'int', default: 0 },
      price: { type: 'decimal', precision: 8, scale: 2, nullable: true },
      ...(v3 ? { isbn: { type: 'varchar', length: 20, nullable: true } } : {}),
    },
    checks: [{ name: 'CHK_book_pages', expression: '"pages" >= 0' }],
    relations: {
      author: { type: 'many-to-one', target: 'Author', inverseSide: 'books', joinColumn: { name: 'authorId' }, onDelete: 'CASCADE', nullable: false },
      genres: { type: 'many-to-many', target: 'Genre', joinTable: { name: 'book_genres', joinColumn: { name: 'bookId' }, inverseJoinColumn: { name: 'genreId' } }, cascade: ['insert'] },
    },
  })
  const Genre = new EntitySchema({
    name: 'Genre', tableName: 'genres',
    columns: {
      id: { type: 'int', primary: true, generated: 'increment' },
      name: { type: 'nvarchar', length: 50, unique: true },
    },
  })
  const Event = new EntitySchema({
    name: 'Event', tableName: 'events', schema: v2 ? 'audit' : undefined,
    columns: {
      id: { type: 'uniqueidentifier', primary: true, generated: 'uuid' },
      kind: { type: 'varchar', length: 30 },
    },
  })
  return v2 ? [Author, Profile, Book, Genre, Event] : [Author, Profile, Book, Genre]
}

function logger(trace) {
  return {
    logQuery: q => trace.logSql(q),
    logQueryError: () => {},
    logQuerySlow: () => {},
    logSchemaBuild: () => {},
    logMigration: () => {},
    log: () => {},
  }
}

function migrationFrom(name, sql) {
  return class {
    constructor() { this.name = name }
    async up(qr) { for (const q of sql.upQueries) await qr.query(q.query, q.parameters) }
    async down(qr) { for (const q of [...sql.downQueries].reverse()) await qr.query(q.query, q.parameters) }
  }
}

const pending = sql => ({ up: sql.upQueries.map(q => q.query), down: sql.downQueries.map(q => q.query) })

export default async function typeormWorkload(t, trace) {
  const make = (version, extra = {}) => new DataSource({
    type: 'mssql',
    host: t.host, port: t.port, username: t.user, password: t.password, database: t.database,
    options: { encrypt: t.encrypt, trustServerCertificate: true },
    requestTimeout: 60000,
    pool: { max: 3, min: 0 },
    entities: entities(version),
    logging: true,
    logger: logger(trace),
    ...extra,
  })
  const step = trace.step.bind(trace)
  const sources = []
  const open = async (version, extra) => { const ds = make(version, extra); sources.push(ds); await ds.initialize(); return ds }
  try {
    let ds
    let generated
    await step('initialize v1', async () => { ds = await open(1); return ds.isInitialized })
    await step('server version', () => ds.query("SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS int) AS major"))
    await step('generate migration v1', async () => { generated = await ds.driver.createSchemaBuilder().log(); return pending(generated) })
    await ds.destroy()
    await step('run migration v1', async () => {
      ds = await open(1, { migrations: [migrationFrom('V1Init1700000000001', generated)], migrationsTableName: 'migrations' })
      return (await ds.runMigrations({ transaction: 'all' })).map(m => m.name)
    })
    await step('showMigrations', () => ds.showMigrations())
    await step('generate after v1 (empty)', async () => pending(await ds.driver.createSchemaBuilder().log()))
    await ds.destroy()

    await step('create schema audit', async () => { ds = await open(1); await ds.query('CREATE SCHEMA audit'); return ds.query("SELECT name FROM sys.schemas WHERE name = 'audit'") })
    await ds.destroy()
    await step('generate migration v2', async () => {
      ds = await open(2)
      generated = await ds.driver.createSchemaBuilder().log()
      return pending(generated)
    })
    await ds.destroy()
    await step('run migration v2', async () => {
      ds = await open(2, { migrations: [migrationFrom('V1Init1700000000001', { upQueries: [], downQueries: [] }), migrationFrom('V2Alter1700000000002', generated)], migrationsTableName: 'migrations' })
      return (await ds.runMigrations({ transaction: 'each' })).map(m => m.name)
    })
    await step('generate after v2 (empty)', async () => pending(await ds.driver.createSchemaBuilder().log()))
    await step('undoLastMigration v2', async () => { await ds.undoLastMigration({ transaction: 'all' }); return ds.query('SELECT name FROM migrations ORDER BY id') })
    await step('rerun migration v2', async () => (await ds.runMigrations()).map(m => m.name))
    await ds.destroy()

    await step('synchronize v3', async () => { ds = await open(3, { synchronize: true }); return ds.isInitialized })
    if (!ds.isInitialized) throw new Error('synchronize failed')
    await step('generate after synchronize (empty)', async () => pending(await ds.driver.createSchemaBuilder().log()))

    const authors = ds.getRepository('Author')
    const books = ds.getRepository('Book')
    const genres = ds.getRepository('Genre')
    const pick = a => a && ({ id: a.id, name: a.name, email: a.email, version: a.version, rating: a.rating, active: a.active, kind: a.kind, prefs: a.prefs, tags: a.tags })

    await step('save with cascades', async () => {
      const [g1, g2] = await genres.save([{ name: 'sci-fi' }, { name: 'poetry' }])
      const a = await authors.save({
        name: 'Ada', email: 'ada@example.com', bio: 'x'.repeat(5000), rating: '4.50', score: 0.125, born: '1815-12-10', wakeUp: '07:30:00',
        seenAt: new Date('2020-01-02T03:04:05.678Z'), zoned: new Date('2021-06-01T12:00:00Z'), legacy: new Date('2001-02-03T04:05:06.007Z'),
        big: '9007199254740993', small: -2, tiny: 200, avatar: Buffer.from('beef', 'hex'), token: '7D444840-9DC0-11D1-B245-5FFDCE74FAD2',
        kind: 'admin', prefs: { theme: 'dark' }, tags: ['a', 'b'], nickname: 'ada', money: '12.3456',
        profile: { website: 'https://example.com' },
        books: [{ title: 'Engine', pages: 100, price: '9.99', genres: [g1] }, { title: 'Notes', pages: 50, genres: [g1, g2] }],
      })
      return { ...pick(a), books: a.books.map(b => b.id), profile: a.profile.id }
    })
    await step('save second author', async () => pick(await authors.save({ name: 'Bob', email: 'bob@example.com', books: [{ title: 'Boat', pages: 10 }] })))
    await step('unique violation', () => authors.save({ name: 'Dup', email: 'ada@example.com' }))
    await step('check violation', () => books.insert({ title: 'neg', pages: -1, author: { id: 1 } }))
    await step('fk violation', () => books.insert({ title: 'orphan', pages: 1, author: { id: 999 } }))
    await step('find with relations', async () => (await authors.find({ relations: { books: { genres: true }, profile: true }, order: { id: 'ASC', books: { id: 'ASC', genres: { id: 'ASC' } } } }))
      .map(a => ({ ...pick(a), profile: a.profile?.website ?? null, books: a.books.map(b => ({ title: b.title, price: b.price, genres: b.genres.map(g => g.name) })) })))
    await step('findOne all columns', async () => {
      const a = await authors.findOne({ where: { email: 'ada@example.com' } })
      return { ...a, createdAt: typeof a.createdAt, updatedAt: typeof a.updatedAt, bio: a.bio.length }
    })
    await step('findAndCount skip take', async () => { const [rows, count] = await books.findAndCount({ order: { title: 'ASC' }, skip: 1, take: 2 }); return { count, titles: rows.map(b => b.title) } })
    await step('findAndCount with join + pagination', async () => {
      const [rows, count] = await authors.findAndCount({ relations: { books: true }, order: { id: 'DESC' }, skip: 0, take: 1 })
      return { count, rows: rows.map(a => ({ name: a.name, books: a.books.length })) }
    })
    await step('query builder join', () => ds.createQueryBuilder('Book', 'b')
      .innerJoin('b.author', 'a').leftJoin('b.genres', 'g')
      .select('a.name', 'author').addSelect('COUNT(DISTINCT b.id)', 'books').addSelect('COUNT(g.id)', 'genres')
      .groupBy('a.name').orderBy('a.name').getRawMany())
    await step('query builder getManyAndCount', async () => {
      const [rows, count] = await ds.createQueryBuilder('Author', 'a').leftJoinAndSelect('a.books', 'b').where('b.pages > :p', { p: 5 }).orderBy('a.id').skip(1).take(1).getManyAndCount()
      return { count, rows: rows.map(a => a.name) }
    })
    await step('query builder subquery + params', () => ds.createQueryBuilder('Author', 'a')
      .select(['a.id', 'a.name'])
      .where(qb => 'a.id IN ' + qb.subQuery().select('b.authorId').from('Book', 'b').where('b.pages >= :min').getQuery())
      .setParameter('min', 50).orderBy('a.id').getMany().then(r => r.map(pick)))
    await step('query builder insert returning', () => ds.createQueryBuilder().insert().into('Genre').values([{ name: 'drama' }, { name: 'horror' }]).returning(['id', 'name']).execute().then(r => ({ raw: r.raw, identifiers: r.identifiers })))
    await step('query builder update returning', () => ds.createQueryBuilder().update('Book').set({ pages: () => 'pages + 1' }).where('pages > :p', { p: 20 }).returning(['id', 'pages']).execute().then(r => ({ raw: r.raw, affected: r.affected })))
    await step('query builder delete', () => ds.createQueryBuilder().delete().from('Genre').where('name = :n', { n: 'horror' }).execute().then(r => ({ raw: r.raw, affected: r.affected })))
    await step('increment / decrement', async () => { await books.increment({ title: 'Boat' }, 'pages', 5); await books.decrement({ title: 'Boat' }, 'pages', 2); return (await books.findOneBy({ title: 'Boat' })).pages })
    await step('update + version', async () => { await authors.update({ email: 'bob@example.com' }, { nickname: 'bobby' }); const a = await authors.findOneBy({ email: 'bob@example.com' }); a.name = 'Robert'; const s = await authors.save(a); return { version: s.version, nickname: s.nickname } })
    await step('upsert', async () => { await genres.upsert([{ name: 'poetry' }, { name: 'essay' }], ['name']); return (await genres.find({ order: { name: 'ASC' } })).map(g => g.name) })
    await step('softDelete + withDeleted + restore', async () => {
      await authors.softDelete({ email: 'bob@example.com' })
      const visible = await authors.count()
      const all = await authors.count({ withDeleted: true })
      await authors.restore({ email: 'bob@example.com' })
      return { visible, all, after: await authors.count() }
    })
    await step('exists / countBy / sum', async () => ({ exists: await authors.exists({ where: { name: 'Ada' } }), count: await books.countBy({ pages: 50 }), sum: await books.sum('pages'), avg: await books.average('pages') }))
    await step('pessimistic locks', () => ds.transaction(async m => ({
      write: (await m.createQueryBuilder('Author', 'a').setLock('pessimistic_write').where('a.id = :id', { id: 1 }).getMany()).map(a => a.id),
      read: (await m.createQueryBuilder('Author', 'a').setLock('pessimistic_read').getMany()).length,
      skip: (await m.createQueryBuilder('Book', 'b').setLock('pessimistic_write').setOnLocked('skip_locked').getMany()).length,
    })))
    await step('optimistic lock mismatch', () => ds.transaction(async m => m.createQueryBuilder('Author', 'a').setLock('optimistic', 99).where('a.id = 1').getOne()))
    await step('raw query with params', () => ds.query('SELECT @0 AS a, @1 AS b, title FROM books WHERE pages > @0 ORDER BY title', [20, 'two']))
    await step('raw query error', () => ds.query('SELECT nope FROM books'))
    await step('transaction serializable', () => ds.transaction('SERIALIZABLE', async m => {
      await m.getRepository('Genre').save({ name: 'trx' })
      return m.query('SELECT transaction_isolation_level AS level, @@TRANCOUNT AS tc FROM sys.dm_exec_sessions WHERE session_id = @@SPID')
    }))
    await step('transaction rollback', async () => {
      try { await ds.transaction(async m => { await m.getRepository('Genre').save({ name: 'trx-bad' }); throw new Error('boom') }) } catch (e) { return { message: e.message, left: await genres.countBy({ name: 'trx-bad' }) } }
    })
    await step('transaction sql error', async () => {
      try { await ds.transaction(async m => { await m.getRepository('Genre').save({ name: 'trx-2' }); await m.getRepository('Genre').insert({ name: 'drama' }) }) } catch (e) { return { number: e.driverError?.number ?? e.number, left: await genres.countBy({ name: 'trx-2' }) } }
    })
    await step('query runner manual transaction', async () => {
      const qr = ds.createQueryRunner()
      await qr.connect()
      try {
        await qr.startTransaction('READ UNCOMMITTED')
        await qr.manager.getRepository('Genre').save({ name: 'qr' })
        const inside = await qr.manager.getRepository('Genre').countBy({ name: 'qr' })
        await qr.rollbackTransaction()
        return { inside, after: await genres.countBy({ name: 'qr' }) }
      } finally { await qr.release() }
    })
    await step('query runner introspection', async () => {
      const qr = ds.createQueryRunner()
      try {
        const table = await qr.getTable('books')
        return {
          columns: table.columns.map(c => ({ name: c.name, type: c.type, length: c.length, precision: c.precision, scale: c.scale, nullable: c.isNullable, default: c.default, generated: c.isGenerated, primary: c.isPrimary, unique: c.isUnique })),
          indices: table.indices.map(i => ({ name: i.name, columns: i.columnNames, unique: i.isUnique })),
          foreignKeys: table.foreignKeys.map(f => ({ name: f.name, columns: f.columnNames, ref: f.referencedTableName, onDelete: f.onDelete })),
          checks: table.checks.map(c => ({ name: c.name, expression: c.expression })),
          hasTable: await qr.hasTable('authors'), hasColumn: await qr.hasColumn('books', 'title'), hasDb: await qr.hasDatabase(t.database),
          schemas: await qr.hasSchema('audit'),
        }
      } finally { await qr.release() }
    })
    await step('query runner DDL', async () => {
      const qr = ds.createQueryRunner()
      try {
        const { Table, TableColumn, TableIndex } = await import('typeorm')
        await qr.createTable(new Table({ name: 'scratch', columns: [{ name: 'id', type: 'int', isPrimary: true, isGenerated: true, generationStrategy: 'increment' }, { name: 'x', type: 'nvarchar', length: '10', isNullable: true }] }))
        await qr.addColumn('scratch', new TableColumn({ name: 'y', type: 'int', default: 5 }))
        await qr.changeColumn('scratch', 'x', new TableColumn({ name: 'x2', type: 'nvarchar', length: '20', isNullable: true }))
        await qr.createIndex('scratch', new TableIndex({ name: 'IDX_scratch_y', columnNames: ['y'] }))
        await qr.renameTable('scratch', 'scratch2')
        const tbl = await qr.getTable('scratch2')
        await qr.dropTable('scratch2')
        return tbl.columns.map(c => `${c.name}:${c.type}:${c.length}:${c.default}`)
      } finally { await qr.release() }
    })
    await step('clear', async () => { await ds.getRepository('Event').clear(); return ds.getRepository('Event').count() })
    await step('dropDatabase schema', async () => { await ds.dropDatabase(); return ds.query("SELECT COUNT(*) AS n FROM sys.tables WHERE is_ms_shipped = 0") })
  } finally {
    for (const ds of sources) if (ds.isInitialized) await ds.destroy().catch(() => {})
  }
}

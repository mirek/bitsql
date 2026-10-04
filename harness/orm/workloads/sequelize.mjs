// sequelize 6 (mssql dialect, tedious): sync({ force }) and sync({ alter })
// (which reads the catalog to diff), associations with include,
// paranoid + timestamps, CRUD, bulkCreate, findAndCountAll with limit/offset,
// upsert (MERGE), managed and unmanaged transactions with isolation levels,
// queryInterface introspection (showAllSchemas, describeTable, showIndex,
// getForeignKeyReferencesForTable).
import { Sequelize, DataTypes, Op, Transaction } from 'sequelize'

function define(sequelize, { v2 = false } = {}) {
  const User = sequelize.define('User', {
    id: { type: DataTypes.INTEGER, primaryKey: true, autoIncrement: true },
    email: { type: DataTypes.STRING(120), allowNull: false, unique: 'users_email_unique' },
    name: { type: DataTypes.STRING, allowNull: false },
    age: { type: DataTypes.INTEGER },
    karma: { type: DataTypes.BIGINT, defaultValue: 0 },
    balance: { type: DataTypes.DECIMAL(10, 2), defaultValue: 0 },
    ratio: { type: DataTypes.FLOAT },
    score: { type: DataTypes.DOUBLE },
    active: { type: DataTypes.BOOLEAN, defaultValue: true },
    born: { type: DataTypes.DATEONLY },
    seenAt: { type: DataTypes.DATE },
    bio: { type: DataTypes.TEXT },
    avatar: { type: DataTypes.BLOB },
    token: { type: DataTypes.UUID },
    kind: { type: DataTypes.ENUM('admin', 'member') , defaultValue: 'member' },
    ...(v2 ? { nickname: { type: DataTypes.STRING(40), allowNull: true }, level: { type: DataTypes.SMALLINT, allowNull: false, defaultValue: 1 } } : {}),
  }, { tableName: 'users', indexes: [{ name: 'users_name_age', fields: ['name', 'age'] }] })

  const Post = sequelize.define('Post', {
    title: { type: DataTypes.STRING(200), allowNull: false },
    body: { type: v2 ? DataTypes.TEXT : DataTypes.STRING(1000) },
    views: { type: DataTypes.INTEGER, allowNull: false, defaultValue: 0 },
  }, { tableName: 'posts', paranoid: true })

  const Tag = sequelize.define('Tag', {
    name: { type: DataTypes.STRING(50), allowNull: false, unique: true },
  }, { tableName: 'tags', timestamps: false })

  User.hasMany(Post, { foreignKey: { name: 'userId', allowNull: false }, as: 'posts', onDelete: 'CASCADE' })
  Post.belongsTo(User, { foreignKey: 'userId', as: 'author' })
  Post.belongsToMany(Tag, { through: 'post_tags', as: 'tags', foreignKey: 'postId', otherKey: 'tagId', timestamps: false })
  Tag.belongsToMany(Post, { through: 'post_tags', as: 'posts', foreignKey: 'tagId', otherKey: 'postId', timestamps: false })
  return { User, Post, Tag }
}

function plain(x) {
  if (Array.isArray(x)) return x.map(plain)
  if (x && typeof x.get === 'function') return x.get({ plain: true })
  return x
}

export default async function sequelizeWorkload(t, trace) {
  const make = () => new Sequelize(t.database, t.user, t.password, {
    dialect: 'mssql',
    host: t.host,
    port: t.port,
    logging: sql => trace.logSql(sql),
    dialectOptions: { options: { encrypt: t.encrypt, trustServerCertificate: true, requestTimeout: 60000 } },
    pool: { max: 3, min: 0 },
  })
  let sequelize = make()
  const step = trace.step.bind(trace)
  try {
    await step('authenticate', () => sequelize.authenticate())
    await step('databaseVersion', () => sequelize.databaseVersion().then(v => v.split('.')[0]))
    let { User, Post, Tag } = define(sequelize)
    await step('sync force', () => sequelize.sync({ force: true }).then(() => 'synced'))
    await step('describeTable users', () => sequelize.getQueryInterface().describeTable('users'))
    await step('describeTable posts', () => sequelize.getQueryInterface().describeTable('posts'))
    await step('showIndex users', () => sequelize.getQueryInterface().showIndex('users'))
    await step('showAllSchemas', () => sequelize.showAllSchemas())
    await step('showAllTables', () => sequelize.getQueryInterface().showAllTables().then(ts => ts.map(x => typeof x === 'string' ? x : x.tableName).sort()))
    await step('getForeignKeyReferencesForTable posts', () => sequelize.getQueryInterface().getForeignKeyReferencesForTable('posts'))
    await step('getForeignKeysForTables', () => sequelize.getQueryInterface().getForeignKeysForTables(['posts', 'post_tags']))

    await step('create user', async () => plain(await User.create({
      email: 'ada@example.com', name: 'Ada', age: 36, karma: '9007199254740993', balance: '10.50', ratio: 0.25, score: 1.5,
      born: '1815-12-10', seenAt: new Date('2020-01-02T03:04:05.678Z'), bio: 'first', avatar: Buffer.from('cafe', 'hex'),
      token: '7d444840-9dc0-11d1-b245-5ffdce74fad2', kind: 'admin',
    })))
    await step('bulkCreate users', async () => plain(await User.bulkCreate([
      { email: 'bob@example.com', name: 'Bob', age: 40 },
      { email: 'cy@example.com', name: 'Cy', age: 22, active: false },
      { email: 'di@example.com', name: 'Di' },
    ])))
    await step('unique violation', () => User.create({ email: 'ada@example.com', name: 'Dup' }))
    await step('notNull violation (client)', () => User.create({ email: 'nn@example.com' }))
    await step('create posts', async () => plain(await Post.bulkCreate([
      { title: 'Hello', body: 'one', userId: 1 }, { title: 'World', body: 'two', userId: 1 },
      { title: 'Boat', body: 'three', userId: 2 }, { title: 'Gone', body: 'four', userId: 3 },
    ])))
    await step('fk violation', () => Post.create({ title: 'orphan', userId: 999 }))
    await step('create tags + setTags', async () => {
      const tags = await Tag.bulkCreate([{ name: 'red' }, { name: 'green' }, { name: 'blue' }])
      const p1 = await Post.findByPk(1)
      await p1.setTags([tags[0], tags[1]])
      const p2 = await Post.findByPk(2)
      await p2.addTag(tags[1])
      return (await p1.getTags({ order: [['id', 'ASC']] })).map(x => x.name)
    })
    await step('findAll include hasMany', async () => plain(await User.findAll({
      attributes: ['id', 'name'], include: [{ model: Post, as: 'posts', attributes: ['id', 'title'] }],
      order: [['id', 'ASC'], [{ model: Post, as: 'posts' }, 'id', 'ASC']],
    })))
    await step('findAll include belongsToMany', async () => plain(await Post.findAll({
      attributes: ['id', 'title'], include: [{ model: Tag, as: 'tags', attributes: ['name'], through: { attributes: [] } }, { model: User, as: 'author', attributes: ['name'] }],
      order: [['id', 'ASC'], [{ model: Tag, as: 'tags' }, 'name', 'ASC']],
    })))
    await step('findAndCountAll limit offset', async () => {
      const r = await User.findAndCountAll({ attributes: ['id', 'name'], order: [['name', 'ASC']], limit: 2, offset: 1 })
      return { count: r.count, rows: plain(r.rows) }
    })
    await step('findAndCountAll include distinct', async () => {
      const r = await User.findAndCountAll({ attributes: ['id', 'name'], include: [{ model: Post, as: 'posts', attributes: ['id'], required: true }], distinct: true, order: [['id', 'ASC']], limit: 1, offset: 0 })
      return { count: r.count, rows: plain(r.rows) }
    })
    await step('findAll limit without order', async () => plain(await User.findAll({ attributes: ['id'], limit: 2, offset: 1 })))
    await step('where operators', async () => plain(await User.findAll({ attributes: ['id'], where: { [Op.or]: [{ age: { [Op.gt]: 30 } }, { name: { [Op.like]: 'C%' } }], email: { [Op.ne]: null } }, order: [['id', 'DESC']] })))
    await step('count / max / sum', async () => ({
      count: await User.count({ where: { active: true } }),
      max: await User.max('age'),
      sum: await User.sum('age'),
    }))
    await step('group by count', async () => plain(await Post.findAll({ attributes: ['userId', [sequelize.fn('COUNT', sequelize.col('id')), 'n']], group: ['userId'], order: [['userId', 'ASC']], raw: true })))
    await step('update', async () => User.update({ age: 41 }, { where: { email: 'bob@example.com' } }))
    await step('increment', async () => { await User.increment({ age: 2 }, { where: { id: 3 } }); return plain(await User.findByPk(3, { attributes: ['age'] })) })
    await step('instance save', async () => { const u = await User.findOne({ where: { name: 'Di' } }); u.age = 19; await u.save(); return plain(await u.reload({ attributes: ['id', 'age'] })) })
    await step('upsert insert', async () => { const [u, created] = await User.upsert({ email: 'eve@example.com', name: 'Eve', age: 30 }); return { created, u: plain(u) } })
    await step('upsert update', async () => { const [u, created] = await User.upsert({ id: 2, email: 'bob@example.com', name: 'Robert', age: 42 }); return { created, u: plain(u) } })
    await step('findOrCreate', async () => { const [u, created] = await User.findOrCreate({ where: { email: 'fay@example.com' }, defaults: { name: 'Fay' } }); return { created, id: u.id } })
    await step('findOrCreate existing', async () => { const [u, created] = await User.findOrCreate({ where: { email: 'fay@example.com' }, defaults: { name: 'Fay' } }); return { created, id: u.id } })

    // paranoid
    await step('paranoid destroy', () => Post.destroy({ where: { title: 'Gone' } }))
    await step('paranoid findAll', async () => plain(await Post.findAll({ attributes: ['id', 'title'], order: [['id', 'ASC']] })))
    await step('paranoid findAll paranoid:false', async () => (await Post.findAll({ paranoid: false, order: [['id', 'ASC']] })).map(p => ({ id: p.id, deleted: p.deletedAt !== null })))
    await step('restore', async () => { await Post.restore({ where: { title: 'Gone' } }); return Post.count() })
    await step('force destroy', () => Post.destroy({ where: { title: 'Gone' }, force: true }))

    // transactions
    await step('managed transaction commit', () => sequelize.transaction(async transaction => {
      await Tag.create({ name: 'trx-ok' }, { transaction })
      return Tag.count({ transaction })
    }))
    await step('managed transaction rollback', async () => {
      try {
        await sequelize.transaction(async transaction => {
          await Tag.create({ name: 'trx-bad' }, { transaction })
          throw new Error('boom')
        })
      } catch (e) { return e.message }
    })
    await step('after rollback', () => Tag.count({ where: { name: { [Op.like]: 'trx-%' } } }))
    await step('managed transaction sql error', async () => {
      try {
        await sequelize.transaction(async transaction => {
          await Tag.create({ name: 'before-error' }, { transaction })
          await Tag.create({ name: 'red' }, { transaction })
        })
      } catch (e) { return { name: e.name, number: e.parent?.number } }
    })
    await step('unmanaged transaction', async () => {
      const transaction = await sequelize.transaction()
      let inside
      try {
        await Tag.create({ name: 'unmanaged' }, { transaction })
        inside = await Tag.count({ where: { name: 'unmanaged' }, transaction })
      } finally { await transaction.rollback() }
      return { inside, after: await Tag.count({ where: { name: 'unmanaged' } }) }
    })
    for (const level of ['READ_UNCOMMITTED', 'READ_COMMITTED', 'REPEATABLE_READ', 'SERIALIZABLE']) {
      await step(`isolation ${level}`, () => sequelize.transaction({ isolationLevel: Transaction.ISOLATION_LEVELS[level] }, async transaction => {
        const [rows] = await sequelize.query('SELECT transaction_isolation_level AS level, @@TRANCOUNT AS tc FROM sys.dm_exec_sessions WHERE session_id = @@SPID', { transaction })
        return rows
      }))
    }
    await step('transaction lock UPDATE', () => sequelize.transaction(async transaction => plain(await User.findAll({ attributes: ['id'], where: { id: 1 }, lock: transaction.LOCK.UPDATE, transaction }))))
    await step('nested transaction savepoint', () => sequelize.transaction(async outer => {
      await Tag.create({ name: 'sp-outer' }, { transaction: outer })
      try {
        await sequelize.transaction({ transaction: outer }, async inner => {
          await Tag.create({ name: 'sp-inner' }, { transaction: inner })
          throw new Error('inner')
        })
      } catch {}
      return (await Tag.findAll({ where: { name: { [Op.like]: 'sp-%' } }, transaction: outer, order: [['name', 'ASC']] })).map(x => x.name)
    }))

    // raw
    await step('raw query select', () => sequelize.query('SELECT 1 AS one, N\'x\' AS s, CAST(2.5 AS decimal(5,2)) AS d', { type: Sequelize.QueryTypes.SELECT }))
    await step('raw query replacements', () => sequelize.query('SELECT name FROM users WHERE age > :age ORDER BY name', { replacements: { age: 30 }, type: Sequelize.QueryTypes.SELECT }))
    await step('raw query bind', () => sequelize.query('SELECT name FROM users WHERE id = $1', { bind: [1], type: Sequelize.QueryTypes.SELECT }))
    await step('raw query error', () => sequelize.query('SELECT nope FROM users'))

    // sync({ alter }) with a changed model: new columns, a type change
    await sequelize.close()
    sequelize = make()
    ;({ User, Post, Tag } = define(sequelize, { v2: true }))
    await step('sync alter', () => sequelize.sync({ alter: true }).then(() => 'synced'))
    await step('describeTable users after alter', () => sequelize.getQueryInterface().describeTable('users'))
    await step('describeTable posts after alter', () => sequelize.getQueryInterface().describeTable('posts'))
    await step('sync alter again (no-op)', () => sequelize.sync({ alter: true }).then(() => 'synced'))
    await step('data survives alter', async () => plain(await User.findAll({ attributes: ['id', 'email', 'nickname', 'level'], order: [['id', 'ASC']] })))
    await step('queryInterface addColumn/removeColumn', async () => {
      const qi = sequelize.getQueryInterface()
      await qi.addColumn('tags', 'color', { type: DataTypes.STRING(20), allowNull: true, defaultValue: 'none' })
      await qi.changeColumn('tags', 'color', { type: DataTypes.STRING(30), allowNull: true })
      await qi.renameColumn('tags', 'color', 'colour')
      const d = await qi.describeTable('tags')
      await qi.removeColumn('tags', 'colour')
      return d
    })
    await step('addIndex / removeIndex', async () => {
      const qi = sequelize.getQueryInterface()
      await qi.addIndex('posts', ['title'], { name: 'posts_title', unique: false })
      const idx = await qi.showIndex('posts')
      await qi.removeIndex('posts', 'posts_title')
      return idx
    })
    await step('createSchema + showAllSchemas', async () => { await sequelize.createSchema('audit'); return sequelize.showAllSchemas() })
    await step('dropSchema', () => sequelize.dropSchema('audit'))
    await step('drop all', () => sequelize.drop())
    await step('tables left', () => sequelize.query('SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES ORDER BY TABLE_NAME', { type: Sequelize.QueryTypes.SELECT }))
  } finally {
    await sequelize.close()
  }
}

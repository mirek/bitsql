// T-SQL type text (as written in corpus params) -> tedious TYPES + options.
import { TYPES } from 'tedious'

const simple = {
  bit: TYPES.Bit, tinyint: TYPES.TinyInt, smallint: TYPES.SmallInt, int: TYPES.Int, bigint: TYPES.BigInt,
  real: TYPES.Real, float: TYPES.Float, money: TYPES.Money, smallmoney: TYPES.SmallMoney,
  uniqueidentifier: TYPES.UniqueIdentifier, date: TYPES.Date, datetime: TYPES.DateTime,
  smalldatetime: TYPES.SmallDateTime, xml: TYPES.Xml, text: TYPES.Text, ntext: TYPES.NText, image: TYPES.Image,
  sql_variant: TYPES.Variant,
}
const sized = { varchar: TYPES.VarChar, nvarchar: TYPES.NVarChar, char: TYPES.Char, nchar: TYPES.NChar, varbinary: TYPES.VarBinary, binary: TYPES.Binary }
const scaled = { time: TYPES.Time, datetime2: TYPES.DateTime2, datetimeoffset: TYPES.DateTimeOffset }
const exact = { decimal: TYPES.Decimal, numeric: TYPES.Numeric }

export function resolveType(text) {
  const match = /^\s*([a-z_0-9]+)\s*(?:\(\s*([^)]*)\s*\))?\s*$/i.exec(text)
  if (!match) throw new Error(`cannot parse parameter type ${JSON.stringify(text)}`)
  const base = match[1].toLowerCase()
  const args = match[2] === undefined ? [] : match[2].split(',').map(s => s.trim().toLowerCase())
  if (simple[base]) return { type: simple[base], options: {} }
  if (sized[base]) {
    const length = args[0] === undefined ? undefined : args[0] === 'max' ? Infinity : Number(args[0])
    return { type: sized[base], options: length === undefined ? {} : { length } }
  }
  if (scaled[base]) return { type: scaled[base], options: args[0] === undefined ? {} : { scale: Number(args[0]) } }
  if (exact[base]) return { type: exact[base], options: { precision: Number(args[0] ?? 18), scale: Number(args[1] ?? 0) } }
  throw new Error(`unsupported parameter type ${text}`)
}

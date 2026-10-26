// Type-checked against the packed package (scripts/npm-publish.sh).
import bitsql, { start, type BitsqlServer, type StartOptions } from 'bitsql'

const options: StartOptions = { databases: ['app'], tls: false, onLog: chunk => process.stderr.write(chunk) }
const server: BitsqlServer = await start(options)
const port: number = server.port
const database: string = server.tedious('app').options.database
const encrypt: boolean = server.mssql().options.encrypt
const text: string = server.connectionString('app') + bitsql.version + port + database + encrypt
await server.stop()
export { text }

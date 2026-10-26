// Type-checked by `npm run check` against the built package.
import * as bitsql from 'bitsql'
import { start, type BitsqlServer, type StartOptions } from 'bitsql'

export async function use(): Promise<string> {
  const options: StartOptions = { databases: ['app'], tls: false, onLog: line => console.log(line) }
  const server: BitsqlServer = await start(options)
  const port: number = server.port
  const database: string = server.tedious('app').options.database
  const encrypt: boolean = server.mssql().options.encrypt
  await server.stop()
  return server.connectionString('app') + bitsql.version + port + database + encrypt
}

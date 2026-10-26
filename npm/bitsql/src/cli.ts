#!/usr/bin/env node
// `bitsql` command: the native host's command line (src/host/main.mbt), so
// the harness can run its suite against this build (BITSQL_BIN=dist/cli.js).
//   --listen HOST:PORT (default 127.0.0.1:47333; port 0 picks a free port)
//   --database NAME (repeatable), --auto-create-databases,
//   --max-request-work N, --tls-cert FILE --tls-key FILE, --no-tls,
//   --http-ca FILE, --record FILE, --version; --spin-us N is accepted and
//   has no effect (Node's event loop has no idle sleep to avoid).
// Prints `listening on HOST:PORT` to stderr once bound (harness contract).
import { readFileSync } from 'node:fs'
import { launch } from './launch'

const args = process.argv.slice(2)
const flag = (name: string) => {
  const i = args.indexOf(name)
  return i >= 0 && i + 1 < args.length ? args[i + 1] : undefined
}

async function main() {
  if (args.includes('--version')) {
    process.stdout.write(`bitsql ${require('../package.json').version}\n`)
    return
  }
  const listen = flag('--listen') ?? '127.0.0.1:47333'
  const colon = listen.lastIndexOf(':')
  const host = listen.slice(0, colon)
  const port = Number(listen.slice(colon + 1))
  const databases: string[] = []
  args.forEach((arg, i) => { if (arg === '--database' && i + 1 < args.length) databases.push(args[i + 1]) })
  const work = flag('--max-request-work')
  const cert = flag('--tls-cert')
  const key = flag('--tls-key')
  if ((cert === undefined) !== (key === undefined)) throw new Error('--tls-cert and --tls-key go together')
  const httpCa = flag('--http-ca')
  const log = (line: string) => process.stderr.write(line + '\n')
  const address = await launch({
    host,
    port,
    databases,
    autoCreateDatabases: args.includes('--auto-create-databases'),
    maxRequestWork: work !== undefined && /^-?\d+$/.test(work) ? BigInt(work) : -1n,
    tls: args.includes('--no-tls') ? false : cert && key ? { cert: readFileSync(cert), key: readFileSync(key) } : undefined,
    httpCa: httpCa === undefined ? undefined : readFileSync(httpCa),
    record: flag('--record'),
  }, log, true)
  log(`listening on ${address.host}:${address.port}`)
  for (const signal of ['SIGINT', 'SIGTERM'] as const) process.on(signal, () => process.exit(0))
}

main().catch(error => {
  process.stderr.write(`bitsql: ${error instanceof Error ? error.message : error}\n`)
  process.exit(1)
})

// One server per worker thread (launch.ts): the engine gets its own stack
// and heap limits, and its work never blocks the caller's event loop.
import { parentPort, workerData } from 'node:worker_threads'
import { Host, type HostOptions } from './server'

export type ToParent =
  | { type: 'listening'; host: string; port: number }
  | { type: 'log'; line: string }
  | { type: 'failed'; message: string }
  | { type: 'fatal'; message: string }
  | { type: 'stopped' }

const port = parentPort!
const { options, compiled } = workerData as { options: Omit<HostOptions, 'log'>; compiled: WebAssembly.Module }
const send = (message: ToParent) => port.postMessage(message)
const host = new Host({ ...options, log: line => send({ type: 'log', line }) }, compiled, error => {
  send({ type: 'fatal', message: error.stack ?? error.message })
  process.exit(1)
})
port.on('message', (message: { type: 'stop' }) => {
  if (message.type === 'stop') void host.close().then(() => { send({ type: 'stopped' }); process.exit(0) })
})
host.listen().then(
  address => send({ type: 'listening', ...address }),
  (error: Error) => { send({ type: 'failed', message: error.message }); process.exit(1) },
)

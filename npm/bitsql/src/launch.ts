// Starts a Host in a worker thread. Native-like headroom: SQL Server runs
// requests on large stacks and the native host has no heap cap; Node's
// defaults (~1 MB stack, ~4 GB heap) fail deep recursion and large
// intermediate results that the native image handles.
import { Worker } from 'node:worker_threads'
import { totalmem } from 'node:os'
import { join } from 'node:path'
import { compileEngine } from './engine'
import type { HostOptions } from './server'
import type { ToParent } from './worker'

export interface Launched {
  host: string
  port: number
  stop(): Promise<void>
}

export async function launch(
  options: Omit<HostOptions, 'log'>,
  log: (line: string) => void,
  /** false: the server never keeps this process alive. */
  ref: boolean,
): Promise<Launched> {
  const compiled = await compileEngine()
  const worker = new Worker(join(__dirname, 'worker.js'), {
    workerData: { options, compiled },
    resourceLimits: { stackSizeMb: 64, maxOldGenerationSizeMb: Math.max(4096, Math.floor(totalmem() / 2 ** 20)) },
  })
  let stopping: Promise<void> | undefined
  const exited = new Promise<void>(resolve => worker.once('exit', () => resolve()))
  return new Promise((resolve, reject) => {
    let listening = false
    worker.on('message', (message: ToParent) => {
      switch (message.type) {
        case 'log': log(message.line); break
        case 'failed': reject(new Error(message.message)); break
        case 'fatal': log(`bitsql: engine failure, server stopped: ${message.message}`); break
        case 'listening':
          listening = true
          // only now: until listening, the start must keep the process alive
          if (!ref) worker.unref()
          resolve({
            host: message.host,
            port: message.port,
            stop: () => {
              // ref'd again: awaiting stop() must keep the process alive
              stopping ??= (worker.ref(), worker.postMessage({ type: 'stop' }), exited)
              return stopping
            },
          })
          break
      }
    })
    worker.once('error', error => { if (listening) log(`bitsql: ${error.message}`); else reject(error) })
    worker.once('exit', code => { if (!listening) reject(new Error(`bitsql: server exited (${code}) before listening`)) })
  })
}

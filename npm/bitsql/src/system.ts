// Host facts for the monitoring views, as src/host/monitor.c (zero where the
// OS does not expose them, e.g. no /sys outside Linux).
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { cpus, totalmem, uptime } from 'node:os'
import { UNIX_EPOCH_TICKS } from './engine'

/** Wall clock as 100 ns ticks since 0001-01-01 UTC, at millisecond precision (the host's `now_ticks`). */
export function nowTicks(): bigint {
  return BigInt(Date.now()) * 10000n + UNIX_EPOCH_TICKS
}

/** Wall clock at sub-millisecond precision (the host's `clock_ticks`). */
export function clockTicks(): bigint {
  return BigInt(Math.round((performance.timeOrigin + performance.now()) * 10000)) + UNIX_EPOCH_TICKS
}

/** Process CPU time in microseconds. */
export function cpuMicros(): bigint {
  const { user, system } = process.cpuUsage()
  return BigInt(user + system)
}

export function cpuCount(): number {
  return cpus().length
}

export function memoryKb(): bigint {
  return BigInt(Math.floor(totalmem() / 1024))
}

function readInt(path: string): number | undefined {
  try {
    const n = Number.parseInt(readFileSync(path, 'utf8'), 10)
    return Number.isNaN(n) ? undefined : n
  } catch { return undefined }
}

/** Distinct physical packages and (package, core) pairs under /sys. */
function topology(): { sockets: number; cores: number } {
  const packages: number[] = []
  const cores: number[] = []
  let sockets = 0
  let coreCount = 0
  let names: string[] = []
  try { names = readdirSync('/sys/devices/system/cpu').filter(name => /^cpu\d+$/.test(name)) } catch {}
  names.sort((a, b) => Number(a.slice(3)) - Number(b.slice(3)))
  for (const cpu of names) {
    const pkg = readInt(`/sys/devices/system/cpu/${cpu}/topology/physical_package_id`)
    const core = readInt(`/sys/devices/system/cpu/${cpu}/topology/core_id`)
    if (pkg === undefined || core === undefined) continue
    let seenPackage = false
    let seenCore = false
    for (let j = 0; j < packages.length; j++) {
      if (packages[j] === pkg) { seenPackage = true; if (cores[j] === core) seenCore = true }
    }
    if (!seenPackage) sockets++
    if (!seenCore) { packages.push(pkg); cores.push(core); coreCount++ }
  }
  return { sockets, cores: coreCount }
}

function numaCount(): number {
  try { return readdirSync('/sys/devices/system/node').filter(name => /^node\d/.test(name)).length } catch { return 0 }
}

export function systemFacts(): [string, bigint][] {
  const { sockets, cores } = topology()
  const online = cpuCount()
  return [
    ['socket_count', BigInt(sockets)],
    ['cores_per_socket', BigInt(sockets ? Math.floor(cores / sockets) : 0)],
    ['hyperthread_ratio', BigInt(sockets > 0 ? Math.floor(online / sockets) : 0)],
    ['numa_node_count', BigInt(numaCount())],
    ['container_type', existsSync('/.dockerenv') || existsSync('/run/.containerenv') ? 1n : 0n],
    ['sqlserver_start_time_ms_ticks', BigInt(Math.floor(uptime() * 1000))],
  ]
}

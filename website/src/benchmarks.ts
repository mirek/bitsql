// Values come from the checked-in raw benchmark, also offered as a download.
import evidence from '../public/benchmark-0.1.28.json';
const [bitsql, sqlserver] = evidence.results;
export const benchmarks = [
  { name: 'Image on disk', unit: 'MiB', values: [bitsql.imageBytes / 2 ** 20, sqlserver.imageBytes / 2 ** 20] },
  { name: 'Idle memory', unit: 'MiB', values: [bitsql.idle.used / 2 ** 20, sqlserver.idle.used / 2 ** 20] },
  { name: 'Cold start → first query', unit: 'ms', values: [bitsql.coldStartMs, sqlserver.coldStartMs] },
  { name: 'TLS login', unit: 'ms', values: [bitsql.loginMs, sqlserver.loginMs] },
  { name: '1,000 inserts', unit: 'ms', values: [bitsql.insertsMs, sqlserver.insertsMs] },
  { name: '1,000 point reads', unit: 'ms', values: [bitsql.pointReadsMs, sqlserver.pointReadsMs] },
];
export function formatValue(value: number): string {
  return value.toLocaleString('en', { maximumFractionDigits: value < 10 ? 2 : 1 });
}
export function barWidth(value: number, values: number[]): number {
  return value / Math.max(...values) * 100;
}

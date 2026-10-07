import './style.css';
import { benchmarks, barWidth, formatValue } from './benchmarks.ts';
import { examples } from './examples.ts';
import type { QueryResult, WorkerReply } from './protocol.ts';
function el<K extends keyof HTMLElementTagNameMap>(tag: K, text?: string, className?: string): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (className) node.className = className;
  return node;
}
function get<T extends HTMLElement>(id: string): T { return document.getElementById(id) as T; }
for (const metric of benchmarks) {
  const card = el('article', undefined, 'chart');
  const heading = el('div', undefined, 'chart-heading');
  const [bitsql, sqlserver] = metric.values;
  const faster = bitsql < sqlserver;
  const ratio = faster ? sqlserver / bitsql : bitsql / sqlserver;
  heading.append(el('h3', metric.name), el('span', `${formatValue(ratio)}× ${faster ? 'less' : 'more'}`, `factor${faster ? '' : ' slower'}`));
  card.append(heading);
  metric.values.forEach((value, i) => {
    const label = el('div', undefined, 'bar-label');
    label.append(el('span', i === 0 ? 'bitsql' : 'SQL Server'), el('span', `${formatValue(value)} ${metric.unit}`));
    const track = el('div', undefined, 'bar-track');
    track.setAttribute('aria-hidden', 'true');
    const bar = el('div', undefined, `bar ${i === 0 ? 'green' : 'gray'}`);
    bar.style.width = `${barWidth(value, metric.values)}%`;
    track.append(bar);
    card.append(label, track);
  });
  get('charts').append(card);
}
for (const button of document.querySelectorAll<HTMLButtonElement>('[data-copy]')) {
  button.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(get(button.dataset.copy!).textContent ?? '');
      button.textContent = 'Copied!';
    } catch { button.textContent = 'Select text to copy'; }
    setTimeout(() => { button.textContent = 'Copy'; }, 2000);
  });
}
const editor = get<HTMLTextAreaElement>('sql');
const example = get<HTMLSelectElement>('example');
const run = get<HTMLButtonElement>('run');
const stop = get<HTMLButtonElement>('stop');
const status = get('query-status');
const results = get('results');
for (const [i, item] of examples.entries()) {
  const option = el('option', item.name);
  option.value = String(i);
  example.append(option);
}
editor.value = examples[0].sql;
example.addEventListener('change', () => { editor.value = examples[Number(example.value)].sql; });
let worker: Worker | undefined;
let timer: ReturnType<typeof setTimeout> | undefined;
function finish() { clearTimeout(timer); run.disabled = false; stop.disabled = true; }
function reset(message = 'Database reset. Ready for a fresh query.') {
  worker?.terminate(); worker = undefined; finish(); results.replaceChildren(); status.textContent = message;
}
function render(result: QueryResult, elapsed: number) {
  results.replaceChildren();
  const hasErrors = result.messages.some(m => m.severity >= 11);
  status.textContent = result.interrupted
    ? 'Browser limitation: this request needs a wait or HTTP host integration. Database reset; request did not complete.'
    : `${hasErrors ? 'Completed with SQL errors' : 'Completed'} in ${formatValue(elapsed)} ms · ${result.sets.length} result set(s)`;
  result.messages.forEach(message => {
    results.append(el('p', `${message.number}, line ${message.line}: ${message.text}`, `message${message.severity >= 11 ? ' error' : ''}`));
  });
  result.sets.forEach((set, i) => {
    const wrapper = el('div', undefined, 'result-wrap');
    const table = el('table');
    table.append(el('caption', `Result ${i + 1} · ${set.rows.length} row(s)${set.rows.length > 200 ? ' · showing first 200' : ''}`));
    const head = el('thead'), header = el('tr');
    set.columns.forEach((name, index) => { const th = el('th', name || '(unnamed)'); th.scope = 'col'; th.title = set.types[index]; header.append(th); });
    head.append(header); table.append(head);
    const body = el('tbody');
    set.rows.slice(0, 200).forEach(row => {
      const tr = el('tr');
      row.forEach(value => tr.append(el('td', value ?? 'NULL', value === null ? 'null' : undefined)));
      body.append(tr);
    });
    table.append(body); wrapper.append(table); results.append(wrapper);
  });
  if (result.counts.length) results.append(el('p', `Row counts: ${result.counts.join(', ')}`, 'small'));
}
function execute() {
  if (run.disabled || !editor.value.trim()) return;
  run.disabled = true; stop.disabled = false; status.textContent = 'Running SQL…'; results.replaceChildren();
  if (!worker) {
    worker = new Worker(new URL('./engine.worker.ts', import.meta.url), { type: 'module' });
    worker.onmessage = (event: MessageEvent<WorkerReply>) => {
      finish();
      if ('error' in event.data) { reset(event.data.error); return; }
      render(event.data.result, event.data.elapsed);
    };
    worker.onerror = () => reset('The engine could not run. Database reset. Try again or reload the page.');
  }
  timer = setTimeout(() => reset('Query exceeded the browser’s 10-second limit. Stopped and reset the database.'), 10_000);
  worker.postMessage({ sql: editor.value });
}
run.addEventListener('click', execute);
get('reset').addEventListener('click', () => reset());
stop.addEventListener('click', () => reset('Query stopped. Database reset.'));
editor.addEventListener('keydown', event => {
  if (event.key === 'Enter' && (event.ctrlKey || event.metaKey)) { event.preventDefault(); execute(); }
});

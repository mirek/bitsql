import { execute } from './generated/engine.js';
import type { WorkerRequest, WorkerReply } from './protocol.ts';
self.onmessage = (event: MessageEvent<WorkerRequest>) => {
  const start = performance.now();
  let reply: WorkerReply;
  try {
    reply = { result: JSON.parse(execute(event.data.sql, Date.now())), elapsed: performance.now() - start };
  } catch (error) {
    reply = { error: `Engine stopped: ${String(error)}. Reset the database before continuing.` };
  }
  self.postMessage(reply);
};

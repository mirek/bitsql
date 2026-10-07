export interface QueryResult {
  sets: { columns: string[]; types: string[]; rows: (string | null)[][] }[];
  messages: { number: number; severity: number; line: number; text: string }[];
  counts: string[];
  interrupted: boolean;
}
export type WorkerRequest = { sql: string };
export type WorkerReply = { result: QueryResult; elapsed: number } | { error: string };

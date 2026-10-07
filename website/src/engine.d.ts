declare module '*generated/engine.js' {
  export function execute(sql: string, now: number): string;
  export function reset(): void;
}

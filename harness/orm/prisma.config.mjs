// Prisma 7 CLI configuration: the schema and the datasource URL
// (DATABASE_URL, set per target by workloads/prisma.mjs).
import { defineConfig } from 'prisma/config'

export default defineConfig({
  schema: 'prisma/schema.prisma',
  migrations: { path: 'prisma/migrations' },
  datasource: { url: process.env.DATABASE_URL ?? 'sqlserver://localhost:1433;database=unused;user=sa;password=unused;encrypt=false' },
})

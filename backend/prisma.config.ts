import 'dotenv/config';
import { defineConfig } from 'prisma/config';

// CLI always requires a separately approved, direct STAGING connection.
// Runtime pooling will be configured independently with @prisma/adapter-pg.
export default defineConfig({
  schema: 'prisma/schema.prisma',
  datasource: { url: process.env.DIRECT_URL ?? '' },
});

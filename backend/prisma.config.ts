import 'dotenv/config';
import { defineConfig } from 'prisma/config';
import { stagingDirectUrl } from '../scripts/staging-target.mjs';

// This configuration is intentionally read-only by policy.
// DO NOT invoke prisma migrate or db push against the legacy target.
// No URL is allowed unless explicit isolated staging gates are satisfied.
// Also verify at the SQL/catalog level that this identity cannot write.
export default defineConfig({
  schema: 'prisma/schema.prisma',
  datasource: { url: stagingDirectUrl(process.env) },
});

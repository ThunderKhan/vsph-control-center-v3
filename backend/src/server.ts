import 'dotenv/config';
import { buildApp } from './app.js';

const port = Number(process.env.API_PORT ?? 4000);
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error('API_PORT must be an integer between 1 and 65535.');
}

const app = buildApp();
app.listen({ port, host: '0.0.0.0' }).catch((error: unknown) => {
  app.log.error(error);
  process.exitCode = 1;
});

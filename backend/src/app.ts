import Fastify from 'fastify';
import { installHttpSecurity } from './http-security.js';

export function buildApp() {
  const app = Fastify({
    logger: { redact: ['req.headers.authorization', 'req.headers.cookie', 'res.headers.set-cookie'] },
  });

  installHttpSecurity(app);

  // Old API shape is retained where possible. Always fail closed until
  // real database connectivity, migration history and auth are verified.
  app.get('/api/health', async (_request, reply) =>
    reply.code(503).send({
      status: 'not_configured',
      database: false,
      releaseReady: false,
      scope: 'migration-foundation-only',
    }),
  );

  app.post('/api/auth/login', async (_request, reply) =>
    reply.code(503).send({
      message: 'Migration foundation is not an enabled authentication service.',
    }),
  );

  return app;
}

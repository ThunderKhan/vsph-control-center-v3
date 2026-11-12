import Fastify from 'fastify';
import { installHttpSecurity } from './http-security.js';
import { registerPortalLoginHttp } from './modules/auth/login-http.js';
import { registerPortalMeHttp } from './modules/auth/session-http.js';
import type { PortalSessionStore } from './modules/auth/portal-session.js';
import type { PortalLoginDependencies } from './modules/auth/portal-login.js';

export function buildApp(options: {
  login?: PortalLoginDependencies;
  sessionStore?: PortalSessionStore;
} = {}) {
  // The production boot path must not accidentally enable partial auth.
  // Once the full session adapter is verified, replace this gate through a
  // separately reviewed, production-authorized integration.
  if (process.env.NODE_ENV === 'production' && (options.login || options.sessionStore)) {
    throw new Error('Partial authentication adapters are not enabled in production.');
  }
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

  if (options.login) {
    // Test/staging dependency injection only; server.ts calls buildApp()
    // with no credentials or stores and therefore keeps login disabled.
    registerPortalLoginHttp(app, options.login);
  } else {
    app.post('/api/auth/login', async (_request, reply) =>
      reply.code(503).send({
        message: 'Migration foundation is not an enabled authentication service.',
      }),
    );
  }

  if (options.sessionStore) {
    registerPortalMeHttp(app, options.sessionStore);
  } else {
    app.get('/api/auth/me', async (_request, reply) =>
      reply.code(503).send({ message: 'Session verification is not configured.' }),
    );
  }

  return app;
}

import type { FastifyInstance } from 'fastify';
import {
  resolvePortalSession, PortalSessionError, type PortalSessionStore,
} from './portal-session.js';
import { readSessionCookies } from './login-http.js';

/**
 * Legacy GET /api/auth/me contract. This adapter works only with an explicit
 * read-only session store. No database adapter is attached by the server.
 */
export function registerPortalMeHttp(
  app: FastifyInstance,
  store: PortalSessionStore,
): void {
  app.get('/api/auth/me', async (request, reply) => {
    try {
      const cookie = readSessionCookies(request.headers.cookie)['vsph.portal.sid'];
      const result = await resolvePortalSession(cookie, store);
      return reply.send({
        user: {
          id: result.user.id,
          name: result.user.full_name,
          email: result.user.email,
          platformRole: result.user.platform_role,
        },
      });
    } catch (error) {
      if (error instanceof PortalSessionError) {
        return reply.code(401).send({ message: error.message });
      }
      // Never return a profile on an uncertain database or catalog lookup.
      app.log.error('Portal session inspection unavailable');
      return reply.code(503).send({ message: 'Session verification is temporarily unavailable.' });
    }
  });
}

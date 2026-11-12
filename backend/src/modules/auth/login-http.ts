import type { FastifyInstance } from 'fastify';
import { IdentityError, identityErrorBody } from './credentials.js';
import {
  loginPortal, PortalLoginError,
  type CookieInstruction, type PortalLoginDependencies,
} from './portal-login.js';

/**
 * Cookie names are the reviewed legacy VSPH session cookie names; reject
 * ambiguous duplicate names rather than interpreting the wrong identity.
 */
function readCookies(cookieHeader: string | undefined): Record<string, string> {
  const result: Record<string, string> = Object.create(null) as Record<string, string>;
  const repeated = new Set<string>();
  if (!cookieHeader) return result;
  for (const part of cookieHeader.split(';').slice(0, 120)) {
    const at = part.indexOf('=');
    if (at < 1) continue;
    const key = part.slice(0, at).trim();
    const value = part.slice(at + 1).trim();
    if (!/^(vsph\.portal\.sid|vsph\.employee\.setup|vsph\.[a-z][a-z0-9_]{1,39}\.sid)$/.test(key) ||
        !/^[A-Za-z0-9_-]{1,128}$/.test(value)) continue;
    if (Object.hasOwn(result, key)) {
      repeated.add(key);
      continue;
    }
    result[key] = value;
  }
  for (const key of repeated) delete result[key];
  return result;
}

function serializeCookie(cookie: CookieInstruction, production: boolean): string {
  if (!/^(vsph\.portal\.sid|vsph\.employee\.setup|vsph\.[a-z][a-z0-9_]{1,39}\.sid)$/.test(cookie.name)) {
    throw new Error('Unrecognized session cookie name');
  }
  const attributes = [
    cookie.action === 'set' ? `${cookie.name}=${cookie.value}` : `${cookie.name}=`,
    'Path=/', 'HttpOnly', 'SameSite=Lax',
    ...(production ? ['Secure'] : []),
  ];
  if (cookie.action === 'set') {
    if (!/^[A-Za-z0-9_-]{1,128}$/.test(cookie.value) ||
        !Number.isSafeInteger(cookie.maxAgeMs) ||
        cookie.maxAgeMs <= 0) throw new Error('Invalid session cookie instructions');
    attributes.push('Max-Age=' + String(Math.floor(cookie.maxAgeMs / 1000)));
  } else {
    attributes.push('Max-Age=0', 'Expires=Thu, 01 Jan 1970 00:00:00 GMT');
  }
  return attributes.join('; ');
}

/**
 * Opt-in HTTP registration; NOT called by the production default buildApp().
 * Only an explicitly supplied, reviewed data store can activate this route.
 * In the normal server the fail-closed 503 placeholder remains registered.
 */
export function registerPortalLoginHttp(
  app: FastifyInstance,
  deps: PortalLoginDependencies,
  options: { production?: boolean } = {},
): void {
  const production = options.production ?? process.env.NODE_ENV === 'production';
  app.post('/api/auth/login', async (request, reply) => {
    try {
      const result = await loginPortal(
        request.body, readCookies(request.headers.cookie), deps,
      );
      reply.header('Set-Cookie',
        result.cookies.map((instruction) => serializeCookie(instruction, production)));
      return reply.code(200).send(result.response);
    } catch (error) {
      if (error instanceof IdentityError) {
        if (error.status === 429) reply.header('Retry-After', '60');
        return reply.code(error.status).send(identityErrorBody(error));
      }
      if (error instanceof PortalLoginError) {
        return reply.code(error.status).send({ message: error.message });
      }
      // Never reveal database/session errors or internal provider details.
      app.log.error({ err: error }, 'Login orchestration unavailable');
      return reply.code(503).send({
        code: 'AUTH_UNAVAILABLE',
        message: 'Identity verification is temporarily unavailable. Try again later.',
      });
    }
  });
}

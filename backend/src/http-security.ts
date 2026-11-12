import type { FastifyInstance } from 'fastify';

/**
 * Request-level parity with original http-security.js / security.js.
 * Do not add a generic CSP to Next.js until nonced app-router scripts have
 * been validated against browser hydration: a broken CSP is not parity.
 */
export function installHttpSecurity(
  app: FastifyInstance,
  options: { publicOrigin?: string; production?: boolean } = {},
): void {
  const production = options.production ?? process.env.NODE_ENV === 'production';
  const publicOrigin = options.publicOrigin ?? process.env.PUBLIC_ORIGIN ??
    'http://localhost:3000';
  if (production && !options.publicOrigin && !process.env.PUBLIC_ORIGIN) {
    throw new Error('PUBLIC_ORIGIN must be explicitly configured in production.');
  }
  if (!/^https?:\/\/[^/]+$/.test(publicOrigin) ||
      (production && !publicOrigin.startsWith('https://'))) {
    throw new Error('PUBLIC_ORIGIN must be the exact HTTPS origin in production.');
  }

  // Legacy local rate limit: 20 requests per 15m for each client IP.
  // A shared/distributed ingress limit is a separate production release gate.
  const buckets = new Map<string, { count: number; reset: number }>();
  const windowMs = 15 * 60 * 1000;
  const maxKeys = 10000;

  app.addHook('onRequest', async (request, reply) => {
    reply.header('X-Request-ID', request.id);
    reply.header('X-Content-Type-Options', 'nosniff');
    reply.header('X-Frame-Options', 'DENY');
    reply.header('Referrer-Policy', 'no-referrer');
    reply.header('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
    reply.header('Cross-Origin-Resource-Policy', 'same-origin');
    if (production) reply.header('Strict-Transport-Security', 'max-age=31536000');

    const path = request.url.split('?')[0] ?? '/';
    if (path.startsWith('/api/')) reply.header('Cache-Control', 'no-store');

    if (!['GET', 'HEAD', 'OPTIONS'].includes(request.method)) {
      if (request.headers.origin !== publicOrigin) {
        return reply.code(403).send({ message: 'Request origin not permitted.' });
      }
    }

    if (request.method === 'POST' && [
      '/api/auth/login', '/api/auth/app-login',
      '/api/invitations/accept', '/api/invitations/inspect',
    ].includes(path)) {
      const now = Date.now();
      const key = request.ip;
      let bucket = buckets.get(key);
      if (!bucket || bucket.reset <= now) {
        if (buckets.size >= maxKeys) {
          for (const [ip, b] of buckets) if (b.reset <= now) buckets.delete(ip);
          if (!buckets.has(key) && buckets.size >= maxKeys) {
            reply.header('Retry-After', String(Math.ceil(windowMs / 1000)));
            return reply.code(429).send({ message: 'Too many requests. Try again later.' });
          }
        }
        bucket = { count: 0, reset: now + windowMs };
        buckets.set(key, bucket);
      }
      bucket.count += 1;
      if (bucket.count > 20) {
        reply.header('Retry-After', String(Math.max(1, Math.ceil((bucket.reset - now) / 1000))));
        return reply.code(429).send({ message: 'Too many requests. Try again later.' });
      }
    }
  });
}

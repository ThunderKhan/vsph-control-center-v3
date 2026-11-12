import { describe, expect, it } from 'vitest';
import { buildApp } from './app.js';

describe('HTTP origin, headers and abuse controls', () => {
  it('denies cross-origin writes (including absent Origin) before authentication', async () => {
    const app = buildApp();
    try {
      const response = await app.inject({ method: 'POST', url: '/api/auth/login',
        payload: { email: 'nobody@example.test', password: 'secret' } });
      expect(response.statusCode).toBe(403);
      expect(response.json()).toMatchObject({ message: 'Request origin not permitted.' });
    } finally { await app.close(); }
  });

  it('preserves secure HTTP headers, API no-cache and fail-closed login', async () => {
    const app = buildApp();
    try {
      const response = await app.inject({ method: 'POST', url: '/api/auth/login',
        headers: { origin: 'http://localhost:3000' },
        payload: { email: 'nobody@example.test', password: 'secret' } });
      expect(response.statusCode).toBe(503);
      expect(response.headers['x-content-type-options']).toBe('nosniff');
      expect(response.headers['cache-control']).toBe('no-store');
      expect(response.headers['x-request-id']).toBeTruthy();
    } finally { await app.close(); }
  });

  it('throttles brute-force attempts without exposing the provider', async () => {
    const app = buildApp();
    try {
      let final;
      for (let index = 0; index < 21; index++) {
        final = await app.inject({ method: 'POST', url: '/api/auth/login',
          headers: { origin: 'http://localhost:3000' },
          payload: { email: 'nobody@example.test', password: 'secret' } });
      }
      expect(final?.statusCode).toBe(429);
      expect(final?.headers['retry-after']).toBeTruthy();
    } finally { await app.close(); }
  });
});

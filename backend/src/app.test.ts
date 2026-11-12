import { describe, expect, it } from 'vitest';
import { buildApp } from './app.js';

describe('migration foundation security gate', () => {
  it('does not claim a configured database or release readiness', async () => {
    const app = buildApp();
    try {
      const response = await app.inject({ method: 'GET', url: '/api/health' });
      expect(response.statusCode).toBe(503);
      expect(response.json()).toMatchObject({
        status: 'not_configured',
        database: false,
        releaseReady: false,
      });
    } finally {
      await app.close();
    }
  });

  it('rejects login until a fully authorized compatibility port exists', async () => {
    const app = buildApp();
    try {
      const response = await app.inject({
        method: 'POST',
        url: '/api/auth/login',
        payload: { email: 'someone@example.test', password: 'not-a-real-password' },
        headers: { origin: 'http://localhost:3000' },
      });
      expect(response.statusCode).toBe(503);
    } finally {
      await app.close();
    }
  });
});

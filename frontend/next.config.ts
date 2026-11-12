import type { NextConfig } from 'next';

const nextConfig: NextConfig = {
  output: 'standalone',
  // In production, Caddy owns /api/* routing to the Fastify container.
  // Never expose a server-only DB or Supabase key through Next.js.
  async rewrites() {
    if (process.env.NODE_ENV === 'production') return [];
    return [{
      source: '/api/:path*',
      destination: 'http://127.0.0.1:4000/api/:path*',
    }];
  },
};
export default nextConfig;

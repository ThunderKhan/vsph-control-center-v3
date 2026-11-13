import type { Metadata } from 'next';
import type { ReactNode } from 'react';
import './globals.css';
import './auth.css';
import './crm-auth.css';

export const metadata: Metadata = {
  title: 'VSPH Control Center',
  description: 'VSPH Control Center',
};

/**
 * Temporary root body class: only /login and /apps/[app]/login are currently
 * ported. Auth appearance must be scoped in a dedicated layout BEFORE any
 * workspace page is migrated; never apply auth styling to workspace pages.
 */
export default function RootLayout({ children }: Readonly<{ children: ReactNode }>) {
  return (
    <html lang="en">
      <head><link rel="stylesheet" href="/fonts.css" /></head>
      <body className="auth-page portal-auth">{children}</body>
    </html>
  );
}

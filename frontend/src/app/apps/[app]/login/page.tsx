import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { AuthPage } from '@/features/auth/AuthPage';

export const metadata: Metadata = { title: 'Sign in | VSPH Control Center' };

type Props = { params: Promise<{ app: string }> };

export default async function ApplicationLoginPage({ params }: Props) {
  const { app } = await params;
  if (!/^[a-z][a-z0-9_-]*$/i.test(app)) notFound();

  // This page is NOT authorized by route rendering. The legacy backend
  // required a live portal session and an allowed product before serving it.
  // Its Fastify equivalent must enforce both before this route is released.
  return <AuthPage appCode={app.toUpperCase()} />;
}

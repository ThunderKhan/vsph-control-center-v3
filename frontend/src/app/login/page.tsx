import type { Metadata } from 'next';
import { AuthPage } from '@/features/auth/AuthPage';

export const metadata: Metadata = {
  title: 'Sign in | VSPH Control Center',
};

export default function LoginPage() {
  return <AuthPage />;
}

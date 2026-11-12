/** Exact legacy presentation defaults from public/auth-config.js (3b3a1535873aa0517aea41da32a407f3d9680547). */
export const DEFAULT_AUTH_COPY = Object.freeze({
  heroKicker: 'ENTERPRISE SOFTWARE',
  heroLineOne: 'Building',
  heroLineTwo: "What's Next",
  heroDescription: 'Enterprise Software Solutions for a Smarter Tomorrow.',
  cardKicker: 'VSPH CONTROL CENTER',
  formHeading: 'Welcome back',
  formDescription: 'Sign in to access your organization’s applications.',
  background: '#00255A',
  action: '#0069C8',
  highlight: '#50C0E8',
});

export type OrganizationContext = { id: string; name: string; role: string };
export type ApplicationContext = {
  application: { name: string };
  email: string;
  organizations: OrganizationContext[];
};

export type MfaFactor = { id: string; name: string };

export type LoginResult = {
  message?: string;
  code?: string;
  factors?: MfaFactor[];
  passwordChangeRequired?: boolean;
  redirect?: string;
};

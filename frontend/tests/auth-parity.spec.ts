import { test, expect } from '@playwright/test';

// Structural checks only. The locked browser/font/fixture screenshots and
// server-backed session/role tests required for parity are still pending.
test('portal login retains the exact legacy copy and controls', async ({ page }) => {
  await page.goto('/login');
  await expect(page.getByRole('heading', { name: 'Welcome back' })).toBeVisible();
  await expect(page.getByText('Enterprise Software Solutions for a Smarter Tomorrow.')).toBeVisible();
  await expect(page.getByRole('textbox', { name: 'Work email' })).toBeVisible();
  await expect(page.locator('#password')).toHaveAttribute('type', 'password');
  await expect(page.locator('[data-icon="show"]')).toBeVisible();
  await expect(page.locator('[data-icon="hide"]')).toBeHidden();
  await page.getByRole('button', { name: 'Show password' }).click();
  await expect(page.locator('#password')).toHaveAttribute('type', 'text');
  await expect(page.locator('[data-icon="show"]')).toBeHidden();
  await expect(page.locator('[data-icon="hide"]')).toBeVisible();
  await expect(page.getByRole('link', { name: 'How to activate your account' })).toBeVisible();
});

test('failed login shows existing inline error, without mock success', async ({ page }) => {
  await page.route('**/api/auth/login', (route) =>
    route.fulfill({
      status: 401,
      contentType: 'application/json',
      body: JSON.stringify({ message: 'Invalid credentials.' }),
    }),
  );
  await page.goto('/login');
  await page.getByRole('textbox', { name: 'Work email' }).fill('user@example.test');
  await page.locator('#password').fill('not-a-real-password');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page.getByRole('alert')).toHaveText('Invalid credentials.');
});

test('MFA prompt matches legacy behavior', async ({ page }) => {
  await page.route('**/api/auth/login', (route) =>
    route.fulfill({
      status: 401,
      contentType: 'application/json',
      body: JSON.stringify({
        message: 'Additional authentication required.',
        code: 'MFA_REQUIRED',
        factors: [{ id: 'factor-test', name: 'Authenticator' }],
      }),
    }),
  );
  await page.goto('/login');
  await page.getByRole('textbox', { name: 'Work email' }).fill('user@example.test');
  await page.locator('#password').fill('not-a-real-password');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page.locator('#totpCode')).toBeVisible();
  await expect(page.locator('#mfaFactorField')).toBeHidden();
});

test('app login fails closed when context cannot be read', async ({ page }) => {
  await page.route('**/api/apps/CRM/contexts', (route) =>
    route.fulfill({
      status: 403,
      contentType: 'application/json',
      body: JSON.stringify({ message: 'Access denied.' }),
    }),
  );
  await page.goto('/apps/crm/login');
  await expect(page.locator('#organizationField')).toBeVisible();
  await expect(page.locator('#authSubmit')).toBeDisabled();
  await expect(page.getByRole('alert')).toHaveText('Access denied.');
  await expect(page.locator('#inviteEntry')).toBeHidden();
});

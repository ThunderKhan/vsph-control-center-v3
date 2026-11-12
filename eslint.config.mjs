import js from '@eslint/js';
import globals from 'globals';
import tseslint from 'typescript-eslint';

export default tseslint.config(
  { ignores: ['**/node_modules/**', '**/.next/**', '**/dist/**', '**/generated/**', '**/next-env.d.ts'] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  // Build scripts, source-only Node tests and backend modules need Node globals.
  { files: ['**/*.{js,mjs,cjs}', 'backend/**/*.ts', 'shared/**/*.ts', 'workers/**/*.ts',
      'frontend/next.config.ts', 'frontend/playwright.config.ts'],
    languageOptions: { globals: { ...globals.node } } },
  // Browser code also has DOM globals; Playwright tests execute in Node.
  { files: ['frontend/src/**/*.{ts,tsx}', 'frontend/tests/**/*.{ts,tsx}'],
    languageOptions: { globals: { ...globals.browser, ...globals.node } } },
);

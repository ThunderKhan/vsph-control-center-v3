/** Preserve response contracts while porting legacy endpoints. */
export type LegacyHealth = {
  status: 'ok' | 'not_configured' | 'database_unavailable';
  database: boolean;
  releaseReady: false;
  scope: string;
};

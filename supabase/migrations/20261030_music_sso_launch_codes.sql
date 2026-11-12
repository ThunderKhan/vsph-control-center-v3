-- Apply to the existing Supabase project AFTER reviewing this migration.
-- Opaque one-minute Music launch codes: no access tokens or passwords stored.
create table if not exists public.sso_launch_codes (
  code_hash text primary key check (length(code_hash)=64),
  client_id text not null check (client_id='music-vercel'),
  application_id uuid not null references public.applications(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  portal_token_hash text not null,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  code_challenge text not null check (length(code_challenge) between 43 and 128),
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index if not exists sso_launch_expiry_idx on public.sso_launch_codes(expires_at);
alter table public.sso_launch_codes enable row level security;
revoke all on table public.sso_launch_codes from public, anon, authenticated;

-- Atomic consume: a code can succeed once, even under concurrent requests.
-- Service-role-only RPC called by the VSPH backend; never expose the secret key.
create or replace function public.consume_sso_launch_code(p_code_hash text)
returns setof public.sso_launch_codes
language sql
security definer
set search_path = ''
as $$
  delete from public.sso_launch_codes
   where code_hash=p_code_hash and expires_at>now()
   returning *;
$$;
revoke all on function public.consume_sso_launch_code(text) from public, anon, authenticated;
grant execute on function public.consume_sso_launch_code(text) to service_role;

-- Optional maintenance: run periodically with trusted service-role context.
-- delete from public.sso_launch_codes where expires_at < now();

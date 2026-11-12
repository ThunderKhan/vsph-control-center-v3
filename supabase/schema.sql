-- VSPH Control Center | Supabase PostgreSQL (new empty project)
-- Run ONCE in Supabase Dashboard > SQL Editor. Does not import the previous MySQL database.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  email text not null unique,
  status text not null default 'active' check (status in ('active','disabled')),
  platform_role text not null default 'user' check (platform_role in ('user','super_admin')),
  created_at timestamptz not null default now()
);
create table if not exists public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  status text not null default 'active' check (status in ('active','suspended','closed')),
  created_at timestamptz not null default now()
);
create table if not exists public.organization_memberships (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null default 'member' check (role in ('owner','admin','member','viewer')),
  status text not null default 'active' check (status in ('invited','active','suspended')),
  created_at timestamptz not null default now(),
  primary key (organization_id,user_id)
);
create table if not exists public.applications (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[A-Z][A-Z0-9_]{1,39}$'),
  name text not null,
  login_path text not null,
  status text not null default 'active' check (status in ('active','maintenance','retired')),
  created_at timestamptz not null default now()
);
create table if not exists public.subscriptions (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  application_id uuid not null references public.applications(id) on delete cascade,
  plan_code text not null default 'prototype',
  status text not null default 'trial' check (status in ('trial','active','past_due','cancelled','expired')),
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  created_at timestamptz not null default now(),
  primary key (organization_id,application_id)
);
create table if not exists public.organization_app_access (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  application_id uuid not null references public.applications(id) on delete cascade,
  status text not null default 'enabled' check (status in ('enabled','suspended','revoked')),
  granted_at timestamptz not null default now(),
  primary key (organization_id,application_id)
);
create table if not exists public.app_roles (
  application_id uuid not null references public.applications(id) on delete cascade,
  code text not null check (code in ('super_admin','admin','manager','user','viewer')),
  name text not null,
  primary key (application_id,code)
);
create table if not exists public.user_app_roles (
  organization_id uuid not null,
  user_id uuid not null,
  application_id uuid not null,
  role_code text not null,
  created_at timestamptz not null default now(),
  primary key (organization_id,user_id,application_id),
  foreign key (organization_id,user_id) references public.organization_memberships(organization_id,user_id) on delete cascade,
  foreign key (organization_id,application_id) references public.organization_app_access(organization_id,application_id) on delete cascade,
  foreign key (application_id,role_code) references public.app_roles(application_id,code)
);
create table if not exists public.portal_sessions (
  token_hash text primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create table if not exists public.app_sessions (
  token_hash text primary key,
  portal_token_hash text not null references public.portal_sessions(token_hash) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  application_id uuid not null references public.applications(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create table if not exists public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid references public.profiles(id) on delete set null,
  organization_id uuid references public.organizations(id) on delete set null,
  action text not null,
  target_type text,
  target_id text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create table if not exists public.crm_contacts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  email text,
  company text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create table if not exists public.music_requests (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  song_title text not null,
  artist text,
  status text not null default 'submitted' check (status in ('submitted','accepted','queued','playing','played','rejected')),
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists idx_memberships_user on public.organization_memberships(user_id);
create index if not exists idx_roles_user on public.user_app_roles(user_id,application_id);
create index if not exists idx_sessions_user on public.portal_sessions(user_id,expires_at);
create index if not exists idx_app_sessions_portal on public.app_sessions(portal_token_hash,expires_at);
create index if not exists idx_crm_org on public.crm_contacts(organization_id,created_at);
create index if not exists idx_music_org on public.music_requests(organization_id,created_at);
create index if not exists idx_audit_time on public.audit_logs(created_at desc);

-- Only the trusted Express server connects using the Supabase secret/service-role key.
-- No tables are directly accessible to browser anon/authenticated roles in this prototype.
do $$ declare t text; begin
  foreach t in array array['profiles','organizations','organization_memberships','applications',
    'subscriptions','organization_app_access','app_roles','user_app_roles','portal_sessions',
    'app_sessions','audit_logs','crm_contacts','music_requests'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all privileges on public.%I from anon, authenticated',t);
  end loop;
end $$;

insert into public.applications (code,name,login_path,status) values
('CRM','Customer Relationship Management','/apps/crm/login','active'),
('MUSIC','Music Management','/apps/music/login','active')
on conflict(code) do update set name=excluded.name, login_path=excluded.login_path;
insert into public.app_roles (application_id,code,name)
select a.id, r.code, r.name from public.applications a
cross join (values ('super_admin','Super Administrator'),('admin','Administrator'),
 ('manager','Manager'),('user','User'),('viewer','Viewer')) r(code,name)
where a.code in ('CRM','MUSIC')
on conflict (application_id,code) do nothing;

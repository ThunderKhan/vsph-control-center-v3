-- Phase 4: internal Outreach grants and confidential one-use launch codes.
-- New forward-only migration. Never apply automatically to an existing hosted DB.
-- IMPORTANT: No application or employee role is seeded by this migration.
create table public.outreach_staff_grants (
  user_id uuid primary key references public.profiles(id) on delete restrict,
  role_code text not null check (role_code in ('administrator','manager','representative','analyst')),
  status text not null default 'enabled' check (status in ('enabled','revoked')),
  granted_by uuid not null references public.profiles(id) on delete restrict,
  version integer not null default 1 check (version between 1 and 2147483647),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.outreach_staff_grants enable row level security;
revoke all on public.outreach_staff_grants from public,anon,authenticated;
grant select,insert,update on public.outreach_staff_grants to service_role;

create table public.outreach_launch_codes (
  code_hash text primary key check (code_hash ~ '^[a-f0-9]{64}$'),
  client_id text not null default 'outreach-internal' check (client_id='outreach-internal'),
  application_id uuid not null references public.applications(id) on delete restrict,
  user_id uuid not null references public.profiles(id) on delete restrict,
  portal_token_hash text not null references public.portal_sessions(token_hash) on delete cascade,
  code_challenge text not null check (code_challenge ~ '^[A-Za-z0-9_-]{43,128}$'),
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index outreach_launch_expiry_idx on public.outreach_launch_codes(expires_at);
alter table public.outreach_launch_codes enable row level security;
revoke all on public.outreach_launch_codes from public,anon,authenticated;
grant select,insert,delete on public.outreach_launch_codes to service_role;

-- Current entitlement: active portal identity and session, explicit enabled grant,
-- active OUTREACH registry entry, plus current active internal employment.
-- Platform owner is allowed ONLY with a separate explicit grant; their platform
-- status never grants Outreach by itself. No customer org access is consulted.
create function public.outreach_current_access(p_user uuid,p_session text)
returns text language plpgsql security definer set search_path='' as $$
declare granted_role text;
begin
  if p_user is null or coalesce(p_session,'') !~ '^[a-f0-9]{64}$' then return null; end if;
  select g.role_code into granted_role
    from public.profiles p
    join public.outreach_staff_grants g on g.user_id=p.id and g.status='enabled'
    join public.portal_sessions s on s.user_id=p.id and s.token_hash=p_session
      and s.expires_at>clock_timestamp()
   where p.id=p_user and p.status='active'
     and exists(select 1 from public.applications a where a.code='OUTREACH' and a.status='active')
     and (
       p.platform_role='super_admin' or exists(
         select 1 from public.internal_employee_identity_links l
         join public.internal_employees e on e.id=l.employee_id
         where l.user_id=p.id and l.status='linked'
           and e.email=lower(p.email) and e.status='active'
       )
     )
   for share of p,g,s;
  return granted_role;
end$$;
revoke all on function public.outreach_current_access(uuid,text) from public,anon,authenticated;
grant execute on function public.outreach_current_access(uuid,text) to service_role;

-- Issue only while the portal session and current employment/grant are valid.
create function public.outreach_issue_code(
  p_actor uuid,p_session text,p_code_hash text,p_challenge text
) returns boolean language plpgsql security definer set search_path='' as $$
declare a_id uuid;
begin
  if p_code_hash is null or p_code_hash !~ '^[a-f0-9]{64}$'
     or p_challenge is null or p_challenge !~ '^[A-Za-z0-9_-]{43,128}$'
     or public.outreach_current_access(p_actor,p_session) is null then
    raise exception 'Outreach launch denied' using errcode='42501';
  end if;
  select id into a_id from public.applications where code='OUTREACH' and status='active';
  if a_id is null then raise exception 'Outreach unavailable' using errcode='42501';end if;
  insert into public.outreach_launch_codes
     (code_hash,application_id,user_id,portal_token_hash,code_challenge,expires_at)
  values(p_code_hash,a_id,p_actor,p_session,p_challenge,clock_timestamp()+interval '60 seconds');
  return true;
end$$;
revoke all on function public.outreach_issue_code(uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.outreach_issue_code(uuid,text,text,text) to service_role;

-- Atomic DELETE ... RETURNING consumes even incorrect verifier attempts.
-- This intentionally prevents replay after a failed/attacker exchange.
create function public.outreach_consume_code(p_code_hash text,p_challenge text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.outreach_launch_codes; current_role text;
begin
  if p_code_hash is null or p_code_hash !~ '^[a-f0-9]{64}$'
     or p_challenge is null or p_challenge !~ '^[A-Za-z0-9_-]{43,128}$'
     then return null;end if;
  delete from public.outreach_launch_codes
   where code_hash=p_code_hash and expires_at>clock_timestamp()
   returning * into c;
  if not found or c.code_challenge<>p_challenge then return null;end if;
  current_role:=public.outreach_current_access(c.user_id,c.portal_token_hash);
  if current_role is null then return null;end if;
  return jsonb_build_object('user_id',c.user_id,'portal_session_ref',c.portal_token_hash,
    'role',current_role,'application','OUTREACH');
end$$;
revoke all on function public.outreach_consume_code(text,text) from public,anon,authenticated;
grant execute on function public.outreach_consume_code(text,text) to service_role;

create function public.outreach_introspect(p_user uuid,p_session text)
returns jsonb language plpgsql security definer set search_path='' as $
declare live_role text;
begin
  live_role:=public.outreach_current_access(p_user,p_session);
  if live_role is null then return jsonb_build_object('active',false);end if;
  return jsonb_build_object('active',true,'user_id',p_user,
    'role',live_role,'application','OUTREACH');
end$;
revoke all on function public.outreach_introspect(uuid,text) from public,anon,authenticated;
grant execute on function public.outreach_introspect(uuid,text) to service_role;

-- Only VSPH's currently authenticated platform owner can grant/revoke.
-- Calls are made by the server with the verified actor and portal session hash.
create function public.outreach_access_command(
  p_actor uuid,p_session text,p_action text,p_target uuid default null,p_role text default null
) returns jsonb language plpgsql security definer set search_path='' as $$
declare target public.profiles; grant_record public.outreach_staff_grants; n integer;
begin
  perform 1 from public.profiles p join public.portal_sessions s on s.user_id=p.id
    where p.id=p_actor and p.status='active' and p.platform_role='super_admin'
      and s.token_hash=p_session and s.expires_at>clock_timestamp()
    for share of p,s;
  if not found then raise exception 'Owner session required' using errcode='42501';end if;
  if p_action='list' then
    if p_target is not null or p_role is not null then
      raise exception 'Unexpected fields' using errcode='22023';end if;
    return jsonb_build_object('items',coalesce((
      select jsonb_agg(x) from (
        select g.user_id,g.role_code,g.status,g.version,g.updated_at,p.full_name,p.email
          from public.outreach_staff_grants g join public.profiles p on p.id=g.user_id
         order by g.updated_at desc,g.user_id limit 100
      ) x
    ),'[]'::jsonb));
  end if;
  if p_action not in ('grant','revoke') or p_target is null then
    raise exception 'Invalid grant command' using errcode='22023';end if;
  select * into target from public.profiles where id=p_target for share;
  if not found then raise exception 'Target unavailable' using errcode='42501';end if;
  if p_action='grant' then
    if target.status<>'active' then
      raise exception 'Only active employees can receive access' using errcode='42501';
    end if;
    if p_role is null or p_role not in ('administrator','manager','representative','analyst')
      or (target.platform_role<>'super_admin' and not exists(
        select 1 from public.internal_employee_identity_links l
        join public.internal_employees e on e.id=l.employee_id
        where l.user_id=target.id and l.status='linked'
          and e.email=lower(target.email) and e.status='active'
      )) then
      raise exception 'Active linked employee and valid role required' using errcode='42501';
    end if;
    insert into public.outreach_staff_grants(user_id,role_code,status,granted_by)
      values(p_target,p_role,'enabled',p_actor)
      on conflict(user_id) do update set role_code=excluded.role_code,status='enabled',
        granted_by=p_actor,version=outreach_staff_grants.version+1,updated_at=clock_timestamp()
      returning * into grant_record;
  else
    if p_role is not null then raise exception 'Unexpected role' using errcode='22023';end if;
    update public.outreach_staff_grants set status='revoked',version=version+1,
      granted_by=p_actor,updated_at=clock_timestamp()
      where user_id=p_target and status='enabled' returning * into grant_record;
    if not found then raise exception 'No enabled grant' using errcode='22023';end if;
  end if;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,details)
    values(p_actor,'outreach.'||p_action,'profile',p_target::text,
      jsonb_build_object('role',grant_record.role_code,'version',grant_record.version));
  return jsonb_build_object('user_id',grant_record.user_id,'role',grant_record.role_code,
    'status',grant_record.status,'version',grant_record.version);
end$$;
revoke all on function public.outreach_access_command(uuid,text,text,uuid,text) from public,anon,authenticated;
grant execute on function public.outreach_access_command(uuid,text,text,uuid,text) to service_role;

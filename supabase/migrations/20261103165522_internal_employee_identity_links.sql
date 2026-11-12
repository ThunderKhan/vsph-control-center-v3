-- Existing-account consent only. No Auth creation/password reset, email or tenant grant.
create table public.internal_employee_link_requests(
 id uuid primary key default gen_random_uuid(),
 idempotency_key uuid not null unique,
 employee_id uuid not null references public.internal_employees(id),
 candidate_user_id uuid not null references public.profiles(id),
 issuer_id uuid not null references public.profiles(id),
 purpose text not null default 'internal_employee_link' check(purpose='internal_employee_link'),
 email text not null,
 roster_version integer not null check(roster_version>0),
 version integer not null default 1 check(version>0),
 state text not null default 'pending' check(state in ('pending','accepted','cancelled','expired','revoked')),
 created_at timestamptz not null default now(),expires_at timestamptz not null default now()+interval '7 days',
 accepted_at timestamptz,
 check(expires_at>created_at)
);
create unique index internal_employee_link_pending on public.internal_employee_link_requests(employee_id) where state='pending';
create index internal_employee_link_inbox on public.internal_employee_link_requests(candidate_user_id,state,expires_at);
create table public.internal_employee_identity_links(
 employee_id uuid primary key references public.internal_employees(id),
 user_id uuid not null references public.profiles(id),
 request_id uuid not null unique references public.internal_employee_link_requests(id),
 status text not null check(status in ('linked','revoked')),
 version integer not null default 1 check(version>0),
 accepted_at timestamptz not null default now(), revoked_at timestamptz,
 check((status='revoked')=(revoked_at is not null))
);
create unique index internal_employee_link_user on public.internal_employee_identity_links(user_id) where status='linked';
do $$declare t text;begin foreach t in array array['internal_employee_link_requests','internal_employee_identity_links'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('revoke all on public.%I from public,anon,authenticated',t);
 execute format('grant select,insert,update,delete on public.%I to service_role',t);
end loop;end$$;

create function public.internal_workforce_authority(p_actor uuid) returns text language sql stable security definer set search_path='' as $$
 select case when u.platform_role='super_admin' then 'owner' when exists(
  select 1 from public.internal_hr_managers h join public.internal_employees e on e.id=h.employee_id
  where h.user_id=u.id and e.email=u.email and e.status='active') then 'hr' end
 from public.profiles u where u.id=p_actor and u.status='active'
$$;
revoke all on function public.internal_workforce_authority(uuid) from public,anon,authenticated;
grant execute on function public.internal_workforce_authority(uuid) to service_role;

create function public.internal_employee_identity(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 actor public.profiles; employee public.internal_employees; request public.internal_employee_link_requests;
 linked public.internal_employee_identity_links; target_id uuid; candidate uuid; issuer uuid; authority text;
 checked_key text; response jsonb; existing_request public.internal_employee_link_requests; removed integer;
begin
 if p_action is null or p_action not in ('inbox','manage','request','renew','cancel','accept','revoke','grant_hr') or jsonb_typeof(p_data) is distinct from 'object' then raise exception 'Invalid identity command' using errcode='22023';end if;
 if exists(select 1 from jsonb_object_keys(p_data) k where k not in ('currentHash','key','rosterVersion','requestId','requestVersion','linkVersion','confirmed','verifiedAt','assurance')) then raise exception 'Invalid identity fields' using errcode='22023';end if;
 foreach checked_key in array array['rosterVersion','requestVersion','linkVersion'] loop
  if p_data?checked_key then
   if jsonb_typeof(p_data->checked_key)<>'number' then raise exception 'Invalid version type' using errcode='22023';end if;
   if p_data->>checked_key !~ '^[1-9][0-9]{0,9}$' then raise exception 'Invalid version' using errcode='22023';end if;
   if (p_data->>checked_key)::numeric>2147483647 then raise exception 'Invalid version range' using errcode='22023';end if;
  end if;
 end loop;
 if p_action='accept' then select employee_id,candidate_user_id,issuer_id into target_id,candidate,issuer from public.internal_employee_link_requests where id=p_id;
 else target_id:=p_id;select id into candidate from public.profiles where email=(select email from public.internal_employees where id=target_id);end if;
 -- All participating profiles precede portal sessions, roster rows and grants.
 perform 1 from public.profiles u where u.id in (p_actor,candidate,issuer)
 order by case when u.platform_role='super_admin' then 0 else 1 end,u.id for share;
 select * into actor from public.profiles where id=p_actor and status='active';
 if not found then raise exception 'Active identity required' using errcode='42501';end if;
 perform 1 from public.portal_sessions s where s.user_id=p_actor and s.token_hash=p_data->>'currentHash' and s.expires_at>clock_timestamp() for update;
 if not found then raise exception 'Current session required' using errcode='42501';end if;
 if not exists(select 1 from public.portal_sessions where user_id=p_actor and token_hash=p_data->>'currentHash' and expires_at>clock_timestamp()) then raise exception 'Session expired while waiting' using errcode='42501';end if;
 if p_action='inbox' then
  if p_id is not null or p_data-array['currentHash']<>'{}'::jsonb then raise exception 'Invalid inbox fields' using errcode='22023';end if;
  return jsonb_build_object('requests',coalesce((select jsonb_agg(x) from(
   select r.id,r.employee_id,r.version,r.roster_version,e.version current_roster_version,r.expires_at,e.full_name,e.department,e.job_title,e.status
   from public.internal_employee_link_requests r join public.internal_employees e on e.id=r.employee_id
   where r.candidate_user_id=p_actor and r.email=actor.email and e.email=actor.email and r.state='pending' and r.expires_at>clock_timestamp()
    and e.status in ('onboarding','active') and public.internal_workforce_authority(r.issuer_id) is not null
    and (public.internal_workforce_authority(r.issuer_id)='owner' or not exists(select 1 from public.internal_hr_managers h where h.employee_id=e.id))
   order by r.created_at desc,r.id limit 20)x),'[]'),
   'employment',coalesce((select jsonb_agg(x) from(select e.full_name,e.department,e.job_title,e.employment_type,e.start_date,e.status
    from public.internal_employee_identity_links l join public.internal_employees e on e.id=l.employee_id
    where l.user_id=p_actor and l.status='linked' and e.email=actor.email and e.status<>'inactive')x),'[]'));
 end if;
 perform 1 from public.internal_employees e where e.id=target_id or e.id in(
  select h.employee_id from public.internal_hr_managers h where h.user_id in (p_actor,issuer)) order by e.id for update;
 perform 1 from public.internal_hr_managers h where h.employee_id=target_id or h.user_id in (p_actor,issuer) order by h.employee_id for update;
 if not exists(select 1 from public.portal_sessions where user_id=p_actor and token_hash=p_data->>'currentHash' and expires_at>clock_timestamp()) then raise exception 'Session expired while waiting' using errcode='42501';end if;
 select * into employee from public.internal_employees where id=target_id;
 if not found then raise exception 'Employee unavailable' using errcode='42501';end if;
 select * into linked from public.internal_employee_identity_links where employee_id=employee.id for update;
 if p_action='accept' then
  select * into request from public.internal_employee_link_requests where id=p_id and candidate_user_id=p_actor and purpose='internal_employee_link' for update;
  if not found or actor.platform_role<>'user' or actor.email<>request.email or employee.email<>actor.email or employee.status not in ('onboarding','active') then raise exception 'Link request unavailable' using errcode='42501';end if;
  authority:=public.internal_workforce_authority(request.issuer_id);
  if authority is null or (authority<>'owner' and exists(select 1 from public.internal_hr_managers where employee_id=employee.id)) then raise exception 'Issuer no longer authorized' using errcode='42501';end if;
  if p_data->'confirmed' is distinct from 'true'::jsonb or coalesce(p_data->>'assurance','') not in ('aal1','aal2') or nullif(p_data->>'verifiedAt','') is null then raise exception 'Fresh identity verification required' using errcode='42501';end if;
  if (p_data->>'verifiedAt')::timestamptz<clock_timestamp()-interval '30 seconds' or (p_data->>'verifiedAt')::timestamptz>clock_timestamp()+interval '5 seconds' then raise exception 'Identity verification expired' using errcode='42501';end if;
  if request.version is distinct from (p_data->>'requestVersion')::integer then raise exception 'Stale request' using errcode='40001';end if;
  if request.state='accepted' and linked.status='linked' and linked.request_id=request.id and linked.user_id=p_actor then return jsonb_build_object('linked',true,'replayed',true);end if;
  if request.state<>'pending' or request.expires_at<=clock_timestamp() then raise exception 'Link request expired or unavailable' using errcode='42501';end if;
  if employee.version<>request.roster_version or employee.version is distinct from (p_data->>'rosterVersion')::integer then raise exception 'Roster changed; request renewal required' using errcode='40001';end if;
  if linked.status='linked' then raise exception 'Existing link requires review' using errcode='40001';end if;
  insert into public.internal_employee_identity_links(employee_id,user_id,request_id,status) values(employee.id,p_actor,request.id,'linked')
   on conflict(employee_id) do update set user_id=excluded.user_id,request_id=excluded.request_id,status='linked',version=internal_employee_identity_links.version+1,accepted_at=now(),revoked_at=null;
  update public.internal_employee_link_requests set state='accepted',accepted_at=now(),version=version+1 where id=request.id;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,details) values(p_actor,'employee.identity_link_accepted','internal_employee',employee.id::text,jsonb_build_object('requestId',request.id,'assurance',p_data->>'assurance'));
  return jsonb_build_object('linked',true,'replayed',false);
 end if;
 authority:=public.internal_workforce_authority(p_actor);
 if authority is null or (authority<>'owner' and (exists(select 1 from public.internal_hr_managers where employee_id=employee.id) or exists(select 1 from public.profiles where email=employee.email and platform_role='super_admin'))) then raise exception 'Workforce authority required' using errcode='42501';end if;
 if p_action='manage' then
  if p_data-array['currentHash']<>'{}'::jsonb then raise exception 'Invalid review fields' using errcode='22023';end if;
  return jsonb_build_object('employee',jsonb_build_object('id',employee.id,'fullName',employee.full_name,'email',employee.email,'status',employee.status,'version',employee.version),
   'link',case when linked.employee_id is null then null else jsonb_build_object('status',linked.status,'version',linked.version) end,
   'requests',coalesce((select jsonb_agg(x) from(select r.id,r.version,r.roster_version,case when r.state='pending' and r.expires_at<=clock_timestamp() then 'expired' else r.state end state,r.expires_at,r.created_at from public.internal_employee_link_requests r
    where r.employee_id=employee.id and (authority='owner' or r.issuer_id=p_actor) order by (r.state='pending') desc,r.created_at desc,r.id limit 20)x),'[]'));
 end if;
 if p_data->'confirmed' is distinct from 'true'::jsonb or employee.version is distinct from (p_data->>'rosterVersion')::integer then raise exception 'Review current roster version' using errcode='40001';end if;
 if p_action='grant_hr' then
  if authority<>'owner' or linked.status is distinct from 'linked' or not exists(select 1 from public.profiles where id=linked.user_id and email=employee.email and status='active' and platform_role='user') then
   raise exception 'Owner approval and accepted active account link required' using errcode='42501';
  end if;
  return public.internal_employee_core_command(p_actor,'grant_hr',employee.id,jsonb_build_object('version',employee.version,'confirmed',true));
 end if;
 if p_action='revoke' then
  if linked.status is distinct from 'linked' or linked.version is distinct from (p_data->>'linkVersion')::integer then raise exception 'Link changed' using errcode='40001';end if;
  update public.internal_employee_identity_links set status='revoked',version=version+1,revoked_at=now() where employee_id=employee.id;
  update public.internal_employee_link_requests set state='revoked',version=version+1 where id=linked.request_id;
  delete from public.internal_hr_managers where employee_id=employee.id;get diagnostics removed=row_count;
  if removed>0 then update public.internal_employees set version=version+1,updated_at=now(),updated_by=p_actor where id=employee.id;end if;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,details) values(p_actor,'employee.identity_link_revoked','internal_employee',employee.id::text,jsonb_build_object('hrRevoked',removed>0));
  return jsonb_build_object('revoked',true);
 end if;
 if p_action in ('renew','cancel') then
  select * into request from public.internal_employee_link_requests where id=(p_data->>'requestId')::uuid and employee_id=employee.id for update;
  if not found or (authority<>'owner' and request.issuer_id<>p_actor) then raise exception 'Request unavailable' using errcode='42501';end if;
  if request.state not in ('pending','expired') or request.version is distinct from (p_data->>'requestVersion')::integer then raise exception 'Request changed' using errcode='40001';end if;
  if p_action='renew' then
   if employee.status not in ('onboarding','active') or linked.status='linked' or not exists(select 1 from public.profiles where id=request.candidate_user_id and email=employee.email and status='active' and platform_role='user') then raise exception 'Candidate unavailable' using errcode='42501';end if;
   update public.internal_employee_link_requests set state='pending',issuer_id=p_actor,version=version+1,roster_version=employee.version,expires_at=clock_timestamp()+interval '7 days' where id=request.id;
  else update public.internal_employee_link_requests set state='cancelled',version=version+1 where id=request.id;end if;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,details) values(p_actor,'employee.identity_request_'||p_action,'internal_employee',employee.id::text,jsonb_build_object('requestId',request.id));
  return jsonb_build_object('saved',true);
 end if;
 if p_action='request' then
  select * into existing_request from public.internal_employee_link_requests where idempotency_key=(p_data->>'key')::uuid;
  if found then
   if existing_request.issuer_id<>p_actor or existing_request.employee_id<>employee.id or existing_request.roster_version<>(p_data->>'rosterVersion')::integer then raise exception 'Idempotency conflict' using errcode='23505';end if;
   return jsonb_build_object('id',existing_request.id,'state',existing_request.state,'replayed',true);
  end if;
  if employee.status not in ('onboarding','active') or linked.status='linked' or not exists(select 1 from public.profiles where id=candidate and email=employee.email and status='active' and platform_role='user') then raise exception 'Existing matching active ordinary portal account required' using errcode='42501';end if;
  update public.internal_employee_link_requests set state='expired',version=version+1 where employee_id=employee.id and state='pending' and expires_at<=clock_timestamp();
  insert into public.internal_employee_link_requests(idempotency_key,employee_id,candidate_user_id,issuer_id,email,roster_version)
   values((p_data->>'key')::uuid,employee.id,candidate,p_actor,employee.email,employee.version) returning * into request;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,details) values(p_actor,'employee.identity_link_requested','internal_employee',employee.id::text,jsonb_build_object('requestId',request.id));
  return jsonb_build_object('id',request.id,'state',request.state,'replayed',false);
 end if;
 raise exception 'Invalid identity action' using errcode='22023';
end$$;
revoke all on function public.internal_employee_identity(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.internal_employee_identity(uuid,text,uuid,jsonb) to service_role;

-- Revocation does not disable a portal/customer identity or erase its assignments.
create function public.internal_employee_identity_lifecycle() returns trigger language plpgsql security definer set search_path='' as $$
declare requests_changed integer:=0; links_changed integer:=0; hr_changed integer:=0;
begin
 if tg_table_name='profiles' then
  if new.status='disabled' or new.email is distinct from old.email then
   delete from public.internal_hr_managers where user_id=new.id;get diagnostics hr_changed=row_count;
   update public.internal_employee_link_requests set state='revoked',version=version+1 where candidate_user_id=new.id and state in ('pending','accepted');get diagnostics requests_changed=row_count;
   update public.internal_employee_identity_links set status='revoked',version=version+1,revoked_at=now() where user_id=new.id and status='linked';get diagnostics links_changed=row_count;
  end if;
 elsif new.status='inactive' or new.email is distinct from old.email then
  update public.internal_employee_link_requests set state='revoked',version=version+1 where employee_id=new.id and state in ('pending','accepted');get diagnostics requests_changed=row_count;
  update public.internal_employee_identity_links set status='revoked',version=version+1,revoked_at=now() where employee_id=new.id and status='linked';get diagnostics links_changed=row_count;
  delete from public.internal_hr_managers where employee_id=new.id;get diagnostics hr_changed=row_count;
 end if;
 if requests_changed+links_changed+hr_changed>0 then
  -- The enclosing governed profile/roster command separately audits its actor.
  -- A direct maintenance change has no invented human attribution.
  insert into public.audit_logs(action,target_type,target_id,details) values('employee.identity_lifecycle_revoked',tg_table_name,new.id::text,
   jsonb_build_object('requests',requests_changed,'links',links_changed,'hrGrants',hr_changed));
 end if;
 return new;
end$$;
revoke all on function public.internal_employee_identity_lifecycle() from public,anon,authenticated;
grant execute on function public.internal_employee_identity_lifecycle() to service_role;
create trigger internal_employee_identity_lifecycle after update of status,email on public.internal_employees for each row execute function public.internal_employee_identity_lifecycle();
create trigger internal_identity_profile_lifecycle after update of status,email on public.profiles for each row execute function public.internal_employee_identity_lifecycle();

-- Existing HR grants are preserved. New/regranted HR authority needs consent.
create or replace function public.internal_employee_command(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if p_action is null or p_action not in ('access','list','create','update','grant_hr','revoke_hr') or jsonb_typeof(p_data) is distinct from 'object' then
  raise exception 'Invalid workforce command' using errcode='22023';
 end if;
 if p_action in ('update','grant_hr','revoke_hr') and (
  jsonb_typeof(p_data->'version') is distinct from 'number' or
  coalesce(p_data->>'version','')!~'^[1-9][0-9]{0,9}$' or
  (p_data->>'version')::numeric>2147483647) then
  raise exception 'Invalid employee version' using errcode='22023';
 end if;
 -- Same platform-first profile order as account deactivation. Grant targets
 -- are resolved before taking any employee/grant lock, never afterwards.
 perform 1 from public.profiles u where u.id=p_actor or
  (p_action='grant_hr' and u.email=(select e.email from public.internal_employees e where e.id=p_id))
 order by case when u.platform_role='super_admin' then 0 else 1 end,u.id for share;
 if not exists(select 1 from public.profiles where id=p_actor and status='active') then
  raise exception 'Active portal identity required' using errcode='42501';
 end if;
 -- HR's own roster and a mutation target are locked in immutable ID order.
 -- Take these BEFORE any grant row, including on read/access requests.
 perform 1 from public.internal_employees e where
  e.id in (select h.employee_id from public.internal_hr_managers h where h.user_id=p_actor)
  or (p_action in ('update','grant_hr','revoke_hr') and e.id=p_id)
  or (p_action='create' and e.idempotency_key=p_id)
 order by e.id for update;
 perform 1 from public.internal_hr_managers h where h.user_id=p_actor or
  (p_action in ('update','grant_hr','revoke_hr') and h.employee_id=p_id)
 order by h.employee_id for update;
 if p_action='grant_hr' and not exists(select 1 from public.internal_employee_identity_links l
  join public.internal_employees e on e.id=l.employee_id join public.profiles u on u.id=l.user_id
  where l.employee_id=p_id and l.status='linked' and u.status='active' and u.platform_role='user' and u.email=e.email) then
  raise exception 'Accepted employee account link required before a new HR grant' using errcode='42501';
 end if;
 -- Core rechecks the current actor, current grant/roster, protected targets,
 -- optimistic versions and all mutation fields after lock waits.
 return public.internal_employee_core_command(p_actor,p_action,p_id,p_data);
end$$;
revoke all on function public.internal_employee_command(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.internal_employee_command(uuid,text,uuid,jsonb) to service_role;

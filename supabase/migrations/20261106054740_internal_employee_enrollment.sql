-- New-identity employee enrollment only. Existing identities use consent linking.
-- Auth side effects are outside SQL; a disabled profile gates every partial failure.
create table public.internal_employee_enrollments(
 id uuid primary key default gen_random_uuid(),
 employee_id uuid not null unique references public.internal_employees(id),
 issuer_id uuid not null references public.profiles(id),
 auth_user_id uuid not null unique default gen_random_uuid(),
 idempotency_key uuid not null unique,
 purpose text not null default 'internal_employee_enrollment' check(purpose='internal_employee_enrollment'),
 email text not null, roster_version integer not null check(roster_version>0),
 version integer not null default 1 check(version>0),
 state text not null default 'provisioning' check(state in ('provisioning','ready','accepting','accepted','cancelled','recovery_required')),
 token_hash text not null check(token_hash ~ '^[0-9a-f]{64}$'),
 acceptance_id uuid, account_blocked boolean not null default false,
 created_at timestamptz not null default now(), expires_at timestamptz not null default now()+interval '7 days',
 accepted_at timestamptz, check(expires_at>created_at)
);
alter table public.internal_employee_enrollments enable row level security;
revoke all on public.internal_employee_enrollments from public,anon,authenticated;
grant select,insert,update,delete on public.internal_employee_enrollments to service_role;

create function public.internal_employee_enrollment(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 e public.internal_employees; r public.internal_employee_enrollments;
 target uuid; issuer uuid; candidate uuid; authority text; link_id uuid;
 manager boolean:=p_action in ('review','start','renew','cancel','ready'); valid boolean;
begin
 if p_action is null or p_action not in ('review','start','renew','cancel','ready','inspect','reserve','finish','failed','reject') or jsonb_typeof(p_data) is distinct from 'object'
 or exists(select 1 from jsonb_object_keys(p_data) k where k not in ('currentHash','key','rosterVersion','version','confirmed','tokenHash','acceptanceId')) then raise exception 'Invalid enrollment command' using errcode='22023';end if;
 if p_action in ('review','start') then
  target:=p_id;select * into r from public.internal_employee_enrollments where employee_id=target;
 else select * into r from public.internal_employee_enrollments where id=p_id;target:=r.employee_id;end if;
 issuer:=r.issuer_id;candidate:=r.auth_user_id;
 -- Match the platform-first profile -> session -> immutable roster -> HR order.
 perform 1 from public.profiles u where u.id in(p_actor,issuer,candidate) or u.email=(select email from public.internal_employees where id=target)
 order by case when u.platform_role='super_admin' then 0 else 1 end,u.id for update;
 if manager then
  if p_actor is null or not exists(select 1 from public.profiles where id=p_actor and status='active') then raise exception 'Workforce identity required' using errcode='42501';end if;
  perform 1 from public.portal_sessions where user_id=p_actor and token_hash=p_data->>'currentHash' and expires_at>clock_timestamp() for update;
  if not found then raise exception 'Current session required' using errcode='42501';end if;
 elsif p_actor is not null then raise exception 'Capability enrollment cannot select an actor' using errcode='42501';end if;
 perform 1 from public.internal_employees x where x.id=target or x.id in(select employee_id from public.internal_hr_managers where user_id in(p_actor,issuer)) order by x.id for update;
 perform 1 from public.internal_hr_managers where employee_id=target or user_id in(p_actor,issuer) order by employee_id for update;
 select * into e from public.internal_employees where id=target;
 if not found then raise exception 'Enrollment unavailable' using errcode='42501';end if;
 if manager then
  authority:=public.internal_workforce_authority(p_actor);
  if authority is null or not exists(select 1 from public.portal_sessions where user_id=p_actor and token_hash=p_data->>'currentHash' and expires_at>clock_timestamp())
   or (authority<>'owner' and (exists(select 1 from public.internal_hr_managers where employee_id=e.id) or exists(select 1 from public.profiles where email=e.email and platform_role='super_admin'))) then raise exception 'Current workforce authority required' using errcode='42501';end if;
 end if;
 select * into r from public.internal_employee_enrollments where employee_id=target for update;
 if p_action='review' then
  if p_data-array['currentHash']<>'{}'::jsonb then raise exception 'Invalid review fields' using errcode='22023';end if;
  return jsonb_build_object('available',r.id is not null or not exists(select 1 from public.profiles where email=e.email),
   'enrollment',case when r.id is null then null else jsonb_build_object('id',r.id,'version',r.version,'state',case when r.state in ('ready','provisioning') and r.expires_at<=clock_timestamp() then 'expired' else r.state end,'expiresAt',r.expires_at) end);
 end if;
 if manager then
  if p_data->'confirmed' is distinct from 'true'::jsonb or jsonb_typeof(p_data->'rosterVersion') is distinct from 'number' or p_data->>'rosterVersion' !~ '^[1-9][0-9]{0,9}$' or (p_data->>'rosterVersion')::numeric>2147483647 then raise exception 'Confirm current roster' using errcode='22023';end if;
  if e.version is distinct from (p_data->>'rosterVersion')::integer then raise exception 'Roster changed' using errcode='40001';end if;
 end if;
 if p_action='start' then
  if coalesce(p_data->>'tokenHash','')!~'^[0-9a-f]{64}$' or nullif(p_data->>'key','') is null then raise exception 'Invalid issuance' using errcode='22023';end if;
  if r.id is not null then
   if r.idempotency_key=(p_data->>'key')::uuid and r.issuer_id=p_actor then return jsonb_build_object('id',r.id,'replayed',true);end if;
   raise exception 'Enrollment already exists; review or reissue' using errcode='40001';
  end if;
  if e.status not in ('onboarding','active') or exists(select 1 from public.profiles where email=e.email) or exists(select 1 from public.internal_employee_identity_links where employee_id=e.id and status='linked') then raise exception 'Use existing-account consent or review employment' using errcode='42501';end if;
  insert into public.internal_employee_enrollments(employee_id,issuer_id,idempotency_key,email,roster_version,token_hash)
   values(e.id,p_actor,(p_data->>'key')::uuid,e.email,e.version,p_data->>'tokenHash') returning * into r;
 elsif manager then
  if r.id is null or (authority<>'owner' and r.issuer_id<>p_actor) then raise exception 'Enrollment unavailable' using errcode='42501';end if;
  if jsonb_typeof(p_data->'version') is distinct from 'number' or p_data->>'version'!~'^[1-9][0-9]{0,9}$' or (p_data->>'version')::numeric>2147483647 then raise exception 'Invalid enrollment version' using errcode='22023';end if;
  if r.version is distinct from (p_data->>'version')::integer then raise exception 'Enrollment changed' using errcode='40001';end if;
  if p_action='cancel' then
   if r.state='accepted' then raise exception 'Use account-link revocation' using errcode='40001';end if;
   update public.internal_employee_enrollments set state='cancelled',version=version+1 where id=r.id;
  elsif p_action='renew' then
   if r.state not in ('provisioning','ready','cancelled') or r.acceptance_id is not null or r.account_blocked or e.status not in ('onboarding','active') or e.email<>r.email or coalesce(p_data->>'tokenHash','')!~'^[0-9a-f]{64}$'
    or exists(select 1 from public.profiles where email=e.email and (id<>r.auth_user_id or status<>'disabled' or platform_role<>'user')) then raise exception 'Enrollment requires recovery' using errcode='42501';end if;
   update public.internal_employee_enrollments set token_hash=p_data->>'tokenHash',issuer_id=p_actor,roster_version=e.version,expires_at=clock_timestamp()+interval '7 days',state='provisioning',version=version+1 where id=r.id returning * into r;
  elsif p_action='ready' then
   if r.state<>'provisioning' or r.email<>e.email or e.status not in ('onboarding','active') or r.roster_version<>e.version or r.expires_at<=clock_timestamp() then raise exception 'Enrollment no longer eligible' using errcode='42501';end if;
   if exists(select 1 from public.profiles where email=r.email and id<>r.auth_user_id) then raise exception 'Existing identity cannot be enrolled' using errcode='42501';end if;
   insert into public.profiles(id,full_name,email,status,platform_role) values(r.auth_user_id,e.full_name,r.email,'disabled','user') on conflict(id) do nothing;
   if not exists(select 1 from public.profiles where id=r.auth_user_id and email=r.email and status='disabled' and platform_role='user') then raise exception 'Identity changed' using errcode='42501';end if;
   update public.internal_employee_enrollments set state='ready',version=version+1 where id=r.id returning * into r;
  end if;
 else
  if r.id is null or r.purpose<>'internal_employee_enrollment' or r.token_hash is distinct from p_data->>'tokenHash' then raise exception 'Invitation unavailable' using errcode='42501';end if;
  if p_action='failed' then
   -- Never automatically retry an ambiguous external password write.
   if r.state='accepting' and r.acceptance_id=(p_data->>'acceptanceId')::uuid then
    update public.internal_employee_enrollments set state='recovery_required',version=version+1 where id=r.id;
    insert into public.audit_logs(action,target_type,target_id,details) values('employee.enrollment_failed','internal_employee',e.id::text,jsonb_build_object('enrollmentId',r.id,'recoveryRequired',true));
   end if;
   return jsonb_build_object('recoveryRequired',true);
  end if;
  authority:=public.internal_workforce_authority(r.issuer_id);
  valid:=not r.account_blocked and r.expires_at>clock_timestamp() and e.status in ('onboarding','active') and e.email=r.email and e.version=r.roster_version and authority is not null
   and (authority='owner' or not exists(select 1 from public.internal_hr_managers where employee_id=e.id))
   and exists(select 1 from public.profiles where id=r.auth_user_id and email=r.email and status='disabled' and platform_role='user')
   and not exists(select 1 from public.internal_employee_identity_links where (employee_id=e.id or user_id=r.auth_user_id) and status='linked')
   and not exists(select 1 from public.organization_memberships where user_id=r.auth_user_id)
   and not exists(select 1 from public.project_memberships where user_id=r.auth_user_id);
  if not coalesce(valid,false) then raise exception 'Invitation no longer eligible' using errcode='42501';end if;
  if p_action='inspect' then
   if r.state<>'ready' then raise exception 'Invitation unavailable' using errcode='42501';end if;
   return jsonb_build_object('name',e.full_name,'email',r.email,'expiresAt',r.expires_at,'purpose',r.purpose);
  elsif p_action='reject' then
   if r.state<>'accepting' or r.acceptance_id is distinct from (p_data->>'acceptanceId')::uuid then raise exception 'Acceptance unavailable' using errcode='42501';end if;
   update public.internal_employee_enrollments set state='ready',acceptance_id=null,version=version+1 where id=r.id;
  elsif p_action='reserve' then
   if r.state<>'ready' then raise exception 'Invitation already in use' using errcode='40001';end if;
   update public.internal_employee_enrollments set state='accepting',acceptance_id=(p_data->>'acceptanceId')::uuid,version=version+1 where id=r.id returning * into r;
  elsif p_action='finish' then
   if r.state<>'accepting' or r.acceptance_id is distinct from (p_data->>'acceptanceId')::uuid then raise exception 'Acceptance unavailable' using errcode='42501';end if;
   insert into public.internal_employee_link_requests(idempotency_key,employee_id,candidate_user_id,issuer_id,email,roster_version,state,accepted_at)
    values(gen_random_uuid(),e.id,r.auth_user_id,r.issuer_id,r.email,e.version,'accepted',now()) returning id into link_id;
   insert into public.internal_employee_identity_links(employee_id,user_id,request_id,status) values(e.id,r.auth_user_id,link_id,'linked')
    on conflict(employee_id) do update set user_id=excluded.user_id,request_id=excluded.request_id,status='linked',version=internal_employee_identity_links.version+1,accepted_at=now(),revoked_at=null;
   update public.internal_employee_enrollments set state='accepted',accepted_at=now(),version=version+1 where id=r.id;
   update public.profiles set status='active' where id=r.auth_user_id;
  end if;
 end if;
 insert into public.audit_logs(actor_user_id,action,target_type,target_id,details) values(p_actor,'employee.enrollment_'||p_action,'internal_employee',e.id::text,jsonb_build_object('enrollmentId',r.id));
 if manager and p_action in ('start','renew') or p_action='reserve' then
  return jsonb_build_object('id',r.id,'authUserId',r.auth_user_id,'email',r.email,'version',r.version,'rosterVersion',r.roster_version);
 end if;
 return jsonb_build_object('saved',true);
end$$;
revoke all on function public.internal_employee_enrollment(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.internal_employee_enrollment(uuid,text,uuid,jsonb) to service_role;

create function public.internal_employee_enrollment_revoke() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_table_name='profiles' then
  if new.status='disabled' or new.email is distinct from old.email then
   update public.internal_employee_enrollments set state='cancelled',account_blocked=true,version=version+1 where auth_user_id=new.id and state in('provisioning','ready','accepting','recovery_required');
  end if;
 elsif new.status='inactive' or new.email is distinct from old.email then
  update public.internal_employee_enrollments set state='cancelled',account_blocked=true,version=version+1 where employee_id=new.id and state in('provisioning','ready','accepting','recovery_required');
 end if;
 return new;
end$$;
revoke all on function public.internal_employee_enrollment_revoke() from public,anon,authenticated;
grant execute on function public.internal_employee_enrollment_revoke() to service_role;
create trigger internal_employee_enrollment_profile_revoke after update of status,email on public.profiles for each row execute function public.internal_employee_enrollment_revoke();
create trigger internal_employee_enrollment_roster_revoke after update of status,email on public.internal_employees for each row execute function public.internal_employee_enrollment_revoke();

-- Ordinary account activation cannot bypass incomplete employee enrollment.
create function public.internal_employee_enrollment_activation_guard() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status='active' and exists(select 1 from public.internal_employee_enrollments where auth_user_id=new.id and state<>'accepted') then
  raise exception 'Complete employee enrollment before enabling this identity' using errcode='42501';
 end if;
 return new;
end$$;
revoke all on function public.internal_employee_enrollment_activation_guard() from public,anon,authenticated;
grant execute on function public.internal_employee_enrollment_activation_guard() to service_role;
create trigger internal_employee_enrollment_activation_guard before update of status on public.profiles for each row execute function public.internal_employee_enrollment_activation_guard();

-- Preserve explicit disable even when the new profile is already disabled.
-- After durable provisioning: explicit account disable also revokes outstanding enrollment.
create or replace function public.set_profile_status(
 p_actor uuid, p_target uuid, p_status text
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
 v_previous text;
 v_role text;
 v_sessions integer := 0;
 v_codes integer := 0;
 v_invites integer := 0;
 v_enrollments integer := 0;
begin
 if p_status is null or p_status not in ('active','disabled') then
  raise exception 'Invalid account status' using errcode = '22023';
 end if;
 -- Recheck the actor in the same transaction as the mutation, not just HTTP middleware.
 perform 1 from public.profiles where id=p_actor and status='active'
  and platform_role='super_admin' for update;
 if not found then raise exception 'Platform administrator required' using errcode='42501'; end if;
 if p_actor=p_target and p_status='disabled' then
  raise exception 'Self-disable is not permitted' using errcode='22023';
 end if;
 select status, platform_role into v_previous, v_role from public.profiles where id=p_target for update;
 if not found then raise exception 'Account not found' using errcode='P0002'; end if;
 if v_role='super_admin' then
  raise exception 'Platform administrator lifecycle requires governed recovery' using errcode='VS001';
 end if;
 if p_status='disabled' then
  update public.internal_employee_enrollments set state='cancelled',account_blocked=true,version=version+1
   where auth_user_id=p_target and state<>'accepted' and not account_blocked;
  get diagnostics v_enrollments = row_count;
  delete from public.portal_sessions where user_id=p_target;
  get diagnostics v_sessions = row_count;
  -- app_sessions cascade through portal_sessions; outstanding Music codes do not have that FK.
  delete from public.sso_launch_codes where user_id=p_target;
  get diagnostics v_codes = row_count;
  update public.membership_invitations set state='revoked',token_hash=null,account_blocked=true
   where user_id=p_target and state<>'accepted' and not account_blocked;
  get diagnostics v_invites = row_count;
  update public.invitation_outbox set state='revoked',encrypted_delivery=null
   where invitation_id in (select id from public.membership_invitations where user_id=p_target and state='revoked');
  update public.provisioning_jobs set state='revoked'
   where id in (select job_id from public.membership_invitations where user_id=p_target and state='revoked');
 end if;
 if v_previous=p_status and v_sessions=0 and v_codes=0 and v_invites=0 and v_enrollments=0 then return p_target; end if;
 update public.profiles set status=p_status where id=p_target;
 insert into public.audit_logs(actor_user_id,action,target_type,target_id,details)
 values(p_actor,'user.status_changed','user',p_target::text,
  jsonb_build_object('before_status',v_previous,'status',p_status,
   'revoked_portal_sessions',v_sessions,'revoked_launch_codes',v_codes,'revoked_invitations',v_invites,'revoked_employee_enrollments',v_enrollments));
 return p_target;
end;
$$;
revoke all on function public.set_profile_status(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.set_profile_status(uuid,uuid,text) to service_role;

-- HR-issued temporary credentials never enable the portal profile. The existing
-- enrollment finish activates it only after employee password replacement/consent.
create table public.internal_employee_temporary_credentials(
 id uuid primary key default gen_random_uuid(),
 enrollment_id uuid not null unique references public.internal_employee_enrollments(id),
 state text not null check(state in('issuing','ready','changing','completed','blocked')),
 version integer not null default 1 check(version>0),
 temporary_hash text not null check(temporary_hash ~ '^[0-9a-f]{64}$'),
 operation_id uuid not null,
 expires_at timestamptz not null default now()+interval '24 hours',
 setup_hash text unique check(setup_hash is null or setup_hash ~ '^[0-9a-f]{64}$'),
 setup_expires_at timestamptz,
 setup_assurance text check(setup_assurance is null or setup_assurance in('aal1','aal2')),
 created_at timestamptz not null default now()
);
alter table public.internal_employee_temporary_credentials enable row level security;
revoke all on public.internal_employee_temporary_credentials from public,anon,authenticated;
grant select,insert,update,delete on public.internal_employee_temporary_credentials to service_role;
create function public.internal_employee_credentials(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 r public.internal_employee_enrollments;t public.internal_employee_temporary_credentials;
 e public.internal_employees;initial_issuer uuid;initial_email text;target uuid;authority text;operation uuid;fresh boolean;prior boolean:=false;
 manager boolean:=p_action in('review','begin','ready');
begin
 if p_action is null or p_action not in('review','begin','ready','login','status','reserve','finish','reject','failed','logout') or jsonb_typeof(p_data) is distinct from 'object'
 or exists(select 1 from jsonb_object_keys(p_data) k where k not in('currentHash','rosterVersion','version','enrollmentId','enrollmentVersion','temporaryHash','setupHash','nonce','verifiedAt','assurance')) then raise exception 'Invalid credentials command' using errcode='22023';end if;
 if p_action in('review','begin') then select * into r from public.internal_employee_enrollments where employee_id=p_id;target:=p_id;
 elsif p_action='login' then select * into r from public.internal_employee_enrollments where auth_user_id=p_actor;target:=r.employee_id;
 else
  if p_action in('ready','failed') then select * into t from public.internal_employee_temporary_credentials where id=p_id;
  else select * into t from public.internal_employee_temporary_credentials where setup_hash=p_data->>'setupHash';end if;
  select * into r from public.internal_employee_enrollments where id=t.enrollment_id;target:=r.employee_id;
 end if;
 initial_issuer:=r.issuer_id;select email into initial_email from public.internal_employees where id=target;
 perform 1 from public.profiles u where u.id in(p_actor,r.issuer_id,r.auth_user_id) or u.email=(select email from public.internal_employees where id=target)
 order by case when u.platform_role='super_admin' then 0 else 1 end,u.id for update;
 if (select issuer_id from public.internal_employee_enrollments where employee_id=target) is distinct from initial_issuer then raise exception 'Issuer changed; refresh before retry' using errcode='40001';end if;
 if manager then
  perform 1 from public.portal_sessions where user_id=p_actor and token_hash=p_data->>'currentHash' and expires_at>clock_timestamp() for update;
  if not found then raise exception 'Current portal session required' using errcode='42501';end if;
 end if;
 perform 1 from public.internal_employees x where x.id=target or x.id in(select employee_id from public.internal_hr_managers where user_id in(p_actor,r.issuer_id)) order by x.id for update;
 perform 1 from public.internal_hr_managers where employee_id=target or user_id in(p_actor,r.issuer_id) order by employee_id for update;
 select * into e from public.internal_employees where id=target;
 if not found and p_action='logout' then return jsonb_build_object('saved',true);end if;
 if not found then raise exception 'Credential setup unavailable' using errcode='42501';end if;
 if e.email is distinct from initial_email then raise exception 'Identity changed; refresh before retry' using errcode='40001';end if;
 select * into r from public.internal_employee_enrollments where employee_id=target for update;
 if r.issuer_id is distinct from initial_issuer then raise exception 'Enrollment appeared or issuer changed; refresh' using errcode='40001';end if;
 select * into t from public.internal_employee_temporary_credentials where enrollment_id=r.id for update;
 if manager then
  authority:=public.internal_workforce_authority(p_actor);
  -- Reuse existing protected-target and current-session governance, after the
  -- stronger profile locks above; never invert profile/roster/grant order.
  perform public.internal_employee_enrollment(p_actor,'review',e.id,jsonb_build_object('currentHash',p_data->>'currentHash'));
  if not exists(select 1 from public.portal_sessions where user_id=p_actor and token_hash=p_data->>'currentHash' and expires_at>clock_timestamp()) then raise exception 'Session expired while waiting' using errcode='42501';end if;
  if p_action='review' then
   return jsonb_build_object('credential',case when t.id is null then null else jsonb_build_object('id',t.id,'version',t.version,'state',case when r.state not in('accepting','accepted') or r.account_blocked then 'revoked' when t.state='ready' and t.expires_at<=clock_timestamp() then 'expired' else t.state end,'expiresAt',t.expires_at,'canReissue',t.state='ready' and r.state in('accepting','cancelled') and not r.account_blocked and (authority='owner' or r.issuer_id=p_actor)) end);
  end if;
  if e.version is distinct from (p_data->>'rosterVersion')::integer or (authority<>'owner' and r.issuer_id<>p_actor) then raise exception 'Review current credential authority and roster' using errcode='40001';end if;
 end if;
 if p_action='failed' then
  if t.state in('issuing','changing') and t.operation_id=(p_data->>'nonce')::uuid then
   update public.internal_employee_temporary_credentials set state='blocked',version=version+1,setup_hash=null,setup_expires_at=null where id=t.id;
   perform public.internal_employee_enrollment(null,'failed',r.id,jsonb_build_object('tokenHash',r.token_hash,'acceptanceId',r.acceptance_id));
   insert into public.audit_logs(action,target_type,target_id,details) values('employee.temporary_credentials_failed','internal_employee',e.id::text,jsonb_build_object('credentialId',t.id));
  end if;
  return jsonb_build_object('blocked',true);
 end if;
 if p_action='begin' then
  if coalesce(p_data->>'temporaryHash','')!~'^[0-9a-f]{64}$' or r.id is null or r.account_blocked or e.email<>r.email or e.status not in('onboarding','active')
   or not exists(select 1 from public.profiles where id=r.auth_user_id and email=r.email and status='disabled' and platform_role='user') then raise exception 'New employee credentials unavailable' using errcode='42501';end if;
  operation:=gen_random_uuid();
  if t.id is null then
   if r.id is distinct from (p_data->>'enrollmentId')::uuid or r.version is distinct from (p_data->>'enrollmentVersion')::integer then raise exception 'Enrollment changed' using errcode='40001';end if;
   perform public.internal_employee_enrollment(null,'reserve',r.id,jsonb_build_object('tokenHash',r.token_hash,'acceptanceId',operation));
   insert into public.internal_employee_temporary_credentials(enrollment_id,state,temporary_hash,operation_id) values(r.id,'issuing',p_data->>'temporaryHash',operation) returning * into t;
  else
   if t.version is distinct from (p_data->>'version')::integer then raise exception 'Credentials changed' using errcode='40001';end if;
   if t.state<>'ready' or r.state not in('accepting','cancelled') then raise exception 'Credential operation requires recovery' using errcode='42501';end if;
   prior:=true;
   update public.internal_employee_enrollments set state='accepting',issuer_id=p_actor,roster_version=e.version,expires_at=clock_timestamp()+interval '7 days',acceptance_id=operation,version=version+1 where id=r.id;
   update public.internal_employee_temporary_credentials set state='issuing',temporary_hash=p_data->>'temporaryHash',operation_id=operation,version=version+1,expires_at=clock_timestamp()+interval '24 hours',setup_hash=null,setup_expires_at=null where id=t.id returning * into t;
  end if;
 else
  if r.id is null or t.id is null or r.state<>'accepting' or r.account_blocked or r.expires_at<=clock_timestamp() or r.email<>e.email or r.roster_version<>e.version or e.status not in('onboarding','active')
   or public.internal_workforce_authority(r.issuer_id) is null
   or (public.internal_workforce_authority(r.issuer_id)<>'owner' and exists(select 1 from public.internal_hr_managers where employee_id=e.id))
   or not exists(select 1 from public.profiles where id=r.auth_user_id and email=r.email and status='disabled' and platform_role='user') then raise exception 'Temporary access unavailable' using errcode='42501';end if;
  if p_action='ready' then
   if t.state<>'issuing' or t.operation_id is distinct from (p_data->>'nonce')::uuid then raise exception 'Credential operation changed' using errcode='40001';end if;
   update public.internal_employee_temporary_credentials set state='ready',version=version+1 where id=t.id;
  elsif p_action='login' then
   fresh:=p_data->>'assurance' in('aal1','aal2') and (p_data->>'verifiedAt')::timestamptz>=clock_timestamp()-interval '30 seconds' and (p_data->>'verifiedAt')::timestamptz<=clock_timestamp()+interval '5 seconds';
   if not coalesce(fresh,false) or r.auth_user_id is distinct from p_actor or t.state<>'ready' or t.expires_at<=clock_timestamp() or t.temporary_hash is distinct from p_data->>'temporaryHash' or coalesce(p_data->>'setupHash','')!~'^[0-9a-f]{64}$' then raise exception 'Temporary login unavailable' using errcode='42501';end if;
   update public.internal_employee_temporary_credentials set setup_hash=p_data->>'setupHash',setup_expires_at=clock_timestamp()+interval '10 minutes',setup_assurance=p_data->>'assurance' where id=t.id;
  else
   if p_actor is not null or t.setup_hash is distinct from p_data->>'setupHash' or t.setup_hash is null or t.setup_expires_at<=clock_timestamp() or t.expires_at<=clock_timestamp() then raise exception 'Password setup session expired' using errcode='42501';end if;
   if p_action='logout' then
    if t.state='changing' then
     update public.internal_employee_temporary_credentials set state='blocked' where id=t.id;
     perform public.internal_employee_enrollment(null,'failed',r.id,jsonb_build_object('tokenHash',r.token_hash,'acceptanceId',r.acceptance_id));
    end if;
    update public.internal_employee_temporary_credentials set setup_hash=null,setup_expires_at=null,setup_assurance=null where id=t.id;
   elsif p_action='status' then
    if t.state<>'ready' then raise exception 'Password setup unavailable' using errcode='42501';end if;
    return jsonb_build_object('email',r.email,'name',e.full_name,'expiresAt',t.setup_expires_at);
   elsif p_action='reserve' then
    if t.state<>'ready' then raise exception 'Password change already in progress' using errcode='40001';end if;
    if coalesce(p_data->>'temporaryHash','')!~'^[0-9a-f]{64}$' or t.temporary_hash=p_data->>'temporaryHash' then raise exception 'Choose a different personal password' using errcode='22023';end if;
    operation:=(p_data->>'nonce')::uuid;
    if operation is null then raise exception 'Password operation required' using errcode='22023';end if;
    update public.internal_employee_temporary_credentials set state='changing',operation_id=operation,version=version+1 where id=t.id returning * into t;
   elsif p_action in('finish','reject') then
    if t.state<>'changing' or t.operation_id is distinct from (p_data->>'nonce')::uuid then raise exception 'Password change unavailable' using errcode='42501';end if;
    if p_action='reject' then update public.internal_employee_temporary_credentials set state='ready',version=version+1 where id=t.id;
    else
     perform public.internal_employee_enrollment(null,'finish',r.id,jsonb_build_object('tokenHash',r.token_hash,'acceptanceId',r.acceptance_id));
     update public.internal_employee_temporary_credentials set state='completed',setup_hash=null,setup_expires_at=null,version=version+1 where id=t.id;
    end if;
   end if;
  end if;
 end if;
 insert into public.audit_logs(actor_user_id,action,target_type,target_id,details) values(case when manager then p_actor else null end,'employee.temporary_credentials_'||p_action,'internal_employee',e.id::text,jsonb_build_object('credentialId',t.id));
 if p_action in('begin','reserve') then return jsonb_build_object('id',t.id,'userId',r.auth_user_id,'enrollmentId',r.id,'email',r.email,'nonce',t.operation_id,'assurance',t.setup_assurance,'reissue',prior,'expiresAt',t.expires_at);end if;
 return jsonb_build_object('saved',true);
end$$;
revoke all on function public.internal_employee_credentials(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.internal_employee_credentials(uuid,text,uuid,jsonb) to service_role;

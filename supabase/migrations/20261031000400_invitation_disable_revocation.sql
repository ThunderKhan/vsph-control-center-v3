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
  delete from public.portal_sessions where user_id=p_target;
  get diagnostics v_sessions = row_count;
  -- app_sessions cascade through portal_sessions; outstanding Music codes do not have that FK.
  delete from public.sso_launch_codes where user_id=p_target;
  get diagnostics v_codes = row_count;
  update public.membership_invitations set state='revoked',token_hash=null
   where user_id=p_target and state not in ('accepted','revoked');
  get diagnostics v_invites = row_count;
  update public.invitation_outbox set state='revoked',encrypted_delivery=null
   where invitation_id in (select id from public.membership_invitations where user_id=p_target and state='revoked');
  update public.provisioning_jobs set state='revoked'
   where id in (select job_id from public.membership_invitations where user_id=p_target and state='revoked');
 end if;
 if v_previous=p_status and v_sessions=0 and v_codes=0 and v_invites=0 then return p_target; end if;
 update public.profiles set status=p_status where id=p_target;
 insert into public.audit_logs(actor_user_id,action,target_type,target_id,details)
 values(p_actor,'user.status_changed','user',p_target::text,
  jsonb_build_object('before_status',v_previous,'status',p_status,
   'revoked_portal_sessions',v_sessions,'revoked_launch_codes',v_codes,'revoked_invitations',v_invites));
 return p_target;
end;
$$;
revoke all on function public.set_profile_status(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.set_profile_status(uuid,uuid,text) to service_role;

-- Reject absent proofs at the DB boundary, including trusted-server caller mistakes.
create or replace function public.provisioning_command(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.provisioning_jobs; i public.membership_invitations; o public.invitation_outbox;
 v_org uuid; v_user uuid; item jsonb; v_new boolean; v_count integer;
begin
 if p_action in ('begin','list','retry','revoke','recover') then
  perform 1 from public.profiles where id=p_actor and platform_role='super_admin' and status='active' for update;
  if not found then raise exception 'Not permitted' using errcode='42501';end if;
 end if;
 if p_action='begin' then
  -- Serialize identical keys BEFORE any tenant creation, including concurrent first requests.
  perform pg_advisory_xact_lock(hashtextextended(p_actor::text||p_id::text,0));
  select * into j from public.provisioning_jobs where actor_id=p_actor and idempotency_key=p_id;
  if found then
   if j.request<>p_data then raise exception 'Idempotency key payload mismatch' using errcode='23505';end if;
   return to_jsonb(j);
  end if;
  if p_id is null or length(p_data->>'organizationName') not between 1 and 150 or
   (p_data->>'slug')!~'^[a-z0-9]+(-[a-z0-9]+)*$' or length(p_data->>'slug')>160 or
   length(p_data->>'adminName') not between 1 and 150 or
   coalesce(p_data->>'adminEmail','')!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' or
   jsonb_typeof(p_data->'products')<>'array' or jsonb_array_length(p_data->'products') not between 1 and 12 then
   raise exception 'Invalid onboarding' using errcode='22023';end if;
  select count(distinct x->>'applicationId') into v_count from jsonb_array_elements(p_data->'products') x;
  if v_count<>jsonb_array_length(p_data->'products') then raise exception 'Duplicate products' using errcode='22023';end if;
  insert into public.organizations(name,slug) values(p_data->>'organizationName',p_data->>'slug') returning id into v_org;
  for item in select * from jsonb_array_elements(p_data->'products') loop
   perform 1 from public.applications where id=(item->>'applicationId')::uuid and status='active';
   if not found or coalesce(item->>'status','') not in ('trial','active') or
    coalesce(item->>'planCode','')!~'^[a-z0-9][a-z0-9_-]{0,59}$' or
    ((item->>'endsAt') is not null and (item->>'endsAt')::timestamptz<=now()) or
    (item->>'status'='trial' and item->>'endsAt' is null) then raise exception 'Invalid product plan' using errcode='22023';end if;
   insert into public.subscriptions(organization_id,application_id,plan_code,status,ends_at)
    values(v_org,(item->>'applicationId')::uuid,item->>'planCode',item->>'status',(item->>'endsAt')::timestamptz);
   insert into public.organization_app_access(organization_id,application_id) values(v_org,(item->>'applicationId')::uuid);
  end loop;
  insert into public.provisioning_jobs(actor_id,idempotency_key,request,organization_id) values(p_actor,p_id,p_data,v_org) returning * into j;
  insert into public.membership_invitations(job_id,organization_id,email) values(j.id,v_org,p_data->>'adminEmail') returning * into i;
  insert into public.invitation_outbox(invitation_id) values(i.id);
  insert into public.audit_logs(actor_user_id,organization_id,action,target_type,target_id) values(p_actor,v_org,'onboarding.queued','provisioning_job',j.id::text);
  return to_jsonb(j);
 elsif p_action='list' then
  return coalesce((select jsonb_agg(x) from (select job.id,job.organization_id,job.state,job.created_at,inv.id invitation_id,inv.email,inv.state invitation_state,inv.expires_at,ob.attempts,ob.failure_code
   from public.provisioning_jobs job join public.membership_invitations inv on inv.job_id=job.id join public.invitation_outbox ob on ob.invitation_id=inv.id
   order by job.created_at desc limit 100) x),'[]');
 elsif p_action='claim' then
  select * into o from public.invitation_outbox where (state='queued' and available_at<=now()) or (state='leased' and lease_until<now())
   order by available_at for update skip locked limit 1;
  if not found then return null;end if;
  if o.attempts>=5 then
   update public.invitation_outbox set state='requires_attention',failure_code='attempt_limit' where id=o.id;
   update public.provisioning_jobs set state='requires_attention' where id=(select job_id from public.membership_invitations where id=o.invitation_id);return null;end if;
  update public.invitation_outbox set state='leased',attempts=attempts+1,lease_token=p_id,lease_until=now()+interval '2 minutes' where id=o.id returning * into o;
  select * into i from public.membership_invitations where id=o.invitation_id;
  select * into j from public.provisioning_jobs where id=i.job_id;
  update public.provisioning_jobs set state='processing' where id=j.id;
  return jsonb_build_object('outbox',to_jsonb(o),'invitation',to_jsonb(i),'job',to_jsonb(j));
 elsif p_action in ('bind','sent','failed') then
  -- Global mutation lock order: target profile -> invitation -> outbox -> job.
  -- Claim leases are short transactions and do not lock profiles/invitations.
  select inv.* into i from public.membership_invitations inv join public.invitation_outbox ob on ob.invitation_id=inv.id where ob.id=p_id;
  perform 1 from public.profiles where id=coalesce(i.user_id,nullif(p_data->>'userId','')::uuid) for update;
  perform 1 from public.membership_invitations where id=i.id for update;
  select * into o from public.invitation_outbox where id=p_id for update;
  if not found or o.state<>'leased' or o.lease_token<>(p_data->>'lease')::uuid or o.lease_until<=now() then raise exception 'Lease lost' using errcode='40001';end if;
  select * into i from public.membership_invitations where id=o.invitation_id for update;
  if i.state='revoked' then raise exception 'Revoked' using errcode='42501';end if;
  select * into j from public.provisioning_jobs where id=i.job_id;
  if p_action='bind' then
   v_user:=(p_data->>'userId')::uuid;
   select case when i.user_id is not null then i.new_identity else not exists(select 1 from public.profiles where id=v_user) end into v_new;
   if exists(select 1 from public.profiles where email=i.email and id<>v_user) then raise exception 'Identity mismatch' using errcode='42501';end if;
   insert into public.profiles(id,full_name,email,status,platform_role) values(v_user,j.request->>'adminName',i.email,'disabled','user') on conflict(id) do nothing;
   if not exists(select 1 from public.profiles where id=v_user and email=i.email) then raise exception 'Identity mismatch' using errcode='42501';end if;
   insert into public.organization_memberships(organization_id,user_id,role,status) values(i.organization_id,v_user,'owner','invited') on conflict(organization_id,user_id) do nothing;
   for item in select * from jsonb_array_elements(j.request->'products') loop
    insert into public.user_app_roles(organization_id,user_id,application_id,role_code) values(i.organization_id,v_user,(item->>'applicationId')::uuid,'admin') on conflict do nothing;end loop;
   update public.membership_invitations set user_id=v_user,new_identity=v_new,token_hash=p_data->>'tokenHash' where id=i.id;
   update public.invitation_outbox set encrypted_delivery=p_data->>'encryptedDelivery' where id=o.id;
  elsif p_action='sent' then
   update public.invitation_outbox set state='sent',encrypted_delivery=null,delivered_at=now() where id=o.id;
   update public.membership_invitations set state='sent' where id=i.id;
   update public.provisioning_jobs set state='awaiting_acceptance' where id=j.id;
  else
   update public.invitation_outbox set state=case when attempts>=5 then 'requires_attention' else 'queued' end,
    failure_code='delivery_failed',available_at=now()+interval '1 minute',lease_token=null where id=o.id;
   update public.provisioning_jobs set state='requires_attention' where id=j.id;
  end if;return jsonb_build_object('ok',true);
 end if;
 perform 1 from public.profiles where id=(select user_id from public.membership_invitations where id=p_id) for update;
 select * into i from public.membership_invitations where id=p_id for update;
 if not found then raise exception 'Invitation unavailable' using errcode='42501';end if;
 if p_action in ('retry','revoke','recover') then
  if p_action='recover' then
   if coalesce((p_data->>'reconciled')::boolean,false) is not true or i.state not in ('requires_attention','accepting') or (i.lease_until is not null and i.lease_until>now()) then raise exception 'Reconciliation required' using errcode='40001';end if;
   update public.membership_invitations set state='pending_delivery',token_hash=null,generation=generation+1,expires_at=now()+interval '24 hours',acceptance_id=null where id=i.id;
   update public.invitation_outbox set state='queued',encrypted_delivery=null,attempts=0,available_at=now() where invitation_id=i.id;
   update public.provisioning_jobs set state='queued' where id=i.job_id;
   insert into public.audit_logs(actor_user_id,organization_id,action,target_type,target_id) values(p_actor,i.organization_id,'invitation.reconciled','invitation',i.id::text);
   return jsonb_build_object('ok',true);
  end if;
  if i.state in ('accepted','accepting') then raise exception 'Invitation cannot be changed in this state; reconcile first' using errcode='40001';end if;
  if p_action='revoke' then
   update public.membership_invitations set state='revoked',token_hash=null where id=i.id;
   update public.invitation_outbox set state='revoked',encrypted_delivery=null where invitation_id=i.id;
   update public.provisioning_jobs set state='revoked' where id=i.job_id;
  else
   -- Delivery retries reuse the encrypted capability, never create another tenant/user.
   if i.state<>'pending_delivery' or i.expires_at<=now() then raise exception 'Revoked/expired invitations require a new reviewed invitation' using errcode='42501';end if;
   update public.invitation_outbox set state='queued',attempts=0,available_at=now(),failure_code=null where invitation_id=i.id;
   update public.provisioning_jobs set state='queued' where id=i.job_id;
  end if;
  insert into public.audit_logs(actor_user_id,organization_id,action,target_type,target_id) values(p_actor,i.organization_id,'invitation.'||p_action,'invitation',i.id::text);
  return jsonb_build_object('ok',true);
 elsif p_action='inspect' then
  if i.state<>'sent' or i.expires_at<=now() or i.token_hash is distinct from p_data->>'tokenHash' then raise exception 'Invitation unavailable' using errcode='42501';end if;
  return jsonb_build_object('newIdentity',i.new_identity);
 elsif p_action='reserve_accept' then
  if p_data->>'acceptanceId' is null or i.state<>'sent' or i.expires_at<=now() or i.token_hash is null or i.token_hash is distinct from p_data->>'tokenHash' then raise exception 'Invitation expired, revoked or already used' using errcode='42501';end if;
  if not i.new_identity and i.user_id is distinct from p_actor then raise exception 'Sign in as the invited account' using errcode='42501';end if;
  perform 1 from public.organizations where id=i.organization_id and status='active';
  if not found or not exists(select 1 from public.organization_memberships where organization_id=i.organization_id and user_id=i.user_id and status='invited') then raise exception 'Membership unavailable' using errcode='42501';end if;
  if not i.new_identity and not exists(select 1 from public.profiles where id=p_actor and status='active') then raise exception 'Account disabled' using errcode='42501';end if;
  update public.membership_invitations set state='accepting',acceptance_id=(p_data->>'acceptanceId')::uuid,lease_until=now()+interval '2 minutes' where id=i.id;
  return jsonb_build_object('userId',i.user_id,'newIdentity',i.new_identity);
 elsif p_action='finish_accept' then
  if i.state<>'accepting' or i.acceptance_id is distinct from (p_data->>'acceptanceId')::uuid or i.lease_until<=now() or i.expires_at<=now() then raise exception 'Acceptance unavailable; administrator reconciliation required' using errcode='40001';end if;
  if i.new_identity then update public.profiles set status='active' where id=i.user_id and status='disabled' and platform_role='user';end if;
  update public.organization_memberships set status='active' where organization_id=i.organization_id and user_id=i.user_id and status='invited';
  if not found then raise exception 'Membership unavailable' using errcode='42501';end if;
  update public.membership_invitations set state='accepted',token_hash=null,accepted_at=now() where id=i.id;
  update public.provisioning_jobs set state='ready' where id=i.job_id;
  insert into public.audit_logs(actor_user_id,organization_id,action,target_type,target_id) values(i.user_id,i.organization_id,'invitation.accepted','invitation',i.id::text);
  return jsonb_build_object('ok',true);
 elsif p_action='accept_failed' then
  if i.state='accepting' and i.acceptance_id=(p_data->>'acceptanceId')::uuid then
   update public.membership_invitations set state='requires_attention',token_hash=null where id=i.id;
   update public.provisioning_jobs set state='requires_attention' where id=i.job_id;end if;
  return jsonb_build_object('ok',true);
 end if;
 raise exception 'Invalid command' using errcode='22023';
end$$;
revoke all on function public.provisioning_command(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.provisioning_command(uuid,text,uuid,jsonb) to service_role;

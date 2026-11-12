-- Additive migration. Service-only state machine; no hosted execution by this change.
create table public.provisioning_jobs (
 id uuid primary key default gen_random_uuid(), actor_id uuid not null references public.profiles(id),
 idempotency_key uuid not null, request jsonb not null, organization_id uuid not null references public.organizations(id),
 state text not null default 'queued' check(state in ('queued','processing','awaiting_acceptance','ready','requires_attention','revoked')),
 created_at timestamptz not null default now(), unique(actor_id,idempotency_key)
);
create table public.membership_invitations (
 id uuid primary key default gen_random_uuid(), job_id uuid not null unique references public.provisioning_jobs(id),
 organization_id uuid not null references public.organizations(id), email text not null,
 auth_user_id uuid not null default gen_random_uuid(), user_id uuid references public.profiles(id), new_identity boolean not null default false,
 token_hash text check(length(token_hash)=64), generation integer not null default 1,
 state text not null default 'pending_delivery' check(state in ('pending_delivery','sent','accepting','accepted','requires_attention','revoked')),
 expires_at timestamptz not null default now()+interval '24 hours', acceptance_id uuid,
 lease_until timestamptz, accepted_at timestamptz
);
create table public.invitation_outbox (
 id uuid primary key default gen_random_uuid(), invitation_id uuid not null unique references public.membership_invitations(id),
 state text not null default 'queued' check(state in ('queued','leased','sent','requires_attention','revoked')),
 attempts integer not null default 0, available_at timestamptz not null default now(), lease_token uuid, lease_until timestamptz,
 encrypted_delivery text, failure_code text, delivered_at timestamptz
);
create index on public.invitation_outbox(state,available_at);
do $$declare t text;begin foreach t in array array['provisioning_jobs','membership_invitations','invitation_outbox'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('revoke all on public.%I from public,anon,authenticated',t);end loop;end$$;

create function public.provisioning_command(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}')
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
  if i.state<>'sent' or i.expires_at<=now() or i.token_hash is null or i.token_hash<>p_data->>'tokenHash' then raise exception 'Invitation expired, revoked or already used' using errcode='42501';end if;
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

-- Reuse the durable member invitation saga, without platform impersonation.
create function public.delegated_invitation_authority(p_actor uuid,p_org uuid,p_request jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare actor_role text; item jsonb;
begin
 perform 1 from public.profiles where id=p_actor and status='active' for update;
 if not found then raise exception 'Inviter unavailable' using errcode='42501';end if;
 select m.role into actor_role from public.organization_memberships m join public.organizations o on o.id=m.organization_id
  where m.organization_id=p_org and m.user_id=p_actor and m.status='active' and m.role in ('owner','admin') and o.status='active';
 if not found or p_request->>'kind' is distinct from 'member' or p_request->'delegated' is distinct from 'true'::jsonb or p_request->>'organizationId' is distinct from p_org::text or coalesce(p_request->>'memberRole','') not in ('admin','member','viewer') or (actor_role<>'owner' and p_request->>'memberRole'='admin') then raise exception 'Delegated invitation unavailable' using errcode='42501';end if;
 for item in select * from jsonb_array_elements(p_request->'products') loop
  perform 1 from public.applications a join public.organization_app_access g on g.application_id=a.id join public.subscriptions s on s.organization_id=g.organization_id and s.application_id=a.id join public.app_roles r on r.application_id=a.id and r.code=item->>'role' join public.user_app_roles mine on mine.organization_id=g.organization_id and mine.application_id=a.id and mine.user_id=p_actor and mine.role_code in ('admin','super_admin')
   where g.organization_id=p_org and a.id=(item->>'applicationId')::uuid and a.status='active' and g.status='enabled' and s.status in ('active','trial') and s.starts_at<=now() and (s.ends_at is null or s.ends_at>now()) and r.code<>'super_admin' and (r.code not in ('staff','musician') or a.code='MUSIC');
  if not found then raise exception 'Current product administrator entitlement required' using errcode='42501';end if;
 end loop;
end$$;
revoke all on function public.delegated_invitation_authority(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.delegated_invitation_authority(uuid,uuid,jsonb) to service_role;

create function public.organization_invitation(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare request jsonb; item jsonb; key_id uuid; target_id uuid; job public.provisioning_jobs; inv public.membership_invitations; actor_role text;
begin
 if jsonb_typeof(p_data) is distinct from 'object' then raise exception 'Invalid fields' using errcode='22023';end if;
 -- Order actor/recipient profiles globally, including cross-organization invites.
 if p_action='queue' then
  perform 1 from public.profiles where id=p_actor or (email=p_data->'request'->>'adminEmail' and platform_role='user') order by (platform_role='super_admin') desc,id for update;
 else
  select user_id into target_id from public.membership_invitations where id=(p_data->>'invitationId')::uuid;
  perform 1 from public.profiles where id=p_actor or (id=target_id and platform_role='user') order by (platform_role='super_admin') desc,id for update;
 end if;
 perform 1 from public.profiles where id=p_actor and status='active';
 if not found then raise exception 'Active identity required' using errcode='42501';end if;
 if p_action='queue' then
  if exists(select 1 from jsonb_object_keys(p_data) k where k not in ('key','request')) then raise exception 'Invalid fields' using errcode='22023';end if;
  request:=p_data->'request';key_id:=(p_data->>'key')::uuid;
  if key_id is null or jsonb_typeof(request) is distinct from 'object' or exists(select 1 from jsonb_object_keys(request) k where k not in ('kind','organizationId','adminName','adminEmail','memberRole','products','delegated')) or jsonb_typeof(request->'products') is distinct from 'array' or jsonb_array_length(request->'products')>12 or jsonb_typeof(request->'adminName') is distinct from 'string' or length(btrim(request->>'adminName')) not between 1 and 150 or (request->>'adminName')~'[[:cntrl:]]' or coalesce(request->>'adminEmail','')!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' or length(request->>'adminEmail')>190 or request->>'adminEmail'<>lower(request->>'adminEmail') then raise exception 'Invalid invitation' using errcode='22023';end if;
  if (select count(distinct x->>'applicationId') from jsonb_array_elements(request->'products') x)<>jsonb_array_length(request->'products') then raise exception 'Duplicate product' using errcode='22023';end if;
  for item in select * from jsonb_array_elements(request->'products') loop
   if jsonb_typeof(item) is distinct from 'object' or exists(select 1 from jsonb_object_keys(item) k where k not in ('applicationId','role')) then raise exception 'Invalid product fields' using errcode='22023';end if;
  end loop;
  perform public.delegated_invitation_authority(p_actor,p_id,request);
  perform pg_advisory_xact_lock(hashtextextended(p_actor::text||key_id::text,0));
  select * into job from public.provisioning_jobs where actor_id=p_actor and idempotency_key=key_id;
  if found then
   if job.request<>request or job.organization_id<>p_id then raise exception 'Idempotency mismatch' using errcode='23505';end if;
   return jsonb_build_object('id',job.id,'state',job.state);
  end if;
  select id into target_id from public.profiles where email=request->>'adminEmail' for update;
  if found and (not exists(select 1 from public.profiles where id=target_id and status='active' and platform_role='user') or exists(select 1 from public.organization_memberships where organization_id=p_id and user_id=target_id)) then raise exception 'Identity or membership requires platform review' using errcode='23505';end if;
 else
  if p_action not in ('list','cancel','reissue') then raise exception 'Invalid command' using errcode='22023';end if;
  if p_action='list' and p_data<>'{}'::jsonb then raise exception 'Invalid fields' using errcode='22023';end if;
  if p_action<>'list' then
   if exists(select 1 from jsonb_object_keys(p_data) k where k not in ('invitationId','generation','confirmed')) or p_data->'confirmed' is distinct from 'true'::jsonb then raise exception 'Explicit confirmation required' using errcode='22023';end if;
   -- Only invitations issued by this customer administrator are delegated here.
   select i.* into inv from public.membership_invitations i join public.provisioning_jobs j on j.id=i.job_id where i.id=(p_data->>'invitationId')::uuid and i.organization_id=p_id and j.actor_id=p_actor and j.request->'delegated'='true'::jsonb;
   if not found then raise exception 'Invitation unavailable' using errcode='42501';end if;
   perform 1 from public.profiles where id=inv.user_id for update;
  end if;
 end if;
 perform 1 from public.organizations where id=p_id and status='active' for no key update;
 if not found then raise exception 'Organization unavailable' using errcode='42501';end if;
 select role into actor_role from public.organization_memberships where organization_id=p_id and user_id=p_actor and status='active' and role in ('owner','admin') for update;
 if not found then raise exception 'Organization administrator required' using errcode='42501';end if;
 if p_action='list' then
  return coalesce((select jsonb_agg(x) from(select i.id,i.email,i.state,i.generation,i.expires_at,(i.expires_at<=now() and i.state not in ('accepted','revoked')) expired,o.state delivery_state,o.failure_code,o.attempts
   from public.membership_invitations i join public.provisioning_jobs j on j.id=i.job_id join public.invitation_outbox o on o.invitation_id=i.id where i.organization_id=p_id and j.actor_id=p_actor and j.request->'delegated'='true'::jsonb order by i.expires_at desc,i.id limit 100)x),'[]');
 elsif p_action='queue' then
  -- Recheck after the org lock so committed membership/lifecycle changes win.
  perform public.delegated_invitation_authority(p_actor,p_id,request);
  insert into public.provisioning_jobs(actor_id,idempotency_key,request,organization_id) values(p_actor,key_id,request,p_id) returning * into job;
  insert into public.membership_invitations(job_id,organization_id,email) values(job.id,p_id,request->>'adminEmail') returning * into inv;
  insert into public.invitation_outbox(invitation_id) values(inv.id);
  insert into public.audit_logs(actor_user_id,organization_id,action,target_type,target_id) values(p_actor,p_id,'organization.invitation_queued','invitation',inv.id::text);
  return jsonb_build_object('id',job.id,'state',job.state);
 end if;
 select * into inv from public.membership_invitations where id=inv.id for update;
 select * into job from public.provisioning_jobs where id=inv.job_id;
 if (p_data->>'generation')::integer is distinct from inv.generation then raise exception 'Stale invitation' using errcode='40001';end if;
 if inv.state in ('accepted','accepting','requires_attention') then raise exception 'Platform reconciliation required' using errcode='40001';end if;
 if p_action='reissue' then
  perform public.delegated_invitation_authority(p_actor,p_id,job.request);
  if inv.account_blocked or (inv.user_id is not null and exists(select 1 from public.profiles where id=inv.user_id and status='disabled') and not inv.new_identity) then raise exception 'Account requires platform review' using errcode='42501';end if;
  if inv.user_id is not null and exists(select 1 from public.organization_memberships where organization_id=p_id and user_id=inv.user_id and status<>'invited') then raise exception 'Membership changed' using errcode='40001';end if;
  update public.membership_invitations set state='pending_delivery',generation=generation+1,token_hash=null,expires_at=now()+interval '24 hours',acceptance_id=null,lease_until=null where id=inv.id;
  update public.invitation_outbox set state='queued',encrypted_delivery=null,attempts=0,lease_token=null,lease_until=null,available_at=now(),failure_code=null where invitation_id=inv.id;
  update public.provisioning_jobs set state='queued' where id=job.id;
 else
  update public.membership_invitations set state='revoked',token_hash=null where id=inv.id;
  update public.invitation_outbox set state='revoked',encrypted_delivery=null,lease_token=null,lease_until=null where invitation_id=inv.id;
  update public.provisioning_jobs set state='revoked' where id=job.id;
 end if;
 insert into public.audit_logs(actor_user_id,organization_id,action,target_type,target_id,details) values(p_actor,p_id,'organization.invitation_'||p_action,'invitation',inv.id::text,jsonb_build_object('generation',inv.generation));
 return '{"ok":true}';
end$$;
revoke all on function public.organization_invitation(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.organization_invitation(uuid,text,uuid,jsonb) to service_role;

-- Keep the original acceptance/worker implementation and its security checks.
-- Delegated jobs additionally recheck their issuer before binding, delivering
-- confirmation, inspection and BOTH acceptance phases. Revocation cannot be
-- bypassed by an already queued/sent link. Failure bookkeeping remains possible.
alter function public.provisioning_command(uuid,text,uuid,jsonb) rename to provisioning_core_command;
create function public.provisioning_command(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare j public.provisioning_jobs; target_id uuid;
begin
 if p_action in ('bind','sent') then
  select job.* into j from public.provisioning_jobs job join public.membership_invitations i on i.job_id=job.id join public.invitation_outbox o on o.invitation_id=i.id where o.id=p_id;
 elsif p_action in ('inspect','reserve_accept','finish_accept') then
  select job.* into j from public.provisioning_jobs job join public.membership_invitations i on i.job_id=job.id where i.id=p_id;
 end if;
 if j.request->'delegated'='true'::jsonb then
  if p_action='bind' then target_id:=(p_data->>'userId')::uuid;
  elsif p_action='sent' then select i.user_id into target_id from public.membership_invitations i join public.invitation_outbox o on o.invitation_id=i.id where o.id=p_id;
  else select user_id into target_id from public.membership_invitations where id=p_id;end if;
  perform 1 from public.profiles where id=j.actor_id or (id=target_id and platform_role='user') order by (platform_role='super_admin') desc,id for update;
  perform public.delegated_invitation_authority(j.actor_id,j.organization_id,j.request);
 end if;
 return public.provisioning_core_command(p_actor,p_action,p_id,p_data);
end$$;
revoke all on function public.provisioning_command(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.provisioning_command(uuid,text,uuid,jsonb) to service_role;

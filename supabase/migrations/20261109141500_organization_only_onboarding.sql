-- Owner-created customer organization with no reusable product subscription.
-- Uses the same durable invitation/outbox lifecycle as standard onboarding.
-- No customer or employee data is modified; the worker handles invitations later.
create function public.organization_only_onboarding(p_actor uuid,p_request_id uuid,p_data jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 j public.provisioning_jobs;
 invitation public.membership_invitations;
 org_id uuid;
begin
 perform 1 from public.profiles where id=p_actor and status='active'
  and platform_role='super_admin' for update;
 if not found then raise exception 'Platform owner required' using errcode='42501';end if;
 if p_request_id is null or jsonb_typeof(p_data) is distinct from 'object' or
    (select count(*) from jsonb_object_keys(p_data))<>5 or
    not (p_data ?& array['organizationName','slug','adminName','adminEmail','products']) or
    length(btrim(coalesce(p_data->>'organizationName',''))) not between 1 and 150 or
    (p_data->>'slug') !~ '^[a-z0-9]+(-[a-z0-9]+)*$' or
    length(p_data->>'slug')>160 or
    length(btrim(coalesce(p_data->>'adminName',''))) not between 1 and 150 or
    (p_data->>'adminEmail') !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' or
    length(p_data->>'adminEmail')>190 or
    jsonb_typeof(p_data->'products') is distinct from 'array' or
    jsonb_array_length(p_data->'products')<>0 then
  raise exception 'Invalid client organization setup' using errcode='22023';
 end if;
 perform pg_advisory_xact_lock(hashtextextended(p_actor::text||p_request_id::text,0));
 select * into j from public.provisioning_jobs
  where actor_id=p_actor and idempotency_key=p_request_id;
 if found then
  if j.request<>p_data then
   raise exception 'Idempotency key payload mismatch' using errcode='23505';
  end if;
  return to_jsonb(j);
 end if;
 insert into public.organizations(name,slug)
 values(btrim(p_data->>'organizationName'),p_data->>'slug') returning id into org_id;
 insert into public.provisioning_jobs(actor_id,idempotency_key,request,organization_id)
 values(p_actor,p_request_id,p_data,org_id) returning * into j;
 insert into public.membership_invitations(job_id,organization_id,email)
 values(j.id,org_id,lower(p_data->>'adminEmail')) returning * into invitation;
 insert into public.invitation_outbox(invitation_id) values(invitation.id);
 insert into public.audit_logs(actor_user_id,organization_id,action,target_type,target_id,details)
 values(p_actor,org_id,'onboarding.queued','provisioning_job',j.id::text,
  jsonb_build_object('purpose','custom_development','products',0));
 return to_jsonb(j);
end $$;
revoke all on function public.organization_only_onboarding(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.organization_only_onboarding(uuid,uuid,jsonb) to service_role;

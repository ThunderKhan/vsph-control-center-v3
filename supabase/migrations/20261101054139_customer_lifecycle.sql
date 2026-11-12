-- Serialize lifecycle/entitlement changes per organization and fence stale forms.
alter table public.organizations add column version integer not null default 1;
create index app_sessions_organization on public.app_sessions(organization_id);
-- Prevent a login from inserting a usable product session after suspension commits.
create function public.guard_product_session_organization() returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform 1 from public.organizations where id=new.organization_id and status='active' for share;
 if not found then raise exception 'Organization unavailable' using errcode='42501';end if;
 return new;
end$$;
revoke all on function public.guard_product_session_organization() from public,anon,authenticated;
grant execute on function public.guard_product_session_organization() to service_role;
create trigger guard_product_session_organization before insert on public.app_sessions for each row execute function public.guard_product_session_organization();
create function public.customer_lifecycle(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare org_row public.organizations; app_id uuid; impact jsonb; start_at timestamptz; end_at timestamptz;
begin
 perform 1 from public.profiles where id=p_actor and platform_role='super_admin' and status='active' for update;
 if not found then raise exception 'Platform administrator required' using errcode='42501';end if;
 select * into org_row from public.organizations where id=p_id for no key update;
 if not found then raise exception 'Organization missing' using errcode='P0002';end if;
 impact:=jsonb_build_object('productSessions',(select count(*) from public.app_sessions where organization_id=p_id),'activeMembers',(select count(*) from public.organization_memberships where organization_id=p_id and status='active'),'pendingInvitations',(select count(*) from public.membership_invitations where organization_id=p_id and state not in ('accepted','revoked')));
 if p_action='preview' then return jsonb_build_object('version',org_row.version,'status',org_row.status,'impact',impact);end if;
 if p_action not in ('status','subscription','access','entitlement') or jsonb_typeof(p_data) is distinct from 'object' or exists(select 1 from jsonb_object_keys(p_data) k where k not in ('version','confirmed','status','applicationId','planCode','subscriptionStatus','accessStatus','startsAt','endsAt')) then raise exception 'Invalid action or fields' using errcode='22023';end if;
 if org_row.version is distinct from (p_data->>'version')::integer then raise exception 'Concurrent lifecycle change' using errcode='40001';end if;
 if p_data->'confirmed' is distinct from 'true'::jsonb then raise exception 'Explicit impact confirmation required' using errcode='22023';end if;
 if p_action='status' then
  if coalesce(p_data->>'status','') not in ('active','suspended','closed') or (org_row.status='closed' and p_data->>'status'<>'closed') then raise exception 'Invalid lifecycle transition' using errcode='22023';end if;
  update public.organizations set status=p_data->>'status',version=version+1 where id=p_id;
  if p_data->>'status'<>'active' then
   delete from public.app_sessions where organization_id=p_id;
   delete from public.sso_launch_codes where organization_id=p_id;
   update public.membership_invitations set state='revoked',token_hash=null where organization_id=p_id and state not in ('accepted','revoked');
   update public.invitation_outbox set state='revoked',encrypted_delivery=null where invitation_id in(select id from public.membership_invitations where organization_id=p_id and state='revoked');
   update public.provisioning_jobs set state='revoked' where organization_id=p_id and state<>'ready';
  end if;
 else
  app_id:=(p_data->>'applicationId')::uuid;
  perform 1 from public.applications where id=app_id;
  if not found then raise exception 'Application missing' using errcode='P0002';end if;
  if p_action in ('subscription','entitlement') then
   start_at:=coalesce(nullif(p_data->>'startsAt','')::timestamptz,(select starts_at from public.subscriptions where organization_id=p_id and application_id=app_id),now());end_at:=nullif(p_data->>'endsAt','')::timestamptz;
   if coalesce(p_data->>'planCode','')!~'^[a-z0-9][a-z0-9_-]{0,59}$' or coalesce(p_data->>'subscriptionStatus','') not in ('trial','active','past_due','cancelled','expired') or
    (end_at is not null and end_at<=start_at) or (p_data->>'subscriptionStatus'='trial' and (end_at is null or end_at<=now())) then raise exception 'Invalid terms' using errcode='22023';end if;
   insert into public.subscriptions(organization_id,application_id,plan_code,status,starts_at,ends_at) values(p_id,app_id,p_data->>'planCode',p_data->>'subscriptionStatus',start_at,end_at)
    on conflict(organization_id,application_id) do update set plan_code=excluded.plan_code,status=excluded.status,starts_at=excluded.starts_at,ends_at=excluded.ends_at;
  end if;
  if p_action in ('access','entitlement') then
   if coalesce(p_data->>'accessStatus','') not in ('enabled','suspended','revoked') then raise exception 'Invalid grant' using errcode='22023';end if;
   insert into public.organization_app_access(organization_id,application_id,status) values(p_id,app_id,p_data->>'accessStatus') on conflict(organization_id,application_id) do update set status=excluded.status;
  end if;
  delete from public.app_sessions where organization_id=p_id and application_id=app_id;
  delete from public.sso_launch_codes where organization_id=p_id and application_id=app_id;
  update public.organizations set version=version+1 where id=p_id;
 end if;
 insert into public.audit_logs(actor_user_id,organization_id,action,target_type,target_id,details) values(p_actor,p_id,'customer.'||p_action||'_updated','organization',p_id::text,jsonb_build_object('beforeStatus',org_row.status,'beforeVersion',org_row.version,'impact',impact,'requested',p_data));
 return jsonb_build_object('version',org_row.version+1,'impact',impact);
end$$;
revoke all on function public.customer_lifecycle(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.customer_lifecycle(uuid,text,uuid,jsonb) to service_role;

-- Bounded directory pagination; direct read continues to work beyond the first page.
create or replace function public.customer_command(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.organization_memberships; v_user uuid; v_role text; v_app uuid; result jsonb;
begin
 perform 1 from public.profiles where id=p_actor and status='active' and platform_role='super_admin' for update;
 if not found then raise exception 'Platform administrator required' using errcode='42501';end if;
 if p_action='list' then
  return coalesce((select jsonb_agg(x) from(select id,name,slug,status from public.organizations where p_data->>'afterId' is null or id>(p_data->>'afterId')::uuid order by id limit 100)x),'[]');
 elsif p_action='read' then
  select to_jsonb(o) into result from public.organizations o where id=p_id;
  if not found then raise exception 'Missing organization' using errcode='P0002';end if;
  return jsonb_build_object('organization',result,
   'members',coalesce((select jsonb_agg(x) from(select mem.user_id,mem.role,mem.status,mem.version,p.full_name,p.email,p.status account_status from public.organization_memberships mem join public.profiles p on p.id=mem.user_id where mem.organization_id=p_id order by p.email limit 200)x),'[]'),
   'products',coalesce((select jsonb_agg(x) from(select a.id,a.code,a.name,a.status,g.status access_status,s.plan_code,s.status subscription_status,s.starts_at,s.ends_at,(select jsonb_agg(r.code order by r.code) from public.app_roles r where r.application_id=a.id) roles from public.applications a join public.organization_app_access g on g.application_id=a.id and g.organization_id=p_id left join public.subscriptions s on s.organization_id=p_id and s.application_id=a.id order by a.code limit 100)x),'[]'),
   'roles',coalesce((select jsonb_agg(x) from(select user_id,application_id,role_code from public.user_app_roles where organization_id=p_id order by user_id,application_id limit 500)x),'[]'),
   'invitations',coalesce((select jsonb_agg(x) from(select i.id,i.email,i.state,i.generation,i.expires_at,(i.expires_at<=now() and i.state not in ('accepted','revoked')) expired,o.state delivery_state,o.failure_code,o.attempts from public.membership_invitations i join public.invitation_outbox o on o.invitation_id=i.id where i.organization_id=p_id order by i.expires_at desc,i.id limit 100)x),'[]'),
   'activity',coalesce((select jsonb_agg(x) from(select action,target_type,target_id,created_at from public.audit_logs where organization_id=p_id order by created_at desc,id desc limit 100)x),'[]'));
 elsif p_action in ('member','role') then
  v_user:=(p_data->>'userId')::uuid;
  perform 1 from public.profiles where id=v_user for update;
  perform 1 from public.organizations where id=p_id for update;
  select * into m from public.organization_memberships where organization_id=p_id and user_id=v_user for update;
  if not found then raise exception 'Membership missing' using errcode='P0002';end if;
  if (p_data->>'version')::integer is distinct from m.version then raise exception 'Concurrent change' using errcode='40001';end if;
  if p_action='member' then
   if p_data->>'status'='active' and (not exists(select 1 from public.profiles where id=v_user and status='active') or not exists(select 1 from public.organizations where id=p_id and status='active')) then raise exception 'Account or organization disabled' using errcode='42501';end if;
   if coalesce(p_data->>'status','') not in ('active','suspended') or coalesce(p_data->>'role','') not in ('owner','admin','member','viewer') or m.status='invited' then raise exception 'Use invitation acceptance' using errcode='22023';end if;
   if m.role='owner' and m.status='active' and (p_data->>'role'<>'owner' or p_data->>'status'<>'active') and not exists(select 1 from public.organization_memberships where organization_id=p_id and user_id<>v_user and role='owner' and status='active') then raise exception 'Last owner' using errcode='22023';end if;
   update public.organization_memberships set role=p_data->>'role',status=p_data->>'status',version=version+1 where organization_id=p_id and user_id=v_user;
   if p_data->>'status'='suspended' then
    update public.membership_invitations set state='revoked',token_hash=null where organization_id=p_id and user_id=v_user and state not in ('accepted','revoked');
    update public.invitation_outbox set state='revoked',encrypted_delivery=null where invitation_id in(select id from public.membership_invitations where organization_id=p_id and user_id=v_user and state='revoked');
    update public.provisioning_jobs set state='revoked' where id in(select job_id from public.membership_invitations where organization_id=p_id and user_id=v_user and state='revoked');
   end if;
  else
   if m.status<>'active' then raise exception 'Active member required' using errcode='42501';end if;
   v_app:=(p_data->>'applicationId')::uuid;v_role:=p_data->>'role';
   if v_role is null then raise exception 'Explicit role required' using errcode='22023';end if;
   if v_role='' then delete from public.user_app_roles where organization_id=p_id and user_id=v_user and application_id=v_app;
   else
    perform 1 from public.organization_app_access g join public.applications a on a.id=g.application_id join public.app_roles r on r.application_id=a.id and r.code=v_role where g.organization_id=p_id and a.id=v_app and a.status='active' and g.status='enabled' and (v_role not in ('staff','musician') or a.code='MUSIC');
    if not found then raise exception 'Role or grant unavailable' using errcode='42501';end if;
    insert into public.user_app_roles(organization_id,user_id,application_id,role_code) values(p_id,v_user,v_app,v_role) on conflict(organization_id,user_id,application_id) do update set role_code=excluded.role_code;
   end if;
   update public.organization_memberships set version=version+1 where organization_id=p_id and user_id=v_user;
  end if;
  delete from public.app_sessions where organization_id=p_id and user_id=v_user;
  delete from public.sso_launch_codes where organization_id=p_id and user_id=v_user;
  insert into public.audit_logs(actor_user_id,organization_id,action,target_type,target_id,details) values(p_actor,p_id,'customer.'||p_action||'_changed','membership',v_user::text,jsonb_build_object('before',to_jsonb(m),'requested',p_data));
  return '{"ok":true}';
 end if;
 raise exception 'Invalid command' using errcode='22023';
end$$;
revoke all on function public.customer_command(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.customer_command(uuid,text,uuid,jsonb) to service_role;

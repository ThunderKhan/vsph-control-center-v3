-- Customer administration is a separate boundary from platform administration.
-- No browser grants, implicit product role, subscription change or identity activation.
create function public.organization_command(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare org public.organizations; actor_member public.organization_memberships;
 target_member public.organization_memberships; target_user uuid; app_id uuid;
 result jsonb; target_role text; desired_role text; desired_status text;
begin
 if jsonb_typeof(p_data) is distinct from 'object' then raise exception 'Object required' using errcode='22023';end if;
 if p_action in ('member','role') then
  target_user:=(p_data->>'userId')::uuid;
  if target_user is null or target_user=p_actor then raise exception 'Self changes unavailable' using errcode='42501';end if;
  -- Global ordering across customer organizations, not merely within one tenant.
  -- Platform actors precede ordinary profiles, matching platform governance;
  -- ordinary actor/target profiles are locked in UUID order.
  perform 1 from public.profiles where id=p_actor or (id=target_user and platform_role='user')
   order by (platform_role='super_admin') desc,id for update;
 else
  perform 1 from public.profiles where id=p_actor for update;
 end if;
 perform 1 from public.profiles where id=p_actor and status='active';
 if not found then raise exception 'Active identity required' using errcode='42501';end if;
 if p_action='list' then
  if exists(select 1 from jsonb_object_keys(p_data) k where k<>'afterId') then raise exception 'Invalid fields' using errcode='22023';end if;
  return coalesce((select jsonb_agg(x) from(select o.id,o.name,o.slug,m.role from public.organizations o join public.organization_memberships m on m.organization_id=o.id where m.user_id=p_actor and m.status='active' and m.role in ('owner','admin') and o.status='active' and (p_data->>'afterId' is null or o.id>(p_data->>'afterId')::uuid) order by o.id limit 100)x),'[]');
 end if;
 -- Check scoped role authority after acquiring consistently ordered profiles.
 if p_action in ('member','role') then
  target_user:=(p_data->>'userId')::uuid;
  if target_user is null or target_user=p_actor then raise exception 'Self changes unavailable' using errcode='42501';end if;
  select * into actor_member from public.organization_memberships where organization_id=p_id and user_id=p_actor and status='active' and role in ('owner','admin');
  if not found then raise exception 'Organization administrator required' using errcode='42501';end if;
  select * into target_member from public.organization_memberships where organization_id=p_id and user_id=target_user;
  if not found or target_member.role='owner' or (actor_member.role='admin' and target_member.role='admin') then raise exception 'Target unavailable' using errcode='42501';end if;
  perform 1 from public.profiles where id=target_user and platform_role='user' for update;
  if not found then raise exception 'Platform identities require platform governance' using errcode='42501';end if;
 end if;
 -- Profiles precede the organization, then memberships, as in platform governance:
 -- membership. NO KEY UPDATE remains compatible with enrollment's FK KEY SHARE.
 select * into org from public.organizations where id=p_id and status='active' for no key update;
 if not found then raise exception 'Organization unavailable' using errcode='42501';end if;
 select * into actor_member from public.organization_memberships where organization_id=p_id and user_id=p_actor and status='active' and role in ('owner','admin') for update;
 if not found then raise exception 'Organization administrator required' using errcode='42501';end if;
 if p_action='read' then
  if p_data<>'{}'::jsonb then raise exception 'Invalid fields' using errcode='22023';end if;
  return jsonb_build_object('organization',jsonb_build_object('id',org.id,'name',org.name,'slug',org.slug,'status',org.status,'version',org.version),'actorRole',actor_member.role,'actorId',p_actor,
   'counts',jsonb_build_object('activeMembers',(select count(*) from public.organization_memberships where organization_id=p_id and status='active'),'invitedMembers',(select count(*) from public.organization_memberships where organization_id=p_id and status='invited'),'suspendedMembers',(select count(*) from public.organization_memberships where organization_id=p_id and status='suspended')),
   'products',coalesce((select jsonb_agg(x) from(select a.id,a.code,a.name,a.status,g.status access_status,s.plan_code,s.status subscription_status,s.starts_at,s.ends_at,
    (a.status='active' and g.status='enabled' and s.status in ('active','trial') and s.starts_at<=now() and (s.ends_at is null or s.ends_at>now())) effective,
    exists(select 1 from public.user_app_roles r where r.organization_id=p_id and r.user_id=p_actor and r.application_id=a.id and r.role_code in ('super_admin','admin')) can_assign,
    (select jsonb_agg(r.code order by r.code) from public.app_roles r where r.application_id=a.id and r.code<>'super_admin') roles
    from public.organization_app_access g join public.applications a on a.id=g.application_id left join public.subscriptions s on s.organization_id=g.organization_id and s.application_id=a.id where g.organization_id=p_id order by a.code limit 100)x),'[]'),
   'productCount',(select count(*) from public.organization_app_access where organization_id=p_id),
   'activity',coalesce((select jsonb_agg(x) from(select action,target_type,created_at from public.audit_logs where organization_id=p_id and action like 'organization.%' order by created_at desc,id desc limit 50)x),'[]'));
 elsif p_action='members' then
  if exists(select 1 from jsonb_object_keys(p_data) k where k<>'afterId') then raise exception 'Invalid fields' using errcode='22023';end if;
  return coalesce((select jsonb_agg(x) from(select m.user_id,m.role,m.status,m.version,p.full_name,p.email,p.status account_status,
   (m.user_id<>p_actor and m.role<>'owner' and p.platform_role='user' and (actor_member.role='owner' or m.role<>'admin')) manageable,
   coalesce((select jsonb_agg(jsonb_build_object('applicationId',r.application_id,'role',r.role_code) order by r.application_id) from public.user_app_roles r where r.organization_id=p_id and r.user_id=m.user_id),'[]') product_roles
   from public.organization_memberships m join public.profiles p on p.id=m.user_id where m.organization_id=p_id and (p_data->>'afterId' is null or m.user_id>(p_data->>'afterId')::uuid) order by m.user_id limit 50)x),'[]');
 elsif p_action='profile' then
  if exists(select 1 from jsonb_object_keys(p_data) k where k not in ('version','name')) or (p_data->>'version')::integer is distinct from org.version or jsonb_typeof(p_data->'name') is distinct from 'string' then raise exception 'Invalid or stale profile' using errcode='40001';end if;
  if length(btrim(p_data->>'name')) not between 1 and 150 or (p_data->>'name')~'[[:cntrl:]]' then raise exception 'Invalid name' using errcode='22023';end if;
  update public.organizations set name=btrim(p_data->>'name'),version=version+1 where id=p_id;
  result:=jsonb_build_object('version',org.version+1);
 elsif p_action in ('member','role') then
  if p_data->'confirmed' is distinct from 'true'::jsonb or exists(select 1 from jsonb_object_keys(p_data) k where k not in ('userId','version','confirmed','role','status','applicationId')) then raise exception 'Explicit confirmation and allowlisted fields required' using errcode='22023';end if;
  select * into target_member from public.organization_memberships where organization_id=p_id and user_id=target_user for update;
  if not found or target_member.role='owner' or (actor_member.role='admin' and target_member.role='admin') then raise exception 'Target unavailable' using errcode='42501';end if;
  if (p_data->>'version')::integer is distinct from target_member.version then raise exception 'Stale membership' using errcode='40001';end if;
  if target_member.status='invited' then raise exception 'Invitation acceptance required' using errcode='22023';end if;
  if p_action='member' then
   desired_role:=p_data->>'role';desired_status:=p_data->>'status';
   if coalesce(desired_role,'') not in ('admin','member','viewer') or coalesce(desired_status,'') not in ('active','suspended') or (actor_member.role<>'owner' and desired_role='admin') then raise exception 'Invalid delegated role' using errcode='42501';end if;
   if desired_status='active' and not exists(select 1 from public.profiles where id=target_user and status='active') then raise exception 'Disabled identity' using errcode='42501';end if;
   update public.organization_memberships set role=desired_role,status=desired_status,version=version+1 where organization_id=p_id and user_id=target_user;
   if desired_status='suspended' then
    update public.membership_invitations set state='revoked',token_hash=null where organization_id=p_id and user_id=target_user and state not in ('accepted','revoked');
    update public.invitation_outbox set state='revoked',encrypted_delivery=null where invitation_id in(select id from public.membership_invitations where organization_id=p_id and user_id=target_user and state='revoked');
    update public.provisioning_jobs set state='revoked' where id in(select job_id from public.membership_invitations where organization_id=p_id and user_id=target_user and state='revoked');
   end if;
  else
   app_id:=(p_data->>'applicationId')::uuid;target_role:=p_data->>'role';
   if target_member.status<>'active' or target_role is null then raise exception 'Active target and explicit role required' using errcode='42501';end if;
   if exists(select 1 from public.user_app_roles where organization_id=p_id and user_id=target_user and application_id=app_id and role_code='super_admin') then raise exception 'Product super admin requires platform governance' using errcode='42501';end if;
   perform 1 from public.organization_app_access g join public.applications a on a.id=g.application_id join public.subscriptions s on s.organization_id=g.organization_id and s.application_id=a.id join public.user_app_roles r on r.organization_id=g.organization_id and r.application_id=a.id and r.user_id=p_actor and r.role_code in ('super_admin','admin')
    where g.organization_id=p_id and a.id=app_id and g.status='enabled' and a.status='active' and s.status in ('active','trial') and s.starts_at<=now() and (s.ends_at is null or s.ends_at>now()) for share of a;
   if not found then raise exception 'Effective entitlement and explicit product administrator required' using errcode='42501';end if;
   if target_role='' then delete from public.user_app_roles where organization_id=p_id and user_id=target_user and application_id=app_id;
   else
    if target_role='super_admin' or not exists(select 1 from public.app_roles where application_id=app_id and code=target_role) then raise exception 'Product role unavailable' using errcode='42501';end if;
    insert into public.user_app_roles(organization_id,user_id,application_id,role_code) values(p_id,target_user,app_id,target_role) on conflict(organization_id,user_id,application_id) do update set role_code=excluded.role_code;
   end if;
   update public.organization_memberships set version=version+1 where organization_id=p_id and user_id=target_user;
  end if;
  delete from public.app_sessions where organization_id=p_id and user_id=target_user;
  delete from public.sso_launch_codes where organization_id=p_id and user_id=target_user;
  result:=jsonb_build_object('version',target_member.version+1);
 else raise exception 'Invalid command' using errcode='22023';
 end if;
 insert into public.audit_logs(actor_user_id,organization_id,action,target_type,target_id,details) values(p_actor,p_id,'organization.'||p_action||'_updated',case when p_action='profile' then 'organization' else 'membership' end,coalesce(target_user,p_id)::text,jsonb_build_object('requested',p_data));
 return result;
end$$;
revoke all on function public.organization_command(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.organization_command(uuid,text,uuid,jsonb) to service_role;

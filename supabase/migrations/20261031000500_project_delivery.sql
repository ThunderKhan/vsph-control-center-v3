-- Depends on schema.sql, Music migrations, atomic status 001 and Phase 2 002/003/004.
-- No external credentials or fixtures. Browser roles have no direct access.
create table public.project_github_installations(
 project_id uuid not null references public.projects(id), installation_id bigint not null check(installation_id>0),
 account_id bigint not null check(account_id>0), account_login text not null check(length(account_login)<=100),
 status text not null default 'active' check(status in ('active','revoked')), approved_by uuid not null references public.profiles(id),
 primary key(project_id,installation_id)
);
create table public.project_repositories(
 id uuid primary key default gen_random_uuid(),project_id uuid not null references public.projects(id),installation_id bigint not null,
 repository_id bigint not null check(repository_id>0),full_name text not null check(length(full_name)<=250),
 default_branch text not null check(length(default_branch)<=250),private boolean not null,version integer not null default 1,
 status text not null default 'active' check(status in ('active','disconnected','attention')),
 checkpoint jsonb not null default '{"kind":0,"page":1}',sync_requested boolean not null default true,
 next_sync_at timestamptz not null default now(),lease_token uuid,lease_until timestamptz,attempts integer not null default 0,
 last_success_at timestamptz,last_error text,created_at timestamptz not null default now(),
 unique(project_id,repository_id),unique(project_id,id),foreign key(project_id,installation_id) references public.project_github_installations(project_id,installation_id)
);
create table public.project_delivery_records(
 id uuid primary key default gen_random_uuid(),project_id uuid not null,connection_id uuid not null,
 kind text not null check(kind in ('commit','contributor','pull','workflow','check','release','tag')),
 source_id text not null check(length(source_id) between 1 and 200),title text not null check(length(title)<=500),
 url text not null check(url ~ '^https://github.com/'),state text not null check(length(state)<=100),
 source_at timestamptz not null,details jsonb not null default '{}',observed_at timestamptz not null default now(),
 unique(connection_id,kind,source_id),unique(project_id,id),foreign key(project_id,connection_id) references public.project_repositories(project_id,id),
 check(octet_length(details::text)<=8000)
);
create table public.project_delivery_events(
 id bigint generated always as identity primary key,project_id uuid not null,record_id uuid not null,
 fingerprint text not null check(length(fingerprint)<=250),snapshot jsonb not null,observed_at timestamptz not null default now(),
 unique(record_id,fingerprint),foreign key(project_id,record_id) references public.project_delivery_records(project_id,id)
);
create table public.project_delivery_links(
 project_id uuid not null,record_id uuid not null,task_id uuid,milestone_id uuid,actor_id uuid not null references public.profiles(id),
 primary key(project_id,record_id),check(num_nonnulls(task_id,milestone_id)=1),
 foreign key(project_id,record_id) references public.project_delivery_records(project_id,id),
 foreign key(project_id,task_id) references public.project_tasks(project_id,id),
 foreign key(project_id,milestone_id) references public.project_milestones(project_id,id)
);
create table public.github_webhook_receipts(
 delivery_id uuid primary key,payload_hash text not null check(length(payload_hash)=64),received_at timestamptz not null default now()
);
create index on public.project_repositories(next_sync_at) where status='active';
create index on public.project_delivery_records(project_id,source_at desc);
create index on public.project_delivery_events(project_id,id desc);
do $$declare t text;begin foreach t in array array['project_github_installations','project_repositories','project_delivery_records','project_delivery_events','project_delivery_links','github_webhook_receipts'] loop
 execute format('alter table public.%I enable row level security',t);execute format('revoke all on public.%I from public,anon,authenticated',t);end loop;end$$;

create function public.delivery_command(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare p public.projects; c public.project_repositories; r public.project_delivery_records; item jsonb; role text; result jsonb; v_grant public.project_github_installations; v_hash text; v_id uuid;
begin
 if p_action='webhook' and p_actor is null then
  insert into public.github_webhook_receipts(delivery_id,payload_hash) values((p_data->>'deliveryId')::uuid,p_data->>'hash') on conflict do nothing;
  if not found then
   if not exists(select 1 from public.github_webhook_receipts where delivery_id=(p_data->>'deliveryId')::uuid and payload_hash=p_data->>'hash') then raise exception 'Delivery identity conflict' using errcode='40001';end if;
   return '{"duplicate":true}';
  end if;
  perform pr.id from public.projects pr join public.project_github_installations g on g.project_id=pr.id where g.installation_id=(p_data->>'installationId')::bigint order by pr.id for update of pr;
  if coalesce((p_data->>'revoked')::boolean,false) then
   update public.project_github_installations set status='revoked' where installation_id=(p_data->>'installationId')::bigint;
   update public.project_repositories set status='attention',last_error='installation_revoked',lease_token=null,lease_until=null,version=version+1 where installation_id=(p_data->>'installationId')::bigint and status<>'disconnected';
  else
   update public.project_repositories set sync_requested=true,next_sync_at=case when last_error is not null then greatest(next_sync_at,now()) else least(next_sync_at,now()) end where installation_id=(p_data->>'installationId')::bigint and repository_id=(p_data->>'repositoryId')::bigint and status='active';
  end if;
  return '{"accepted":true}';
 end if;
 if p_action='claim' and p_actor is null then
  select x.* into c from public.project_repositories x join public.project_github_installations g using(project_id,installation_id)
  join public.projects pr on pr.id=x.project_id where x.status='active' and g.status='active' and pr.status<>'archived'
   and x.next_sync_at<=now() and (x.lease_until is null or x.lease_until<now()) and (p_id is null or x.id=p_id)
  order by x.next_sync_at,x.id for update of x skip locked limit 1;
  if not found then return null;end if;
  update public.project_repositories set lease_token=gen_random_uuid(),lease_until=now()+interval '2 minutes',sync_requested=false where id=c.id returning * into c;
  select * into v_grant from public.project_github_installations where project_id=c.project_id and installation_id=c.installation_id;
  return to_jsonb(c)||jsonb_build_object('account_id',v_grant.account_id);
 end if;
 if p_action in ('ingest','failed') and p_actor is null then
  -- Same lock order as interactive delivery changes: project -> connection -> grant.
  select pr.* into p from public.projects pr join public.project_repositories x on x.project_id=pr.id where x.id=p_id for update of pr;
  select * into c from public.project_repositories where id=p_id for update;
  if not found or c.status<>'active' or c.lease_token is null or p_data->>'leaseToken' is null or c.lease_until is null or c.lease_token is distinct from (p_data->>'leaseToken')::uuid or c.lease_until<=now() or p.status='archived' then raise exception 'Stale sync lease' using errcode='40001';end if;
  perform 1 from public.project_github_installations where project_id=c.project_id and installation_id=c.installation_id and status='active' for share;
  if not found then raise exception 'Installation unavailable' using errcode='42501';end if;
  if p_action='failed' then
   update public.project_repositories set attempts=attempts+1,last_error=p_data->>'code',status=case when p_data->>'code' in ('permission_denied','repository_unavailable') or attempts>=4 then 'attention' else 'active' end,
    next_sync_at=now()+make_interval(secs=>greatest(60,least(86400,coalesce((p_data->>'retryAfter')::integer,60*(2^least(attempts,10))::integer)))),lease_token=null,lease_until=null where id=c.id;
   return '{"failed":true}';
  end if;
  if jsonb_array_length(p_data->'records')>100 then raise exception 'Page exceeds budget' using errcode='22023';end if;
  for item in select * from jsonb_array_elements(p_data->'records') loop
   insert into public.project_delivery_records(project_id,connection_id,kind,source_id,title,url,state,source_at,details)
    values(c.project_id,c.id,item->>'kind',item->>'sourceId',item->>'title',item->>'url',item->>'state',(item->>'sourceAt')::timestamptz,coalesce(item->'details','{}'))
   on conflict(connection_id,kind,source_id) do update set title=excluded.title,url=excluded.url,state=excluded.state,source_at=excluded.source_at,details=excluded.details,observed_at=now() returning * into r;
   insert into public.project_delivery_events(project_id,record_id,fingerprint,snapshot) values(c.project_id,r.id,r.state||':'||r.source_at::text,jsonb_build_object('kind',r.kind,'title',r.title,'url',r.url,'state',r.state,'source_at',r.source_at)) on conflict do nothing;
  end loop;
  if (select count(*) from public.project_delivery_records where connection_id=c.id)>10000 then raise exception 'Record retention budget reached' using errcode='22023';end if;
  update public.project_repositories set checkpoint=p_data->'checkpoint',attempts=0,last_error=null,last_success_at=now(),
   full_name=coalesce(p_data->>'fullName',full_name),default_branch=coalesce(p_data->>'defaultBranch',default_branch),private=coalesce((p_data->>'private')::boolean,private),
   next_sync_at=case when coalesce((p_data->>'cycleComplete')::boolean,false) and not sync_requested then now()+interval '15 minutes' else now() end,
   lease_token=null,lease_until=null where id=c.id;
  return '{"ingested":true}';
 end if;
 if p_actor is null then raise exception 'Actor required' using errcode='42501';end if;
 perform 1 from public.profiles where id=p_actor and status='active' for share;
 if not found then raise exception 'Account unavailable' using errcode='42501';end if;
 select * into p from public.projects where id=p_id for update;
 role:=public.project_permission(p_actor,p_id);
 if role is null or role='client' then raise exception 'Engineering access denied' using errcode='42501';end if;
 if p_action='detail' then
  return jsonb_build_object('installations',coalesce((select jsonb_agg(g) from public.project_github_installations g where project_id=p.id),'[]'),
   'connections',coalesce((select jsonb_agg(to_jsonb(x)-'lease_token'-'lease_until') from public.project_repositories x where project_id=p.id),'[]'),
   'records',coalesce((select jsonb_agg(x) from (select d.* from public.project_delivery_records d join public.project_repositories conn on conn.id=d.connection_id join public.project_github_installations g on g.project_id=conn.project_id and g.installation_id=conn.installation_id where d.project_id=p.id and conn.status='active' and g.status='active' order by d.source_at desc,d.id limit 200) x),'[]'),
   'events',coalesce((select jsonb_agg(x) from (select e.id,e.observed_at,e.snapshot,e.fingerprint from public.project_delivery_events e join public.project_delivery_records d on d.id=e.record_id join public.project_repositories conn on conn.id=d.connection_id join public.project_github_installations g on g.project_id=conn.project_id and g.installation_id=conn.installation_id where e.project_id=p.id and conn.status='active' and g.status='active' order by e.id desc limit 200) x),'[]'),
   'links',coalesce((select jsonb_agg(l) from public.project_delivery_links l join public.project_delivery_records d on d.id=l.record_id join public.project_repositories conn on conn.id=d.connection_id join public.project_github_installations g on g.project_id=conn.project_id and g.installation_id=conn.installation_id where l.project_id=p.id and conn.status='active' and g.status='active'),'[]'));
 end if;
 if role<>'manager' then raise exception 'Manager required' using errcode='42501';end if;
 if p.status in ('completed','archived') then raise exception 'Project is read only' using errcode='22023';end if;
 if p_action='grant' then
  if not exists(select 1 from public.profiles where id=p_actor and platform_role='super_admin') then raise exception 'Platform approval required' using errcode='42501';end if;
  insert into public.project_github_installations(project_id,installation_id,account_id,account_login,approved_by) values(p.id,(p_data->>'installationId')::bigint,(p_data->>'accountId')::bigint,p_data->>'accountLogin',p_actor)
  on conflict(project_id,installation_id) do update set status='active',account_id=excluded.account_id,account_login=excluded.account_login,approved_by=excluded.approved_by;
 elsif p_action='grant.revoke' then
  if not exists(select 1 from public.profiles where id=p_actor and platform_role='super_admin') then raise exception 'Platform approval required' using errcode='42501';end if;
  update public.project_github_installations set status='revoked' where project_id=p.id and installation_id=(p_data->>'installationId')::bigint;
  update public.project_repositories set status='disconnected',lease_token=null,lease_until=null,version=version+1 where project_id=p.id and installation_id=(p_data->>'installationId')::bigint;
 elsif p_action='connect' then
  perform 1 from public.project_github_installations where project_id=p.id and installation_id=(p_data->>'installationId')::bigint and account_id=(p_data->>'accountId')::bigint and status='active' for share;
  if not found then raise exception 'Installation not approved for project' using errcode='42501';end if;
  if (select count(*) from public.project_repositories where project_id=p.id)>=20 and not exists(select 1 from public.project_repositories where project_id=p.id and repository_id=(p_data->>'repositoryId')::bigint) then raise exception 'Connection budget reached' using errcode='22023';end if;
  insert into public.project_repositories(project_id,installation_id,repository_id,full_name,default_branch,private) values(p.id,(p_data->>'installationId')::bigint,(p_data->>'repositoryId')::bigint,p_data->>'fullName',p_data->>'defaultBranch',(p_data->>'private')::boolean)
  on conflict(project_id,repository_id) do update set status='active',installation_id=excluded.installation_id,full_name=excluded.full_name,default_branch=excluded.default_branch,private=excluded.private,checkpoint='{"kind":0,"page":1}',version=project_repositories.version+1,lease_token=null,lease_until=null,next_sync_at=case when project_repositories.last_error is not null then greatest(project_repositories.next_sync_at,now()) else now() end,attempts=project_repositories.attempts,last_error=project_repositories.last_error;
 elsif p_action in ('request','disconnect') then
  select * into c from public.project_repositories where id=(p_data->>'connectionId')::uuid and project_id=p.id for update;
  if not found then raise exception 'Connection unavailable' using errcode='P0002';end if;
  if c.version is distinct from (p_data->>'version')::integer then raise exception 'Stale connection' using errcode='40001';end if;
  if p_action='disconnect' then update public.project_repositories set status='disconnected',lease_token=null,lease_until=null,version=version+1 where id=c.id;
  else
   if c.status='disconnected' then raise exception 'Reconnect after permission verification' using errcode='22023';end if;
   perform 1 from public.project_github_installations where project_id=p.id and installation_id=c.installation_id and status='active';
   if not found then raise exception 'Installation revoked' using errcode='42501';end if;
   update public.project_repositories set sync_requested=true,next_sync_at=greatest(now(),case when last_error is not null then next_sync_at else now() end),status='active',attempts=0,version=version+1 where id=c.id;
  end if;
 elsif p_action='link' then
  select d.* into r from public.project_delivery_records d join public.project_repositories conn on conn.id=d.connection_id where d.id=(p_data->>'recordId')::uuid and d.project_id=p.id and conn.status='active';
  if not found or r.kind not in ('pull','release') then raise exception 'Link source unavailable' using errcode='22023';end if;
  insert into public.project_delivery_links(project_id,record_id,task_id,milestone_id,actor_id) values(p.id,r.id,nullif(p_data->>'taskId','')::uuid,nullif(p_data->>'milestoneId','')::uuid,p_actor)
  on conflict(project_id,record_id) do update set task_id=excluded.task_id,milestone_id=excluded.milestone_id,actor_id=excluded.actor_id;
 else raise exception 'Unknown delivery action' using errcode='22023';end if;
 insert into public.audit_logs(actor_user_id,organization_id,action,target_type,target_id) values(p_actor,p.customer_organization_id,'delivery.'||p_action,'project',p.id::text);
 return '{"saved":true}';
end$$;
revoke all on function public.delivery_command(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.delivery_command(uuid,text,uuid,jsonb) to service_role;

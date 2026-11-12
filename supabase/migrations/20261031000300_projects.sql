-- First-class project domain. No entitlement/product role confers project membership.
create table public.projects(
 id uuid primary key default gen_random_uuid(), key text not null unique check(key ~ '^[A-Z][A-Z0-9-]{1,19}$'),
 name text not null check(length(name) between 1 and 150), description text not null default '' check(length(description)<=5000),
 kind text not null check(kind in ('internal','customer')), customer_organization_id uuid references public.organizations(id),
 owner_id uuid not null references public.profiles(id), created_by uuid not null references public.profiles(id),
 status text not null default 'planned' check(status in ('planned','active','paused','completed','archived')),
 priority text not null default 'normal' check(priority in ('low','normal','high','urgent')),
 starts_on date, due_on date, client_visible boolean not null default false,
 version integer not null default 1, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 check((kind='customer')=(customer_organization_id is not null)),check(due_on is null or starts_on is null or due_on>=starts_on)
);
create table public.project_memberships(
 project_id uuid not null references public.projects(id), user_id uuid not null references public.profiles(id),
 role text not null check(role in ('manager','contributor','viewer','client')),
 status text not null default 'active' check(status in ('active','revoked')), team text not null default '' check(length(team)<=100),
 primary key(project_id,user_id)
);
create table public.project_products(project_id uuid not null references public.projects(id),application_id uuid not null references public.applications(id),primary key(project_id,application_id));
create table public.project_milestones(
 id uuid primary key default gen_random_uuid(),project_id uuid not null references public.projects(id),
 title text not null check(length(title) between 1 and 200),status text not null default 'planned' check(status in ('planned','active','done','cancelled')),
 due_on date, depends_on uuid, shared boolean not null default false,unique(project_id,id),
 foreign key(project_id,depends_on) references public.project_milestones(project_id,id),check(id is distinct from depends_on)
);
create table public.project_tasks(
 id uuid primary key default gen_random_uuid(),project_id uuid not null references public.projects(id),
 title text not null check(length(title) between 1 and 200),description text not null default '' check(length(description)<=5000),
 milestone_id uuid,assignee_id uuid,status text not null default 'todo' check(status in ('todo','in_progress','blocked','in_review','done','cancelled')),
 priority text not null default 'normal' check(priority in ('low','normal','high','urgent')),due_on date,shared boolean not null default false,
 unique(project_id,id),foreign key(project_id,milestone_id) references public.project_milestones(project_id,id),
 foreign key(project_id,assignee_id) references public.project_memberships(project_id,user_id)
);
create table public.project_comments(
 id uuid primary key default gen_random_uuid(),project_id uuid not null references public.projects(id),task_id uuid,
 actor_id uuid not null references public.profiles(id),body text not null check(length(body) between 1 and 4000),shared boolean not null default false,
 created_at timestamptz not null default now(),foreign key(project_id,task_id) references public.project_tasks(project_id,id)
);
create table public.project_deliverables(
 id uuid primary key default gen_random_uuid(),project_id uuid not null references public.projects(id),task_id uuid,
 title text not null check(length(title) between 1 and 200),url text not null check(length(url)<=2000 and url ~ '^https://[^/[:space:]]+'),
 actor_id uuid not null references public.profiles(id),shared boolean not null default false,created_at timestamptz not null default now(),
 foreign key(project_id,task_id) references public.project_tasks(project_id,id)
);
create table public.project_activity(
 id bigint generated always as identity primary key,project_id uuid not null references public.projects(id),
 actor_id uuid not null references public.profiles(id),action text not null,entity_id uuid,summary text not null,shared boolean not null default false,
 created_at timestamptz not null default now()
);
create index on public.project_memberships(user_id,status,project_id);
create index on public.project_tasks(project_id,status,due_on);
create index on public.project_milestones(project_id,due_on);
create index on public.project_comments(project_id,created_at);
create index on public.project_activity(project_id,id desc);
do $$declare t text;begin foreach t in array array['projects','project_memberships','project_products','project_milestones','project_tasks','project_comments','project_deliverables','project_activity'] loop
 execute format('alter table public.%I enable row level security',t);execute format('revoke all on public.%I from public,anon,authenticated',t);end loop;end$$;

create function public.project_permission(p_actor uuid,p_project uuid) returns text language sql stable security definer set search_path='' as $$
 select case when u.platform_role='super_admin' then 'manager' else m.role end
 from public.projects p join public.profiles u on u.id=p_actor and u.status='active'
 left join public.project_memberships m on m.project_id=p.id and m.user_id=u.id and m.status='active'
 where p.id=p_project and (u.platform_role='super_admin' or
 (m.role is not null and (m.role<>'client' or (p.client_visible and exists(select 1 from public.organization_memberships om
 join public.organizations org on org.id=om.organization_id and org.status='active'
 where om.organization_id=p.customer_organization_id and om.user_id=p_actor and om.status='active')))))
$$;
revoke all on function public.project_permission(uuid,uuid) from public,anon,authenticated;

create function public.project_command(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare p public.projects; task public.project_tasks; milestone public.project_milestones;
 v_role text; v_admin boolean; entity uuid; person uuid; v_shared boolean:=false; v_title text; new_status text; response jsonb; record jsonb;
begin
 select platform_role='super_admin' into v_admin from public.profiles where id=p_actor and status='active' for share;
 if not found then raise exception 'Account unavailable' using errcode='42501';end if;
 if p_action='list' then
  return jsonb_build_object('projects',coalesce((select jsonb_agg(x) from (select pr.*,
   (select count(*) from public.project_tasks t where t.project_id=pr.id and t.status='done' and (public.project_permission(p_actor,pr.id)<>'client' or t.shared)) completed_tasks,
   (select count(*) from public.project_tasks t where t.project_id=pr.id and t.status<>'cancelled' and (public.project_permission(p_actor,pr.id)<>'client' or t.shared)) total_tasks
   from public.projects pr where public.project_permission(p_actor,pr.id) is not null
    and (p_data->>'cursor' is null or pr.id<(p_data->>'cursor')::uuid)
    and (coalesce(p_data->>'q','')='' or pr.name ilike '%'||left(p_data->>'q',100)||'%' or pr.key ilike '%'||left(p_data->>'q',100)||'%')
    and (coalesce(p_data->>'status','')='' or pr.status=p_data->>'status')
   order by pr.id desc limit 50) x),'[]'),'canCreate',v_admin);
 elsif p_action='create' then
  if not v_admin then raise exception 'Portfolio administration required' using errcode='42501';end if;
  insert into public.projects(key,name,description,kind,customer_organization_id,owner_id,created_by,priority,starts_on,due_on,client_visible)
  values(p_data->>'key',p_data->>'name',coalesce(p_data->>'description',''),p_data->>'kind',nullif(p_data->>'customerOrganizationId','')::uuid,
   coalesce(nullif(p_data->>'ownerId','')::uuid,p_actor),p_actor,coalesce(p_data->>'priority','normal'),nullif(p_data->>'startsOn','')::date,nullif(p_data->>'dueOn','')::date,coalesce((p_data->>'clientVisible')::boolean,false)) returning * into p;
  if not exists(select 1 from public.profiles where id=p.owner_id and status='active') then raise exception 'Owner unavailable' using errcode='22023';end if;
  if p.customer_organization_id is not null and not exists(select 1 from public.organizations where id=p.customer_organization_id and status='active') then raise exception 'Customer unavailable' using errcode='22023';end if;
  insert into public.project_memberships(project_id,user_id,role) values(p.id,p.owner_id,'manager');
  for record in select * from jsonb_array_elements(coalesce(p_data->'products','[]')) loop insert into public.project_products values(p.id,(record#>>'{}')::uuid);end loop;
  insert into public.project_activity(project_id,actor_id,action,entity_id,summary) values(p.id,p_actor,'project.created',p.id,p.name);
  insert into public.audit_logs(actor_user_id,organization_id,action,target_type,target_id) values(p_actor,p.customer_organization_id,'project.created','project',p.id::text);
  return to_jsonb(p);
 end if;
 v_role:=public.project_permission(p_actor,p_id);
 if p_action='directory' then
  if not v_admin and v_role is distinct from 'manager' then raise exception 'Not permitted' using errcode='42501';end if;
  return jsonb_build_object('users',coalesce((select jsonb_agg(x) from (select id,full_name,email from public.profiles where status='active' and
   (id=p_actor or lower(email)=lower(p_data->>'email') or id in (select user_id from public.project_memberships where project_id=p_id and status='active')) limit 200) x),'[]'),
   'organizations',coalesce((select jsonb_agg(x) from (select id,name from public.organizations where status='active' and (v_admin or id=(select customer_organization_id from public.projects where id=p_id)) order by name limit 200) x),'[]'),
   'products',coalesce((select jsonb_agg(x) from (select id,name from public.applications where status='active' order by name limit 200) x),'[]'));
 end if;
 if v_role is null then raise exception 'Project unavailable' using errcode='42501';end if;
 select * into p from public.projects where id=p_id for update;
 -- Recheck membership under the project lock; every mutation in this domain takes it.
 v_role:=public.project_permission(p_actor,p_id);
 if v_role is null then raise exception 'Project unavailable' using errcode='42501';end if;
 if p_action='detail' then
  return jsonb_build_object('project',to_jsonb(p),'role',v_role,
   'members',coalesce((select jsonb_agg(x) from (select m.*,u.full_name from public.project_memberships m join public.profiles u on u.id=m.user_id where m.project_id=p.id and (v_role<>'client' or m.user_id=p_actor)) x),'[]'),
   'products',coalesce((select jsonb_agg(x) from (select a.id,a.name from public.project_products pp join public.applications a on a.id=pp.application_id where pp.project_id=p.id) x),'[]'),
   'milestones',coalesce((select jsonb_agg(x order by x.due_on nulls last) from public.project_milestones x where x.project_id=p.id and (v_role<>'client' or x.shared)),'[]'),
   'tasks',coalesce((select jsonb_agg(x order by x.due_on nulls last) from public.project_tasks x where x.project_id=p.id and (v_role<>'client' or x.shared)),'[]'),
   'comments',coalesce((select jsonb_agg(x) from (select c.* from public.project_comments c where c.project_id=p.id and (v_role<>'client' or (c.shared and (c.task_id is null or exists(select 1 from public.project_tasks t where t.id=c.task_id and t.shared)))) order by c.created_at desc limit 200) x),'[]'),
   'deliverables',coalesce((select jsonb_agg(x) from (select d.* from public.project_deliverables d where d.project_id=p.id and (v_role<>'client' or (d.shared and (d.task_id is null or exists(select 1 from public.project_tasks t where t.id=d.task_id and t.shared)))) order by d.created_at desc limit 200) x),'[]'),
   'activity',coalesce((select jsonb_agg(x) from (select a.* from public.project_activity a where a.project_id=p.id and (v_role<>'client' or (a.shared and case
    when a.action like 'task.%' then exists(select 1 from public.project_tasks t where t.id=a.entity_id and t.shared)
    when a.action like 'milestone.%' then exists(select 1 from public.project_milestones m where m.id=a.entity_id and m.shared)
    when a.action='deliverable.create' then exists(select 1 from public.project_deliverables d where d.id=a.entity_id and d.shared and (d.task_id is null or exists(select 1 from public.project_tasks t where t.id=d.task_id and t.shared)))
    when a.action='comment.create' then exists(select 1 from public.project_comments c where c.id=a.entity_id and c.shared and (c.task_id is null or exists(select 1 from public.project_tasks t where t.id=c.task_id and t.shared)))
    else false end)) order by a.id desc limit 200) x),'[]'));
 end if;
 if v_role not in ('manager','contributor') then raise exception 'Read only' using errcode='42501';end if;
 if p.version is distinct from (p_data->>'version')::integer then raise exception 'Stale project version' using errcode='40001';end if;
 if p.status='completed' and p_action<>'update' then raise exception 'Reopen completed project before changing work' using errcode='22023';end if;
 if p.status='archived' and not (v_admin and p_action='update' and p_data->>'status'='planned') then raise exception 'Archived project is read only' using errcode='22023';end if;
 if p_action not in ('task.update','comment.create') and v_role<>'manager' then raise exception 'Manager required' using errcode='42501';end if;
 entity:=coalesce(nullif(p_data->>'id','')::uuid,gen_random_uuid());v_title:=left(coalesce(p_data->>'title',p_data->>'name',p_action),200);
 v_shared:=coalesce((p_data->>'shared')::boolean,false);
 if p_action='update' then
  if v_role<>'manager' then raise exception 'Manager required' using errcode='42501';end if;
  new_status:=coalesce(p_data->>'status',p.status);
  if new_status<>p.status and not ((p.status='planned' and new_status in ('active','archived')) or (p.status='active' and new_status in ('paused','completed','archived')) or (p.status='paused' and new_status in ('active','archived')) or (p.status='completed' and new_status in ('active','archived')) or (p.status='archived' and new_status='planned' and v_admin)) then raise exception 'Invalid project transition' using errcode='22023';end if;
  if new_status='completed' and (exists(select 1 from public.project_tasks where project_id=p.id and status not in ('done','cancelled')) or exists(select 1 from public.project_milestones where project_id=p.id and status not in ('done','cancelled'))) then raise exception 'Complete work before project' using errcode='22023';end if;
  person:=coalesce(nullif(p_data->>'ownerId','')::uuid,p.owner_id);
  if not exists(select 1 from public.profiles where id=person and status='active') then raise exception 'Owner unavailable' using errcode='22023';end if;
  insert into public.project_memberships(project_id,user_id,role) values(p.id,person,'manager') on conflict(project_id,user_id) do update set role='manager',status='active';
  update public.projects set name=coalesce(p_data->>'name',name),description=coalesce(p_data->>'description',description),status=new_status,owner_id=person,
   priority=coalesce(p_data->>'priority',priority),due_on=case when p_data?'dueOn' then nullif(p_data->>'dueOn','')::date else due_on end,
   client_visible=coalesce((p_data->>'clientVisible')::boolean,client_visible) where id=p.id;
  if p_data?'products' then delete from public.project_products where project_id=p.id;for record in select * from jsonb_array_elements(p_data->'products') loop insert into public.project_products values(p.id,(record#>>'{}')::uuid);end loop;end if;
  entity:=p.id;
 elsif p_action='member.save' then
  person:=(p_data->>'userId')::uuid;
  if not exists(select 1 from public.project_memberships where project_id=p.id and user_id=person) and (select count(*) from public.project_memberships where project_id=p.id)>=200 then raise exception 'Membership limit reached' using errcode='22023';end if;
  if person=p.owner_id and (p_data->>'role' is distinct from 'manager' or p_data->>'status' is distinct from 'active') then raise exception 'Transfer ownership before revocation' using errcode='22023';end if;
  if not exists(select 1 from public.profiles where id=person and status='active') then raise exception 'Member unavailable' using errcode='22023';end if;
  if p_data->>'role'='client' and not exists(select 1 from public.organization_memberships where user_id=person and organization_id=p.customer_organization_id and status='active') then raise exception 'Customer membership required' using errcode='22023';end if;
  insert into public.project_memberships(project_id,user_id,role,status,team) values(p.id,person,p_data->>'role',p_data->>'status',coalesce(p_data->>'team','')) on conflict(project_id,user_id) do update set role=excluded.role,status=excluded.status,team=excluded.team;
  entity:=person;
 elsif p_action in ('milestone.create','milestone.update') then
  if p_action='milestone.create' then
   if (select count(*) from public.project_milestones where project_id=p.id)>=100 then raise exception 'Milestone limit reached' using errcode='22023';end if;
   insert into public.project_milestones(id,project_id,title,due_on,shared) values(entity,p.id,p_data->>'title',nullif(p_data->>'dueOn','')::date,v_shared);
  else
   select * into milestone from public.project_milestones where id=entity and project_id=p.id;
   if not found then raise exception 'Milestone unavailable' using errcode='P0002';end if;
   new_status:=coalesce(p_data->>'status',milestone.status);
   if new_status<>milestone.status and not ((milestone.status='planned' and new_status in ('active','cancelled')) or (milestone.status='active' and new_status in ('planned','done','cancelled')) or (milestone.status='done' and new_status='active') or (milestone.status='cancelled' and new_status='planned')) then raise exception 'Invalid milestone transition' using errcode='22023';end if;
   if coalesce(p_data->>'status',milestone.status)='done' and (exists(select 1 from public.project_tasks where milestone_id=entity and status not in ('done','cancelled')) or exists(select 1 from public.project_milestones where id=case when p_data?'dependsOn' then nullif(p_data->>'dependsOn','')::uuid else milestone.depends_on end and status<>'done')) then raise exception 'Milestone work or dependency incomplete' using errcode='22023';end if;
   update public.project_milestones set title=coalesce(p_data->>'title',title),status=coalesce(p_data->>'status',status),due_on=case when p_data?'dueOn' then nullif(p_data->>'dueOn','')::date else due_on end,shared=coalesce((p_data->>'shared')::boolean,shared),depends_on=case when p_data?'dependsOn' then nullif(p_data->>'dependsOn','')::uuid else depends_on end where id=entity;
   if exists(with recursive deps(id) as(select depends_on from public.project_milestones where id=entity union select m.depends_on from public.project_milestones m join deps d on m.id=d.id) select 1 from deps where id=entity) then raise exception 'Cyclic dependency' using errcode='22023';end if;
  end if;
 elsif p_action in ('task.create','task.update') then
  if p_action='task.create' then
   if (select count(*) from public.project_tasks where project_id=p.id)>=500 then raise exception 'Task limit reached' using errcode='22023';end if;
   insert into public.project_tasks(id,project_id,title) values(entity,p.id,p_data->>'title');end if;
  select * into task from public.project_tasks where id=entity and project_id=p.id;
  if not found then raise exception 'Task unavailable' using errcode='P0002';end if;
  if v_role='contributor' and (task.assignee_id is distinct from p_actor or p_data - array['id','version','status']<>'{}'::jsonb) then raise exception 'Assigned status updates only' using errcode='42501';end if;
  person:=case when p_data?'assigneeId' then nullif(p_data->>'assigneeId','')::uuid else task.assignee_id end;
  if person is not null and not exists(select 1 from public.project_memberships m join public.profiles u on u.id=m.user_id and u.status='active' where m.project_id=p.id and m.user_id=person and m.status='active' and m.role in ('manager','contributor')) then raise exception 'Assignee unavailable' using errcode='22023';end if;
  new_status:=coalesce(p_data->>'status',task.status);
  if new_status<>task.status and not ((task.status='todo' and new_status in ('in_progress','cancelled')) or (task.status='in_progress' and new_status in ('todo','blocked','in_review')) or (task.status='blocked' and new_status in ('todo','in_progress','cancelled')) or (task.status='in_review' and new_status in ('in_progress','done')) or (task.status in ('done','cancelled') and v_role='manager' and new_status='todo')) then raise exception 'Invalid task transition' using errcode='22023';end if;
  update public.project_tasks set title=coalesce(p_data->>'title',title),description=coalesce(p_data->>'description',description),status=new_status,assignee_id=person,priority=coalesce(p_data->>'priority',priority),due_on=case when p_data?'dueOn' then nullif(p_data->>'dueOn','')::date else due_on end,milestone_id=case when p_data?'milestoneId' then nullif(p_data->>'milestoneId','')::uuid else milestone_id end,shared=coalesce((p_data->>'shared')::boolean,shared) where id=entity;
  select shared into v_shared from public.project_tasks where id=entity;
 elsif p_action='comment.create' then
  if v_role='contributor' then v_shared:=false;end if;
  insert into public.project_comments(id,project_id,task_id,actor_id,body,shared) values(entity,p.id,nullif(p_data->>'taskId','')::uuid,p_actor,p_data->>'body',v_shared);
 elsif p_action='deliverable.create' then
  insert into public.project_deliverables(id,project_id,task_id,actor_id,title,url,shared) values(entity,p.id,nullif(p_data->>'taskId','')::uuid,p_actor,p_data->>'title',p_data->>'url',v_shared);
 else raise exception 'Invalid project action' using errcode='22023';end if;
 update public.projects set version=version+1,updated_at=now() where id=p.id returning version into p.version;
 insert into public.project_activity(project_id,actor_id,action,entity_id,summary,shared) values(p.id,p_actor,p_action,entity,v_title,v_shared);
 insert into public.audit_logs(actor_user_id,organization_id,action,target_type,target_id,details) values(p_actor,p.customer_organization_id,'project.'||p_action,'project',p.id::text,jsonb_build_object('entity_id',entity,'version',p.version));
 return jsonb_build_object('id',entity,'version',p.version);
end$$;
revoke all on function public.project_command(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.project_command(uuid,text,uuid,jsonb) to service_role;

-- Feedback #5: project overview extras. Additive only; existing project keys, UUIDs and tasks are unchanged.
-- No destructive data migration or automatic modification of existing projects.
create table public.project_checklist_items (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  milestone_id uuid not null,
  title text not null check (length(btrim(title)) between 1 and 180),
  completed boolean not null default false,
  completed_at timestamptz,
  completed_by uuid references public.profiles(id),
  created_by uuid not null references public.profiles(id),
  assignee_id uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  constraint project_checklist_milestone foreign key (project_id,milestone_id)
    references public.project_milestones(project_id,id) on delete restrict,
  constraint project_checklist_completed_consistent check (
    (completed and completed_at is not null and completed_by is not null)
    or (not completed and completed_at is null and completed_by is null)
  )
);
create index project_checklist_by_milestone on public.project_checklist_items(project_id,milestone_id,created_at,id);

create table public.project_risks (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  title text not null check (length(btrim(title)) between 1 and 180),
  severity text not null check (severity in ('low','medium','high')),
  status text not null default 'open' check (status in ('open','resolved')),
  owner_id uuid not null references public.profiles(id),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index project_risks_by_project on public.project_risks(project_id,status,created_at desc);

create table public.project_resources (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  label text not null check (length(btrim(label)) between 1 and 120),
  url text not null check (length(url) between 12 and 1000 and url ~ '^https://[^/[:space:]]+'),
  category text not null check (category in ('document','design','repository','deployment','other')),
  shared boolean not null default false,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  archived_at timestamptz
);
create index project_resources_by_project on public.project_resources(project_id,created_at desc) where archived_at is null;

create table public.project_weekly_updates (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  summary text not null check (length(btrim(summary)) between 8 and 2500),
  health text not null check (health in ('on_track','at_risk','off_track')),
  next_steps text not null default '' check (length(next_steps) <= 1500),
  shared boolean not null default false,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);
create index project_weekly_updates_by_project on public.project_weekly_updates(project_id,created_at desc);

alter table public.project_checklist_items enable row level security;
alter table public.project_risks enable row level security;
alter table public.project_resources enable row level security;
alter table public.project_weekly_updates enable row level security;
revoke all on public.project_checklist_items,public.project_risks,public.project_resources,public.project_weekly_updates from public,anon,authenticated;
grant select,insert,update on public.project_checklist_items,public.project_risks,public.project_resources,public.project_weekly_updates to service_role;

create function public.project_workspace_command(
  p_actor uuid,p_action text,p_project uuid,p_data jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  project public.projects; access text; identity public.profiles;
  item public.project_checklist_items; risk public.project_risks;
  entity uuid; change_version integer; title text; target_url text;
  details jsonb;
begin
  if p_project is null or p_action is null or p_action not in (
    'list','checklist.add','checklist.toggle','risk.add','risk.resolve',
    'resource.add','resource.archive','update.publish'
  ) or jsonb_typeof(p_data) is distinct from 'object' then
    raise exception 'Invalid workspace request' using errcode='22023';
  end if;
  select * into identity from public.profiles where id=p_actor and status='active' for share;
  if not found then raise exception 'Active account required' using errcode='42501';end if;
  access:=public.project_permission(p_actor,p_project);
  if access is null then raise exception 'Project unavailable' using errcode='42501';end if;
  if p_action='list' then
    if p_data<>'{}'::jsonb then raise exception 'Unexpected workspace filters' using errcode='22023';end if;
    return jsonb_build_object(
      'checklist',coalesce((select jsonb_agg(
          case when access='client' then
            jsonb_build_object('id',c.id,'milestone_id',c.milestone_id,
              'title',c.title,'completed',c.completed)
          else to_jsonb(c) end
          order by c.created_at,c.id)
        from public.project_checklist_items c join public.project_milestones m on m.id=c.milestone_id
        where c.project_id=p_project and (access<>'client' or m.shared)),'[]'::jsonb),
      'risks',case when access='client' then '[]'::jsonb else
        coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at desc,r.id)
          from (select * from public.project_risks where project_id=p_project order by created_at desc limit 100) r),'[]'::jsonb) end,
      'resources',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id)
        from (select * from public.project_resources where project_id=p_project and archived_at is null
          and (access<>'client' or shared) order by created_at desc limit 100) x),'[]'::jsonb),
      'updates',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id)
        from (select * from public.project_weekly_updates where project_id=p_project
          and (access<>'client' or shared) order by created_at desc limit 30) x),'[]'::jsonb),
      'canManage',access='manager','role',access
    );
  end if;
  select * into project from public.projects where id=p_project for update;
  if not found then raise exception 'Project unavailable' using errcode='42501';end if;
  -- Recompute the role under the project lock. Membership or manager authority
  -- may have changed while the caller was waiting for that lock.
  access:=public.project_permission(p_actor,p_project);
  if access is null then raise exception 'Project unavailable' using errcode='42501';end if;
  if project.status in ('archived','completed') then
    raise exception 'Closed project cannot be edited' using errcode='22023';
  end if;
  if jsonb_typeof(p_data->'version') is distinct from 'number'
     or coalesce(p_data->>'version','') !~ '^[1-9][0-9]{0,8}$' then
    raise exception 'Project version required' using errcode='22023';
  end if;
  change_version:=(p_data->>'version')::integer;
  if change_version<>project.version then
    raise exception 'Project changed; refresh' using errcode='40001';
  end if;
  if access<>'manager' and p_action<>'checklist.toggle' then
    raise exception 'Project manager required' using errcode='42501';
  end if;

  if p_action='checklist.add' then
    if (select count(*) from jsonb_object_keys(p_data))<>4 or
      not(p_data ?& array['version','milestoneId','title','assigneeId']) or
      coalesce(p_data->>'milestoneId','') !~* '^[0-9a-f-]{36}$' then
      raise exception 'Invalid checklist data' using errcode='22023';end if;
    title:=btrim(p_data->>'title');
    if length(title) not between 1 and 180 or title~'[[:cntrl:]]' or
       not exists(select 1 from public.project_milestones m where m.project_id=p_project
         and m.id=(p_data->>'milestoneId')::uuid) or
       (select count(*) from public.project_checklist_items where project_id=p_project)>=500 then
      raise exception 'Checklist item invalid or limit reached' using errcode='22023';end if;
    if p_data->'assigneeId' is distinct from 'null'::jsonb then
      if jsonb_typeof(p_data->'assigneeId') is distinct from 'string'
         or coalesce(p_data->>'assigneeId','') !~*
           '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         or not exists (
           select 1 from public.project_memberships m
           join public.profiles u on u.id=m.user_id and u.status='active'
           where m.project_id=p_project
             and m.user_id=(p_data->>'assigneeId')::uuid
             and m.status='active' and m.role in ('manager','contributor')
         ) then
        raise exception 'Select an eligible project assignee' using errcode='42501';
      end if;
    end if;
    insert into public.project_checklist_items(project_id,milestone_id,title,created_by,assignee_id)
      values(p_project,(p_data->>'milestoneId')::uuid,title,p_actor,
        nullif(p_data->>'assigneeId','')::uuid) returning id into entity;
  elsif p_action='checklist.toggle' then
    if (select count(*) from jsonb_object_keys(p_data))<>3 or
      not(p_data ?& array['version','itemId','completed']) or
      coalesce(p_data->>'itemId','') !~* '^[0-9a-f-]{36}$' or
      jsonb_typeof(p_data->'completed') is distinct from 'boolean' then
      raise exception 'Invalid checklist change' using errcode='22023';end if;
    select * into item from public.project_checklist_items
      where project_id=p_project and id=(p_data->>'itemId')::uuid;
    if not found then raise exception 'Checklist item unavailable' using errcode='42501';end if;
    -- Contributors may complete only explicitly assigned checklist work; managers can review all.
    if access<>'manager' and not (access='contributor' and item.assignee_id=p_actor) then
      raise exception 'Only the assigned employee or project manager may complete the item' using errcode='42501';end if;
    update public.project_checklist_items set completed=(p_data->>'completed')::boolean,
      completed_at=case when (p_data->>'completed')::boolean then clock_timestamp() else null end,
      completed_by=case when (p_data->>'completed')::boolean then p_actor else null end
      where id=item.id returning id into entity;
  elsif p_action='risk.add' then
    if (select count(*) from jsonb_object_keys(p_data))<>3 or
       not(p_data ?& array['version','title','severity']) or
       p_data->>'severity' not in ('low','medium','high') then
       raise exception 'Invalid risk fields' using errcode='22023';end if;
    title:=btrim(p_data->>'title');
    if length(title) not between 1 and 180 or title~'[[:cntrl:]]' or
      (select count(*) from public.project_risks where project_id=p_project)>=100 then
       raise exception 'Risk limit or title invalid' using errcode='22023';end if;
    insert into public.project_risks(project_id,title,severity,owner_id,created_by)
      values(p_project,title,p_data->>'severity',p_actor,p_actor) returning id into entity;
  elsif p_action='risk.resolve' then
    if (select count(*) from jsonb_object_keys(p_data))<>3 or
      not(p_data ?& array['version','id','resolved']) or
      coalesce(p_data->>'id','') !~* '^[0-9a-f-]{36}$' or
      jsonb_typeof(p_data->'resolved') is distinct from 'boolean' then
       raise exception 'Invalid risk change' using errcode='22023';end if;
    update public.project_risks set status=case when (p_data->>'resolved')::boolean then 'resolved' else 'open' end,updated_at=now()
      where project_id=p_project and id=(p_data->>'id')::uuid returning id into entity;
    if not found then raise exception 'Risk unavailable' using errcode='42501';end if;
  elsif p_action='resource.add' then
    if (select count(*) from jsonb_object_keys(p_data))<>5 or
       not(p_data ?& array['version','label','url','category','shared']) or
       p_data->>'category' not in ('document','design','repository','deployment','other') or
       jsonb_typeof(p_data->'shared') is distinct from 'boolean' then
       raise exception 'Invalid resource data' using errcode='22023';end if;
    title:=btrim(p_data->>'label');target_url:=p_data->>'url';
    if length(title) not between 1 and 120 or title~'[[:cntrl:]]' or
      length(target_url) not between 12 and 1000 or
      target_url !~ '^https://[A-Za-z0-9.-]+(?::[0-9]{1,5})?(/[A-Za-z0-9._~%/?#=&-]*)?$' or
      (select count(*) from public.project_resources where project_id=p_project and archived_at is null)>=100 then
       raise exception 'Resource invalid or limit reached' using errcode='22023';end if;
    insert into public.project_resources(project_id,label,url,category,shared,created_by)
      values(p_project,title,target_url,p_data->>'category',(p_data->>'shared')::boolean,p_actor) returning id into entity;
  elsif p_action='resource.archive' then
    if (select count(*) from jsonb_object_keys(p_data))<>2 or
      not(p_data ?& array['version','id']) or
      coalesce(p_data->>'id','') !~* '^[0-9a-f-]{36}$' then
       raise exception 'Invalid resource removal' using errcode='22023';end if;
    update public.project_resources set archived_at=now()
      where id=(p_data->>'id')::uuid and project_id=p_project and archived_at is null returning id into entity;
    if not found then raise exception 'Resource unavailable' using errcode='42501';end if;
  elsif p_action='update.publish' then
    if (select count(*) from jsonb_object_keys(p_data))<>5 or
      not(p_data ?& array['version','summary','health','nextSteps','shared']) or
      p_data->>'health' not in ('on_track','at_risk','off_track') or
      jsonb_typeof(p_data->'shared') is distinct from 'boolean' then
       raise exception 'Invalid update' using errcode='22023';end if;
    title:=btrim(p_data->>'summary');
    if length(title) not between 8 and 2500 or title~'[[:cntrl:]]' or
      length(coalesce(p_data->>'nextSteps',''))>1500 or
      (select count(*) from public.project_weekly_updates where project_id=p_project)>=1000 then
       raise exception 'Update invalid or limit reached' using errcode='22023';end if;
    insert into public.project_weekly_updates(project_id,summary,health,next_steps,shared,created_by)
      values(p_project,title,p_data->>'health',coalesce(p_data->>'nextSteps',''),(p_data->>'shared')::boolean,p_actor)
      returning id into entity;
  end if;
  update public.projects set version=version+1,updated_at=now()
    where id=p_project returning version into change_version;
  insert into public.project_activity(project_id,actor_id,action,entity_id,summary,shared)
    values(p_project,p_actor,'workspace.'||p_action,entity,coalesce(title,p_action),false);
  insert into public.audit_logs(actor_user_id,organization_id,action,target_type,target_id,details)
    values(p_actor,project.customer_organization_id,'project.workspace.'||p_action,
      'project',p_project::text,jsonb_build_object('entity_id',entity,'version',change_version));
  return jsonb_build_object('id',entity,'version',change_version);
end$$;
revoke all on function public.project_workspace_command(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.project_workspace_command(uuid,text,uuid,jsonb) to service_role;

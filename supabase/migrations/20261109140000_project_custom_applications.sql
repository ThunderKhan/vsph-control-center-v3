-- Project-owned custom application metadata; reusable catalog products remain separate.
-- Additive, no existing tenant or product rows are modified. Source-only until reviewed installation.
create table public.project_custom_applications(
 id uuid primary key default gen_random_uuid(),
 project_id uuid not null references public.projects(id),
 name text not null check(length(btrim(name)) between 1 and 150),
 description text not null default '' check(length(description)<=2000),
 status text not null default 'planned' check(status in ('planned','building','testing','live','paused','retired')),
 repository_url text not null default '' check(length(repository_url)<=1000),
 deployment_url text not null default '' check(length(deployment_url)<=1000),
 shared boolean not null default false,
 created_by uuid not null references public.profiles(id),
 version integer not null default 1 check(version between 1 and 2147483646),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(project_id,id),
 check(repository_url='' or repository_url ~ '^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/%-]*)?$'),
 check(deployment_url='' or deployment_url ~ '^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/%-]*)?$')
);
create index project_custom_applications_project_idx on public.project_custom_applications(project_id,created_at,id);
alter table public.project_custom_applications enable row level security;
revoke all on public.project_custom_applications from public,anon,authenticated;
grant select,insert,update on public.project_custom_applications to service_role;

create function public.project_custom_application_command(
 p_actor uuid,p_action text,p_project uuid,p_id uuid default null,p_data jsonb default '{}'
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
 p public.projects;
 a public.project_custom_applications;
 role_name text;
 key_name text;
 data_keys integer;
 response jsonb;
begin
 if p_project is null or p_action not in ('list','create','update') or
    jsonb_typeof(p_data) is distinct from 'object' then
  raise exception 'Invalid project application request' using errcode='22023';
 end if;
 select * into p from public.projects where id=p_project;
 if not found then raise exception 'Project unavailable' using errcode='42501';end if;
 role_name:=public.project_permission(p_actor,p_project);
 if role_name is null then raise exception 'Project unavailable' using errcode='42501';end if;

 if p_action='list' then
  if p_id is not null or p_data<>'{}'::jsonb then
   raise exception 'Invalid application list' using errcode='22023';
  end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at,x.id),'[]'::jsonb)
    into response from (
     select id,name,description,status,
       case when role_name='client' then '' else repository_url end as repository_url,
       deployment_url,shared,version,created_at,updated_at
     from public.project_custom_applications
     where project_id=p_project and (role_name<>'client' or shared)
     order by created_at,id limit 50
    ) x;
  return jsonb_build_object('applications',response,
   'canManage',role_name='manager' and p.status not in ('archived','completed'));
 end if;

 if role_name<>'manager' then raise exception 'Project manager required' using errcode='42501';end if;
 -- Serialize mutations against project archival and membership revocation.
 select * into p from public.projects where id=p_project for update;
 role_name:=public.project_permission(p_actor,p_project);
 if role_name is distinct from 'manager' then
  raise exception 'Project manager required' using errcode='42501';
 end if;
 if p.status in ('completed','archived') then
  raise exception 'Project is closed for changes' using errcode='22023';
 end if;

 data_keys:=(select count(*) from jsonb_object_keys(p_data));
 if data_keys<>(case when p_action='create' then 6 else 7 end) then
  raise exception 'Invalid application fields' using errcode='22023';
 end if;
 for key_name in select jsonb_object_keys(p_data) loop
  if key_name not in ('name','description','status','repositoryUrl','deploymentUrl','shared','version') then
   raise exception 'Unexpected application field' using errcode='22023';
  end if;
 end loop;
 if not (p_data ?& array['name','description','status','repositoryUrl','deploymentUrl','shared']) or
    jsonb_typeof(p_data->'shared') is distinct from 'boolean' or
    jsonb_typeof(p_data->'name') is distinct from 'string' or
    jsonb_typeof(p_data->'description') is distinct from 'string' or
    jsonb_typeof(p_data->'status') is distinct from 'string' or
    jsonb_typeof(p_data->'repositoryUrl') is distinct from 'string' or
    jsonb_typeof(p_data->'deploymentUrl') is distinct from 'string' or
    length(btrim(p_data->>'name')) not between 1 and 150 or
    length(p_data->>'description')>2000 or
    p_data->>'status' not in ('planned','building','testing','live','paused','retired') or
    length(p_data->>'repositoryUrl')>1000 or
    length(p_data->>'deploymentUrl')>1000 then
  raise exception 'Invalid application details' using errcode='22023';
 end if;
 if (p_data->>'repositoryUrl')<>'' and
    (p_data->>'repositoryUrl') !~ '^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/%-]*)?$' then
  raise exception 'Invalid repository URL' using errcode='22023';
 end if;
 if (p_data->>'deploymentUrl')<>'' and
    (p_data->>'deploymentUrl') !~ '^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/%-]*)?$' then
  raise exception 'Invalid deployment URL' using errcode='22023';
 end if;

 if p_action='create' then
  if p_id is not null or p_data?'version' then
   raise exception 'Unexpected application identity' using errcode='22023';
  end if;
  if (select count(*) from public.project_custom_applications where project_id=p_project)>=50 then
   raise exception 'Project application limit reached' using errcode='22023';
  end if;
  insert into public.project_custom_applications(
   project_id,name,description,status,repository_url,deployment_url,shared,created_by)
  values(p_project,btrim(p_data->>'name'),p_data->>'description',
   p_data->>'status',p_data->>'repositoryUrl',p_data->>'deploymentUrl',
   (p_data->>'shared')::boolean,p_actor)
  returning * into a;
 else
  if p_id is null or jsonb_typeof(p_data->'version') is distinct from 'number' or
     (p_data->>'version') !~ '^[1-9][0-9]{0,8}$' then
   raise exception 'Invalid application version' using errcode='22023';
  end if;
  select * into a from public.project_custom_applications
   where id=p_id and project_id=p_project for update;
  if not found then raise exception 'Application unavailable' using errcode='42501';end if;
  if a.version<>(p_data->>'version')::integer then
   raise exception 'Application changed' using errcode='40001';
  end if;
  update public.project_custom_applications
  set name=btrim(p_data->>'name'),description=p_data->>'description',
      status=p_data->>'status',repository_url=p_data->>'repositoryUrl',
      deployment_url=p_data->>'deploymentUrl',shared=(p_data->>'shared')::boolean,
      version=version+1,updated_at=now()
  where id=a.id returning * into a;
 end if;
 insert into public.project_activity(project_id,actor_id,action,entity_id,summary,shared)
 values(p_project,p_actor,'custom_application.'||p_action,a.id,a.name,a.shared);
 insert into public.audit_logs(actor_user_id,organization_id,action,target_type,target_id,details)
 values(p_actor,p.customer_organization_id,'custom_application.'||p_action,
        'project_custom_application',a.id::text,
        jsonb_build_object('projectId',p_project,'status',a.status,'shared',a.shared));
 return to_jsonb(a)-'created_by'-'project_id';
end $$;
revoke all on function public.project_custom_application_command(uuid,text,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.project_custom_application_command(uuid,text,uuid,uuid,jsonb) to service_role;

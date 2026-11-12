-- Feedback 02–04: atomically appointed project manager, guarded project lifecycle,
-- owner-reviewed employee restoration. No existing records are mutated by install.
-- Browser roles may not call any of these functions or read the restore ledger.

create table public.internal_employee_restoration_events(
 id uuid primary key default gen_random_uuid(),
 employee_id uuid not null references public.internal_employees(id),
 removed_at timestamptz not null,
 removed_by uuid not null references public.profiles(id),
 removal_reason text not null,
 restored_at timestamptz not null default clock_timestamp(),
 restored_by uuid not null references public.profiles(id),
 restoration_reason text not null,
 version_after integer not null check(version_after>0)
);
create index internal_employee_restoration_events_employee on public.internal_employee_restoration_events(employee_id,restored_at desc);
alter table public.internal_employee_restoration_events enable row level security;
revoke all on public.internal_employee_restoration_events from public,anon,authenticated;
grant select,insert on public.internal_employee_restoration_events to service_role;

-- Allow exactly a reviewed owner restoration; an ordinary roster update still
-- cannot clear removal metadata, re-enable employee access or revive HR authority.
create or replace function public.internal_employee_removed_guard()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if old.removed_at is not null and not (
   coalesce(current_setting('vsph.employee_restore_id',true),'')=old.id::text
   and new.removed_at is null and new.removed_by is null and new.removal_reason is null
   and new.status='onboarding' and new.version=old.version+1
   and new.id=old.id and new.email=old.email
   and new.created_by=old.created_by and new.created_at=old.created_at
 ) then
   raise exception 'Archived employee can only be restored through the owner-reviewed workflow'
     using errcode='42501';
 end if;
 return new;
end $$;
revoke all on function public.internal_employee_removed_guard() from public,anon,authenticated;

create function public.internal_employee_rehire_command(
 p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
 actor public.profiles; employee public.internal_employees;
 reason text; record_version integer; affected integer;
 old_removed_at timestamptz; old_removed_by uuid; old_removal_reason text;
 prior_user uuid;
begin
 select * into actor from public.profiles where id=p_actor and status='active' for share;
 if not found or actor.platform_role<>'super_admin' then
  raise exception 'Platform owner required for archived employee review' using errcode='42501';
 end if;
 if jsonb_typeof(p_data) is distinct from 'object'
   or p_action is null or p_action not in('lookup','list','restore') then
  raise exception 'Invalid restoration request' using errcode='22023';
 end if;
 if p_action='lookup' then
  if p_id is not null or (select count(*) from jsonb_object_keys(p_data))<>1 or
     jsonb_typeof(p_data->'email') is distinct from 'string' or
     length(p_data->>'email') not between 3 and 254 then
   raise exception 'Invalid employee lookup' using errcode='22023'; end if;
  return jsonb_build_object('employee',
    (select jsonb_build_object('id',id,'email',email,'fullName',full_name,
      'version',version,'archived',removed_at is not null,'status',status)
     from public.internal_employees
     where lower(email)=lower(btrim(p_data->>'email')) limit 1));
 end if;
 if p_action='list' then
  if p_id is not null or p_data<>'{}'::jsonb then
   raise exception 'Invalid archived employee listing' using errcode='22023';end if;
  return jsonb_build_object('employees',coalesce((
   select jsonb_agg(to_jsonb(x) order by x.removed_at desc,x.id)
   from (select id,full_name,email,department,job_title,version,removed_at,removal_reason
         from public.internal_employees where removed_at is not null
         order by removed_at desc,id limit 100) x),'[]'::jsonb));
 end if;
 if p_id is null or (select count(*) from jsonb_object_keys(p_data))<>3 or
   not(p_data ?& array['version','reason','confirmed']) or
   p_data->'confirmed' is distinct from 'true'::jsonb or
   jsonb_typeof(p_data->'version') is distinct from 'number' or
   coalesce(p_data->>'version','') !~ '^[1-9][0-9]{0,8}$' then
  raise exception 'Confirm a current archived employee version' using errcode='22023'; end if;
 reason:=btrim(p_data->>'reason');
 if reason is null or length(reason) not between 8 and 500 or reason~'[[:cntrl:]]' then
  raise exception 'Restoration reason must contain 8–500 printable characters' using errcode='22023';end if;
 record_version:=(p_data->>'version')::integer;
 -- The immutable employee ID and email are deliberately reused; no new
 -- Auth identity or access token is created by this operation.
 select * into employee from public.internal_employees where id=p_id for update;
 if not found or employee.removed_at is null then
  raise exception 'Archived employee unavailable' using errcode='P0002';end if;
 if employee.version<>record_version then
  raise exception 'Employee changed: refresh before restoring' using errcode='40001';end if;
 if exists(select 1 from public.profiles where email=employee.email and platform_role='super_admin') then
  raise exception 'Owner employment record requires separate security review' using errcode='42501';end if;
 old_removed_at:=employee.removed_at;
 old_removed_by:=employee.removed_by;
 old_removal_reason:=employee.removal_reason;
 -- Once restored, a stale accepted consent link must never resurrect old
 -- employee or project permissions without renewed approval.
 select user_id into prior_user from public.internal_employee_identity_links where employee_id=p_id;
 update public.internal_employee_identity_links
 set status='revoked',revoked_at=coalesce(revoked_at,clock_timestamp()),version=version+1
 where employee_id=p_id and status='linked';
 update public.internal_employee_link_requests
 set state='cancelled',version=version+1
 where employee_id=p_id and state='pending';
 update public.internal_employee_enrollments
 set state='cancelled',version=version+1
 where employee_id=p_id and state in('provisioning','ready');
 delete from public.internal_hr_managers where employee_id=p_id;
 if prior_user is not null then
  if exists(select 1 from public.projects where owner_id=prior_user and status not in('archived','completed')) then
   raise exception 'Transfer open project ownership before employee restoration' using errcode='42501';end if;
  -- Project employment allocations are revoked; customer-client roles are
  -- a separate tenancy relationship and must never be erased here.
  update public.project_memberships set status='revoked'
   where user_id=prior_user and status='active'
     and role in ('manager','contributor','viewer');
 end if;
 -- The trigger permits only this strict, transaction-local transition.
 perform set_config('vsph.employee_restore_id',p_id::text,true);
 update public.internal_employees
 set status='onboarding',removed_at=null,removed_by=null,removal_reason=null,
   version=version+1,updated_at=clock_timestamp(),updated_by=p_actor
 where id=p_id returning * into employee;
 perform set_config('vsph.employee_restore_id','',true);
 insert into public.internal_employee_restoration_events(
  employee_id,removed_at,removed_by,removal_reason,restored_by,restoration_reason,version_after
 ) values(p_id,old_removed_at,old_removed_by,old_removal_reason,p_actor,reason,employee.version);
 insert into public.audit_logs(actor_user_id,action,target_type,target_id,details)
 values(p_actor,'employee.restored','internal_employee',p_id::text,
  jsonb_build_object('archivedAt',old_removed_at,'reason',reason,
    'version',employee.version,'accessRestored',false));
 return jsonb_build_object('id',employee.id,'version',employee.version,
   'status','onboarding','accessRestored',false,'requiresNewConsent',true);
end $$;
revoke all on function public.internal_employee_rehire_command(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.internal_employee_rehire_command(uuid,text,uuid,jsonb) to service_role;

-- A project owner may atomically create a project and appoint an eligible
-- project manager. HR status alone never authorizes appointments.
create function public.project_creation_command(
 p_actor uuid,p_action text,p_data jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor public.profiles; result jsonb; manager uuid; chosen text;
begin
 select * into actor from public.profiles where id=p_actor and status='active' for share;
 if not found or actor.platform_role<>'super_admin' then
  raise exception 'Platform owner required' using errcode='42501';end if;
 if jsonb_typeof(p_data) is distinct from 'object' or p_action is null or p_action not in('managers','create') then
  raise exception 'Invalid project creation command' using errcode='22023';end if;
 if p_action='managers' then
  if p_data<>'{}'::jsonb then raise exception 'Unexpected search fields' using errcode='22023';end if;
  return jsonb_build_object('managers',coalesce((
   select jsonb_agg(to_jsonb(x) order by x.full_name,x.id)
   from (select u.id,u.full_name,e.department,e.job_title
     from public.internal_employee_identity_links l
     join public.internal_employees e on e.id=l.employee_id and e.status='active'
      and e.removed_at is null
     join public.profiles u on u.id=l.user_id and u.status='active' and u.email=e.email
     where l.status='linked'
       and not exists(select 1 from public.organization_memberships m where m.user_id=u.id)
     order by u.full_name,u.id limit 200) x),'[]'::jsonb));
 end if;
 if not (p_data ? 'managerUserId') or
   jsonb_typeof(p_data->'managerUserId') is distinct from 'string' then
  raise exception 'Manager choice required' using errcode='22023';end if;
 chosen:=p_data->>'managerUserId';
 if chosen<>'' then
  if chosen !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception 'Invalid project manager' using errcode='22023';end if;
  manager:=chosen::uuid;
  if manager=p_actor or not exists(
   select 1 from public.internal_employee_identity_links l
   join public.internal_employees e on e.id=l.employee_id and e.status='active' and e.removed_at is null
   join public.profiles u on u.id=l.user_id and u.email=e.email and u.status='active'
   where l.user_id=manager and l.status='linked'
    and not exists(select 1 from public.organization_memberships m where m.user_id=manager)
  ) then raise exception 'Select an eligible active internal employee to manage this project'
   using errcode='42501';end if;
 end if;
 result:=public.project_command(p_actor,'create',null,p_data-'managerUserId');
 if manager is not null then
  perform public.project_workforce_command(p_actor,'manager.grant',(result->>'id')::uuid,
   jsonb_build_object('version',(result->>'version')::integer,'userId',manager));
  select to_jsonb(x) into result from public.projects x where id=(result->>'id')::uuid;
 end if;
 return result;
end $$;
revoke all on function public.project_creation_command(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.project_creation_command(uuid,text,jsonb) to service_role;

-- Delete is owner-only, requires an archived project and a matching key.
-- Safely delete only metadata-only projects: any meaningful linked project or
-- financial activity causes a transaction-wide refusal, preserving history.
create function public.project_lifecycle_command(
 p_actor uuid,p_action text,p_project uuid,p_data jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
 actor public.profiles; project public.projects; dependency record;
 occupied boolean; new_data jsonb;
begin
 select * into actor from public.profiles where id=p_actor and status='active' for share;
 if not found or actor.platform_role<>'super_admin' then
  raise exception 'Only the platform owner may archive or delete projects' using errcode='42501';end if;
 if p_action is null or p_action not in('archive','delete') or p_project is null or
   jsonb_typeof(p_data) is distinct from 'object' or (select count(*) from jsonb_object_keys(p_data))<>3 or
   not (p_data ?& array['version','key','confirmed']) or
   p_data->'confirmed' is distinct from 'true'::jsonb or
   jsonb_typeof(p_data->'version') is distinct from 'number' or
   coalesce(p_data->>'version','')!~'^[1-9][0-9]{0,8}$' then
  raise exception 'Confirm project key and current version' using errcode='22023';end if;
 select * into project from public.projects where id=p_project for update;
 if not found then raise exception 'Project unavailable' using errcode='P0002';end if;
 if project.version<>(p_data->>'version')::integer then
  raise exception 'Project changed; refresh before continuing' using errcode='40001';end if;
 if project.key is distinct from p_data->>'key' then
  raise exception 'Project key confirmation does not match' using errcode='22023';end if;
 if p_action='archive' then
  if project.status='archived' then raise exception 'Already archived' using errcode='22023';end if;
  new_data:=public.project_command(p_actor,'update',p_project,jsonb_build_object(
    'version',project.version,'status','archived'));
  insert into public.audit_logs(actor_user_id,organization_id,action,target_type,target_id,details)
   values(p_actor,project.customer_organization_id,'project.archived','project',project.id::text,
     jsonb_build_object('key',project.key));
  return jsonb_build_object('archived',true,'id',project.id);
 end if;
 if project.status<>'archived' then
  raise exception 'Archive the project before permanent deletion' using errcode='22023';end if;
 -- Discover all current direct database references, including future
 -- components (e.g. checklist, resources). Never silently cascade them.
 for dependency in
  select ns.nspname as table_schema, rel.relname as table_name,
    a.attname as column_name
  from pg_catalog.pg_constraint c
  join pg_catalog.pg_class rel on rel.oid=c.conrelid
  join pg_catalog.pg_namespace ns on ns.oid=rel.relnamespace
  join pg_catalog.pg_attribute a on a.attrelid=c.conrelid and a.attnum=c.conkey[1]
  where c.contype='f' and c.confrelid='public.projects'::regclass
    and array_length(c.conkey,1)=1
  order by ns.nspname,rel.relname
 loop
  if dependency.table_schema='public' and
      dependency.table_name not in('project_memberships','project_activity','project_products') then
   execute format('select exists(select 1 from %I.%I where %I=$1)',
     dependency.table_schema,dependency.table_name,dependency.column_name)
     into occupied using p_project;
   if occupied then
    raise exception 'Project has retained work, customer or financial records; archive it instead of deleting'
      using errcode='23503';
   end if;
  elsif dependency.table_schema<>'public' then
   raise exception 'Project has a reference in another schema; manual review required'
    using errcode='23503';
  end if;
 end loop;
 delete from public.project_products where project_id=p_project;
 delete from public.project_activity where project_id=p_project;
 delete from public.project_memberships where project_id=p_project;
 delete from public.projects where id=p_project;
 insert into public.audit_logs(actor_user_id,organization_id,action,target_type,target_id,details)
 values(p_actor,project.customer_organization_id,'project.permanently_deleted','project',p_project::text,
   jsonb_build_object('key',project.key,'name',project.name,'emptyProject',true));
 return jsonb_build_object('deleted',true,'id',p_project,'key',project.key);
end $$;
revoke all on function public.project_lifecycle_command(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.project_lifecycle_command(uuid,text,uuid,jsonb) to service_role;

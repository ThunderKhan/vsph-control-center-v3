-- Internal VSPH workforce registry. Separate from tenant members and product roles.
-- No identity creation, invitations, email delivery, payroll, or project permissions.
create table public.internal_employees (
 id uuid primary key default gen_random_uuid(),
 idempotency_key uuid not null unique,
 request_hash text not null check (request_hash ~ '^[0-9a-f]{32}$'),
 full_name text not null check (length(btrim(full_name)) between 1 and 150),
 email text not null unique check(email=lower(email) and length(email)<=190),
 department text not null check(length(btrim(department)) between 1 and 100),
 job_title text not null check(length(btrim(job_title)) between 1 and 120),
 employment_type text not null check(employment_type in ('full_time','part_time','intern','contract')),
 start_date date not null,
 status text not null default 'onboarding' check(status in ('onboarding','active','on_leave','inactive')),
 version integer not null default 1 check(version>0),
 created_by uuid not null references public.profiles(id),
 updated_by uuid not null references public.profiles(id),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create index internal_employees_status on public.internal_employees(status,id);
create index internal_employees_department on public.internal_employees(department,id);
alter table public.internal_employees enable row level security;
revoke all on public.internal_employees from public,anon,authenticated;
grant select,insert,update,delete on public.internal_employees to service_role;

-- HR authority is explicitly granted by the platform owner to an EXISTING
-- active portal identity whose email matches an active staff roster entry.
create table public.internal_hr_managers(
 employee_id uuid primary key references public.internal_employees(id) on delete restrict,
 user_id uuid not null unique references public.profiles(id) on delete restrict,
 granted_by uuid not null references public.profiles(id),
 granted_at timestamptz not null default now()
);
alter table public.internal_hr_managers enable row level security;
revoke all on public.internal_hr_managers from public,anon,authenticated;
grant select,insert,update,delete on public.internal_hr_managers to service_role;

create function public.internal_employee_command(
 p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}'
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
 actor public.profiles;
 target public.internal_employees;
 matching_user public.profiles;
 owner_mode boolean;
 hr_authority boolean;
 incoming text;
 normalized_email text;
 rows_data jsonb;
 counts_data jsonb;
 department_data jsonb;
 managers_data jsonb;
 request_digest text;
 changed integer;
begin
 if p_action not in ('access','list','create','update','grant_hr','revoke_hr')
    or jsonb_typeof(p_data) is distinct from 'object' then
  raise exception 'Invalid workforce command' using errcode='22023';
 end if;
 -- Use the current server-owned session actor, not browser-supplied roles.
 -- Acquiring a profile share lock fences concurrent profile deactivation.
 select * into actor from public.profiles where id=p_actor and status='active' for share;
 if not found then raise exception 'Active portal identity required' using errcode='42501';end if;
 owner_mode := actor.platform_role='super_admin';
 hr_authority := false;
 if not owner_mode then
  -- Lock HR assignment so owner revocation cannot race an in-flight edit.
  perform 1 from public.internal_hr_managers m
   join public.internal_employees e on e.id=m.employee_id
   where m.user_id=p_actor and e.email=actor.email and e.status='active'
   for share of m,e;
  hr_authority:=found;
 end if;
 if not (owner_mode or hr_authority) then
  raise exception 'VSPH owner or current HR manager required' using errcode='42501';
 end if;

 if p_action='access' then
  if p_data<>'{}'::jsonb or p_id is not null then raise exception 'Invalid access fields' using errcode='22023';end if;
  return jsonb_build_object('role',case when owner_mode then 'owner' else 'hr' end,
    'canManageHr',owner_mode);
 end if;

 if p_action='list' then
  if p_id is not null or exists(select 1 from jsonb_object_keys(p_data) k
   where k not in ('afterId','status','search')) then raise exception 'Invalid directory fields' using errcode='22023';end if;
  if length(coalesce(p_data->>'search',''))>80
   or (p_data ? 'status' and p_data->>'status' not in ('all','onboarding','active','on_leave','inactive')) then
   raise exception 'Invalid directory filter' using errcode='22023';end if;
  incoming:=lower(btrim(coalesce(p_data->>'search','')));
  select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]'::jsonb) into rows_data
  from(
    select e.id,e.full_name,e.email,e.department,e.job_title,e.employment_type,
      e.start_date,e.status,e.version,e.created_at,e.updated_at,
      exists(select 1 from public.internal_hr_managers h where h.employee_id=e.id) is_hr
    from public.internal_employees e
    where (p_data->>'afterId' is null or e.id>(p_data->>'afterId')::uuid)
     and (coalesce(p_data->>'status','all')='all' or e.status=p_data->>'status')
     and (incoming='' or position(incoming in lower(e.full_name||' '||e.email||' '||e.department||' '||e.job_title))>0)
    order by e.id limit 51
  ) x;
  select jsonb_build_object(
    'total',count(*),'active',count(*) filter(where status='active'),
    'onboarding',count(*) filter(where status='onboarding'),
    'onLeave',count(*) filter(where status='on_leave'),
    'inactive',count(*) filter(where status='inactive'),
    'hrManagers',(select count(*) from public.internal_hr_managers)
  ) into counts_data from public.internal_employees;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.members desc,x.department),'[]'::jsonb)
   into department_data from(
    select department,count(*) members from public.internal_employees
    where status in ('active','on_leave')
    group by department order by count(*) desc,department limit 10
   ) x;
  managers_data:='[]'::jsonb;
  if owner_mode then
   select coalesce(jsonb_agg(to_jsonb(x) order by x.full_name),'[]'::jsonb)
    into managers_data from(
     select m.employee_id,m.user_id,e.full_name,e.email,e.status,p.status account_status,
      e.version
     from public.internal_hr_managers m
     join public.internal_employees e on e.id=m.employee_id
     join public.profiles p on p.id=m.user_id
     order by e.full_name limit 100
    ) x;
  end if;
  return jsonb_build_object('role',case when owner_mode then 'owner' else 'hr' end,
   'canManageHr',owner_mode,'employees',rows_data,'counts',counts_data,
   'departments',department_data,'hrManagers',managers_data);
 end if;

 if p_action='create' then
  if p_id is null or exists(select 1 from jsonb_object_keys(p_data) k where k not in
    ('fullName','email','department','jobTitle','employmentType','startDate'))
    or (select count(*) from jsonb_object_keys(p_data))<>6 then
   raise exception 'Invalid onboarding fields or idempotency key' using errcode='22023';
  end if;
  incoming:=btrim(p_data->>'fullName');
  normalized_email:=lower(btrim(p_data->>'email'));
  if length(incoming) not between 1 and 150 or incoming~'[[:cntrl:]]'
   or length(normalized_email)>190 or normalized_email!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
   or length(btrim(coalesce(p_data->>'department',''))) not between 1 and 100
   or btrim(p_data->>'department')~'[[:cntrl:]]'
   or length(btrim(coalesce(p_data->>'jobTitle',''))) not between 1 and 120
   or btrim(p_data->>'jobTitle')~'[[:cntrl:]]'
   or p_data->>'employmentType' not in ('full_time','part_time','intern','contract')
   or coalesce(p_data->>'startDate','')!~'^\d{4}-\d{2}-\d{2}$' then
    raise exception 'Invalid employee fields' using errcode='22023';
  end if;
  -- A client-generated key allows safe retries after network loss.
  request_digest:=md5(jsonb_build_object('fullName',incoming,'email',normalized_email,
   'department',btrim(p_data->>'department'),'jobTitle',btrim(p_data->>'jobTitle'),
   'employmentType',p_data->>'employmentType','startDate',p_data->>'startDate')::text);
  perform pg_advisory_xact_lock(hashtextextended('staff:'||p_actor::text||p_id::text,0));
  select * into target from public.internal_employees where idempotency_key=p_id for update;
  if found then
   if target.request_hash<>request_digest then raise exception 'Idempotency key changed' using errcode='23505';end if;
   return jsonb_build_object('id',target.id,'status',target.status,'version',target.version,'replayed',true);
  end if;
  insert into public.internal_employees(idempotency_key,request_hash,full_name,email,
   department,job_title,employment_type,start_date,created_by,updated_by)
  values(p_id,request_digest,incoming,normalized_email,btrim(p_data->>'department'),
   btrim(p_data->>'jobTitle'),p_data->>'employmentType',(p_data->>'startDate')::date,p_actor,p_actor)
  returning * into target;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,details)
   values(p_actor,'employee.created','internal_employee',target.id::text,
    jsonb_build_object('status','onboarding','department',target.department));
  return jsonb_build_object('id',target.id,'status',target.status,'version',target.version,'replayed',false);
 end if;

 if p_id is null or p_data->'confirmed' is distinct from 'true'::jsonb
    or (p_data->>'version')::integer is null then
  raise exception 'Review and confirm a current employee version' using errcode='22023';
 end if;
 -- SQL compares versions under a row lock, not in the browser.
 select * into target from public.internal_employees where id=p_id for update;
 if not found then raise exception 'Employee not found' using errcode='P0002';end if;
 if (p_data->>'version')::integer is distinct from target.version then
  raise exception 'Stale employee; reload' using errcode='40001';end if;
 -- HR cannot alter anyone assigned HR privileges or a platform owner.
 if not owner_mode and (
  exists(select 1 from public.internal_hr_managers where employee_id=p_id)
  or exists(select 1 from public.profiles where email=target.email and platform_role='super_admin')
 ) then raise exception 'Only the platform owner may manage this record' using errcode='42501';end if;

 if p_action='update' then
  if exists(select 1 from jsonb_object_keys(p_data) k where k not in
    ('version','confirmed','fullName','department','jobTitle','employmentType','startDate','status'))
   or (select count(*) from jsonb_object_keys(p_data))<>8 then
   raise exception 'Invalid employee edit fields' using errcode='22023';end if;
  incoming:=btrim(p_data->>'fullName');
  if length(incoming) not between 1 and 150 or incoming~'[[:cntrl:]]'
   or length(btrim(coalesce(p_data->>'department',''))) not between 1 and 100
   or btrim(p_data->>'department')~'[[:cntrl:]]'
   or length(btrim(coalesce(p_data->>'jobTitle',''))) not between 1 and 120
   or btrim(p_data->>'jobTitle')~'[[:cntrl:]]'
   or p_data->>'employmentType' not in ('full_time','part_time','intern','contract')
   or p_data->>'status' not in ('onboarding','active','on_leave','inactive')
   or coalesce(p_data->>'startDate','')!~'^\d{4}-\d{2}-\d{2}$' then
   raise exception 'Invalid employee edit fields' using errcode='22023';end if;
  -- When a previously authorized HR employee leaves, revoke HR authority
  -- atomically. This does not disable an unrelated portal/customer account.
  if p_data->>'status'='inactive' then
   delete from public.internal_hr_managers where employee_id=p_id;
  end if;
  update public.internal_employees set full_name=incoming,
   department=btrim(p_data->>'department'),job_title=btrim(p_data->>'jobTitle'),
   employment_type=p_data->>'employmentType',start_date=(p_data->>'startDate')::date,
   status=p_data->>'status',version=version+1,updated_by=p_actor,updated_at=now()
   where id=p_id returning * into target;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,details)
   values(p_actor,'employee.updated','internal_employee',target.id::text,
   jsonb_build_object('version',target.version,'status',target.status,'department',target.department));
  return jsonb_build_object('id',target.id,'status',target.status,'version',target.version);
 end if;

 if not owner_mode then raise exception 'Only the platform owner can manage HR authority' using errcode='42501';end if;
 if exists(select 1 from jsonb_object_keys(p_data) k where k not in ('version','confirmed'))
    or (select count(*) from jsonb_object_keys(p_data))<>2 then
  raise exception 'Invalid HR permission request' using errcode='22023';end if;
 if p_action='grant_hr' then
  if target.status<>'active' then raise exception 'Activate the employee roster record first' using errcode='42501';end if;
  select * into matching_user from public.profiles where email=target.email and status='active'
   and platform_role='user' for share;
  if not found then raise exception 'Existing active portal account with matching email required' using errcode='42501';end if;
  if exists(select 1 from public.internal_hr_managers where user_id=matching_user.id or employee_id=p_id) then
    raise exception 'Existing HR mapping requires review' using errcode='23505';end if;
  insert into public.internal_hr_managers(employee_id,user_id,granted_by)
   values(p_id,matching_user.id,p_actor);
  update public.internal_employees set version=version+1,updated_at=now(),updated_by=p_actor where id=p_id returning * into target;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,details)
   values(p_actor,'employee.hr_granted','internal_employee',p_id::text,jsonb_build_object('userId',matching_user.id));
  return jsonb_build_object('id',target.id,'version',target.version,'role','hr');
 end if;
 if p_action='revoke_hr' then
  delete from public.internal_hr_managers where employee_id=p_id;
  get diagnostics changed=row_count;
  if changed<>1 then raise exception 'No current HR assignment' using errcode='40001';end if;
  update public.internal_employees set version=version+1,updated_at=now(),updated_by=p_actor where id=p_id returning * into target;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,details)
   values(p_actor,'employee.hr_revoked','internal_employee',p_id::text,'{}'::jsonb);
  return jsonb_build_object('id',target.id,'version',target.version,'role','employee');
 end if;
 raise exception 'Invalid operation' using errcode='22023';
end;
$$;
revoke all on function public.internal_employee_command(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.internal_employee_command(uuid,text,uuid,jsonb) to service_role;

-- Deactivating a portal identity must permanently revoke its internal HR grant.
-- Re-enabling that identity later needs a fresh owner-approved HR assignment.
-- This trigger executes in the same transaction as profile status governance.
create function public.internal_hr_profile_disabled() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.status='disabled' and old.status is distinct from new.status then
  delete from public.internal_hr_managers where user_id=new.id;
 end if;
 return new;
end;
$$;
revoke all on function public.internal_hr_profile_disabled() from public,anon,authenticated;
grant execute on function public.internal_hr_profile_disabled() to service_role;
create trigger internal_hr_revoke_on_profile_disable
 after update of status on public.profiles
 for each row when (new.status='disabled' and old.status is distinct from new.status)
 execute function public.internal_hr_profile_disabled();

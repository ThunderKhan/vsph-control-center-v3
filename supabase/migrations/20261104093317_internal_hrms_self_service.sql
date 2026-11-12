-- Internal workforce self-service. Customer/product roles never authorize HRMS.
create table public.internal_leave_requests(
 id uuid primary key default gen_random_uuid(),employee_id uuid not null references public.internal_employees(id),
 idempotency_key uuid not null unique,request_hash text not null,
 start_on date not null,end_on date not null,kind text not null check(kind in ('annual','sick','unpaid','other')),
 reason text not null check(length(reason) between 1 and 500),status text not null default 'pending' check(status in ('pending','approved','rejected','cancelled')),
 version integer not null default 1 check(version>0),requested_at timestamptz not null default now(),
 reviewed_by uuid references public.profiles(id),reviewed_at timestamptz,decision_note text not null default '' check(length(decision_note)<=300),
 check(end_on>=start_on and end_on-start_on<=365)
);
create index internal_leave_employee on public.internal_leave_requests(employee_id,id);
create table public.internal_attendance(
 id uuid primary key default gen_random_uuid(),employee_id uuid not null references public.internal_employees(id),
 idempotency_key uuid not null unique,out_key uuid unique,work_day date not null,
 checked_in_at timestamptz not null default clock_timestamp(),checked_out_at timestamptz,
 status text not null default 'open' check(status in ('open','closed','incomplete')),
 version integer not null default 1 check(version>0),recovered_by uuid references public.profiles(id),recovery_note text,
 unique(employee_id,work_day),
 check((status='closed')=(checked_out_at is not null)),check(checked_out_at is null or checked_out_at>=checked_in_at),
 check(status<>'incomplete' or (recovered_by is not null and length(btrim(recovery_note)) between 8 and 300))
);
create unique index internal_attendance_one_open on public.internal_attendance(employee_id) where status='open';
create index internal_attendance_employee on public.internal_attendance(employee_id,work_day desc);
do $$declare t text;begin foreach t in array array['internal_leave_requests','internal_attendance'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('revoke all on public.%I from public,anon,authenticated',t);
 execute format('grant select,insert,update,delete on public.%I to service_role',t);
end loop;end$$;

-- Private guard follows profiles -> portal session -> roster UUIDs -> HR grants.
create function public.internal_hrms_guard(p_actor uuid,p_hash text,p_target uuid default null,p_management boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare own_employee uuid; target_user uuid; authority text;
begin
 select l.employee_id into own_employee from public.internal_employee_identity_links l join public.internal_employees e on e.id=l.employee_id
 join public.profiles p on p.id=l.user_id and p.email=e.email
 where l.user_id=p_actor and l.status='linked' and e.status in ('active','on_leave');
 select user_id into target_user from public.internal_employee_identity_links where employee_id=p_target and status='linked';
 perform 1 from public.profiles where id in (p_actor,target_user) order by case when platform_role='super_admin' then 0 else 1 end,id for share;
 if not exists(select 1 from public.profiles where id=p_actor and status='active') then raise exception 'Current identity required' using errcode='42501';end if;
 perform 1 from public.portal_sessions where user_id=p_actor and token_hash=p_hash and expires_at>clock_timestamp() for share;
 if not found then raise exception 'Current session required' using errcode='42501';end if;
 perform 1 from public.internal_employees where id in (own_employee,p_target) or id in(select employee_id from public.internal_hr_managers where user_id=p_actor) order by id for update;
 perform 1 from public.internal_hr_managers where user_id=p_actor or employee_id=p_target order by employee_id for share;
 if own_employee is not null and not exists(select 1 from public.internal_employee_identity_links l join public.internal_employees e on e.id=l.employee_id
 join public.profiles p on p.id=l.user_id and p.email=e.email where l.employee_id=own_employee and l.user_id=p_actor and l.status='linked' and e.status in ('active','on_leave')) then own_employee:=null;end if;
 authority:=public.internal_workforce_authority(p_actor);
 if p_management then
  if authority is null or (authority='hr' and own_employee is null) then raise exception 'Current HR or owner authority required' using errcode='42501';end if;
  if authority='hr' and p_target is not null and (p_target=own_employee or exists(select 1 from public.internal_hr_managers where employee_id=p_target) or exists(select 1 from public.internal_employees e join public.profiles p on p.email=e.email where e.id=p_target and p.platform_role='super_admin')) then raise exception 'Owner review required for protected staff' using errcode='42501';end if;
 elsif own_employee is null then raise exception 'Accepted active employee identity required' using errcode='42501';end if;
 if not exists(select 1 from public.portal_sessions where user_id=p_actor and token_hash=p_hash and expires_at>clock_timestamp()) then raise exception 'Session expired during operation' using errcode='42501';end if;
 return jsonb_build_object('role',authority,'employeeId',own_employee);
end$$;
revoke all on function public.internal_hrms_guard(uuid,text,uuid,boolean) from public,anon,authenticated,service_role;

create function public.hrms_access(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare employee uuid; authority text;
begin
 if p_action is distinct from 'get' or p_id is not null or jsonb_typeof(p_data) is distinct from 'object' or (select count(*) from jsonb_object_keys(p_data))<>1 or not p_data?'currentHash' then raise exception 'Invalid access query' using errcode='22023';end if;
 perform 1 from public.profiles where id=p_actor and status='active' for share;if not found then raise exception 'Active identity required' using errcode='42501';end if;
 perform 1 from public.portal_sessions where user_id=p_actor and token_hash=p_data->>'currentHash' and expires_at>clock_timestamp() for share;if not found then raise exception 'Current session required' using errcode='42501';end if;
 select l.employee_id into employee from public.internal_employee_identity_links l join public.internal_employees e on e.id=l.employee_id join public.profiles p on p.id=l.user_id and p.email=e.email where l.user_id=p_actor and l.status='linked' and e.status in ('active','on_leave');
 authority:=public.internal_workforce_authority(p_actor);
 return jsonb_build_object('employee',employee is not null,'management',coalesce(authority='owner' or (authority='hr' and employee is not null),false),'governHr',coalesce(authority='owner',false),'pendingLink',exists(select 1 from public.internal_employee_link_requests where candidate_user_id=p_actor and state='pending' and expires_at>clock_timestamp()));
end$$;
revoke all on function public.hrms_access(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.hrms_access(uuid,text,uuid,jsonb) to service_role;

-- Fence basic staff from broad project metadata. Their assigned work uses the
-- separate self-service RPC; explicitly assigned managers keep project powers.
-- A revoked staff link never restores older broad contributor access.
create or replace function public.project_permission(p_actor uuid,p_project uuid) returns text language sql stable security definer set search_path='' as $$
 select case when u.platform_role='super_admin' then 'manager'
  when exists(select 1 from public.internal_employee_link_requests r where r.candidate_user_id=p_actor and r.accepted_at is not null)
   then case when m.role='manager' and exists(select 1 from public.internal_employee_identity_links l join public.internal_employees e on e.id=l.employee_id where l.user_id=p_actor and l.status='linked' and e.status='active' and e.email=u.email) then 'manager' end
  when exists(select 1 from public.organization_memberships where user_id=p_actor)
   then case when p.kind='customer' and p.client_visible and exists(select 1 from public.organization_memberships om join public.organizations org on org.id=om.organization_id and org.status='active' where om.user_id=p_actor and om.organization_id=p.customer_organization_id and om.status='active') then 'client' end
  else m.role end
 from public.projects p join public.profiles u on u.id=p_actor and u.status='active'
 left join public.project_memberships m on m.project_id=p.id and m.user_id=u.id and m.status='active'
 where p.id=p_project and (u.platform_role='super_admin' or (m.role is not null and (m.role<>'client' or (p.client_visible and exists(select 1 from public.organization_memberships om join public.organizations org on org.id=om.organization_id and org.status='active' where om.organization_id=p.customer_organization_id and om.user_id=p_actor and om.status='active')))))
$$;
revoke all on function public.project_permission(uuid,uuid) from public,anon,authenticated;

create function public.internal_self_service(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare authz jsonb; employee uuid; e public.internal_employees; request public.internal_leave_requests; entry public.internal_attendance; task public.project_tasks; project public.projects;
 work_date date:=(clock_timestamp() at time zone 'Asia/Kolkata')::date; digest text; key text; before_status text; result jsonb;
begin
 if p_action is null or p_action not in ('get','task.status','leave.request','leave.cancel','attendance.in','attendance.out') or jsonb_typeof(p_data) is distinct from 'object' then raise exception 'Invalid employee command' using errcode='22023';end if;
 for key in select jsonb_object_keys(p_data) loop
  if key not in (select unnest(case p_action when 'get' then array['currentHash','afterTaskId'] when 'task.status' then array['currentHash','version','status'] when 'leave.request' then array['currentHash','startOn','endOn','kind','reason'] when 'leave.cancel' then array['currentHash','version'] when 'attendance.in' then array['currentHash'] else array['currentHash','version','key'] end)) then raise exception 'Unknown employee field' using errcode='22023';end if;
 end loop;
 authz:=public.internal_hrms_guard(p_actor,p_data->>'currentHash');employee:=(authz->>'employeeId')::uuid;
 select * into e from public.internal_employees where id=employee;
 if p_action='get' then
  if p_id is not null then raise exception 'No employee target allowed' using errcode='22023';end if;
  if p_data?'afterTaskId' and p_data->>'afterTaskId'!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then raise exception 'Invalid task cursor' using errcode='22023';end if;
  return jsonb_build_object('employee',jsonb_build_object('name',e.full_name,'department',e.department,'jobTitle',e.job_title,'status',e.status,'startDate',e.start_date),
   'tasks',coalesce((select jsonb_agg(x order by x.id) from(select t.id,t.title,t.status,t.priority,t.due_on,p.name project_name,p.status project_status,p.version project_version
    from public.project_tasks t join public.projects p on p.id=t.project_id join public.project_memberships m on m.project_id=p.id and m.user_id=p_actor and m.status='active'
    where t.assignee_id=p_actor and m.role in ('manager','contributor') and (p.customer_organization_id is null or exists(select 1 from public.organizations o where o.id=p.customer_organization_id and o.status='active'))
    and (not p_data?'afterTaskId' or t.id>(p_data->>'afterTaskId')::uuid) order by t.id limit 50)x),'[]'),
   'leave',coalesce((select jsonb_agg(x order by x.requested_at desc) from(select id,start_on,end_on,kind,reason,status,version,requested_at,decision_note from public.internal_leave_requests where employee_id=employee order by requested_at desc,id desc limit 25)x),'[]'),
   'attendance',coalesce((select jsonb_agg(x order by x.work_day desc) from(select id,work_day,checked_in_at,checked_out_at,status,version,recovery_note from public.internal_attendance where employee_id=employee order by work_day desc limit 31)x),'[]'),
   'workDate',work_date,'workTimeZone','Asia/Kolkata');
 end if;
 if p_id is null then raise exception 'Operation identifier required' using errcode='22023';end if;
 if p_action in ('task.status','leave.cancel','attendance.out') then
  if jsonb_typeof(p_data->'version') is distinct from 'number' or coalesce(p_data->>'version','')!~'^[1-9][0-9]{0,9}$' or (p_data->>'version')::numeric>2147483646 then raise exception 'Current version required' using errcode='22023';end if;
 end if;
 if p_action='task.status' then
  select p.* into project from public.projects p join public.project_tasks t on t.project_id=p.id where t.id=p_id and t.assignee_id=p_actor for update of p;
  select * into task from public.project_tasks where id=p_id and assignee_id=p_actor;
  if not found or project.status<>'active' or not exists(select 1 from public.project_memberships where project_id=project.id and user_id=p_actor and status='active' and role in ('manager','contributor')) or (project.customer_organization_id is not null and not exists(select 1 from public.organizations where id=project.customer_organization_id and status='active')) then raise exception 'Assigned work unavailable' using errcode='42501';end if;
  -- Serialize customer suspension with the assigned-work mutation. A status
  -- read alone would permit an organization revocation to race the update.
  if project.customer_organization_id is not null then
   perform 1 from public.organizations where id=project.customer_organization_id and status='active' for share;
   if not found then raise exception 'Customer organization unavailable' using errcode='42501';end if;
  end if;
  if project.version<>(p_data->>'version')::integer then raise exception 'Project changed' using errcode='40001';end if;
  if jsonb_typeof(p_data->'status') is distinct from 'string' or not ((task.status='todo' and p_data->>'status' in ('in_progress','blocked')) or (task.status='in_progress' and p_data->>'status' in ('in_review','blocked')) or (task.status='in_review' and p_data->>'status' in ('done','in_progress','blocked')) or (task.status='blocked' and p_data->>'status'='in_progress')) then raise exception 'Invalid task transition' using errcode='22023';end if;
  before_status:=task.status;update public.project_tasks set status=p_data->>'status' where id=task.id;
  update public.projects set version=version+1,updated_at=now() where id=project.id returning version into project.version;
  insert into public.project_activity(project_id,actor_id,action,entity_id,summary) values(project.id,p_actor,'task.update',task.id,task.title);
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,details) values(p_actor,'employee.task_status','project_task',task.id::text,jsonb_build_object('from',before_status,'to',p_data->>'status','projectVersion',project.version));
  return jsonb_build_object('version',project.version);
 elsif p_action='leave.request' then
  if jsonb_typeof(p_data->'startOn') is distinct from 'string' or jsonb_typeof(p_data->'endOn') is distinct from 'string' or p_data->>'startOn'!~'^\d{4}-\d{2}-\d{2}$' or p_data->>'endOn'!~'^\d{4}-\d{2}-\d{2}$' or
    jsonb_typeof(p_data->'kind') is distinct from 'string' or p_data->>'kind' not in ('annual','sick','unpaid','other') or jsonb_typeof(p_data->'reason') is distinct from 'string' or length(btrim(p_data->>'reason')) not between 1 and 500 then raise exception 'Invalid leave request' using errcode='22023';end if;
  if (p_data->>'endOn')::date<(p_data->>'startOn')::date or (p_data->>'endOn')::date-(p_data->>'startOn')::date>365 then raise exception 'Invalid leave dates' using errcode='22023';end if;
  digest:=md5((p_data-'currentHash')::text);
  select * into request from public.internal_leave_requests where idempotency_key=p_id;
  if found then if request.employee_id<>employee or request.request_hash<>digest then raise exception 'Leave retry changed' using errcode='23505';end if;return jsonb_build_object('id',request.id,'replayed',true);end if;
  if exists(select 1 from public.internal_leave_requests where employee_id=employee and status in ('pending','approved') and start_on<=(p_data->>'endOn')::date and end_on>=(p_data->>'startOn')::date) then raise exception 'Overlapping leave request' using errcode='23505';end if;
  insert into public.internal_leave_requests(employee_id,idempotency_key,request_hash,start_on,end_on,kind,reason) values(employee,p_id,digest,(p_data->>'startOn')::date,(p_data->>'endOn')::date,p_data->>'kind',btrim(p_data->>'reason')) returning * into request;
  result:=jsonb_build_object('id',request.id,'replayed',false);
 elsif p_action='leave.cancel' then
  select * into request from public.internal_leave_requests where id=p_id and employee_id=employee for update;
  if not found then raise exception 'Own leave request required' using errcode='42501';end if;
  if request.version<>(p_data->>'version')::integer or request.status<>'pending' then raise exception 'Leave request changed or already reviewed' using errcode='40001';end if;
  update public.internal_leave_requests set status='cancelled',version=version+1 where id=request.id;result:=jsonb_build_object('id',request.id);
 elsif p_action='attendance.in' then
  if e.status<>'active' then raise exception 'Active employment required to check in' using errcode='42501';end if;
  select * into entry from public.internal_attendance where idempotency_key=p_id;
  if found then if entry.employee_id<>employee then raise exception 'Own attendance required' using errcode='42501';end if;return jsonb_build_object('id',entry.id,'replayed',true);end if;
  insert into public.internal_attendance(employee_id,idempotency_key,work_day) values(employee,p_id,work_date) returning * into entry;result:=jsonb_build_object('id',entry.id,'replayed',false);
 else
  if coalesce(p_data->>'key','')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then raise exception 'Checkout key required' using errcode='22023';end if;
  select * into entry from public.internal_attendance where id=p_id and employee_id=employee for update;
  if not found then raise exception 'Own attendance required' using errcode='42501';end if;
  if entry.status='closed' and entry.out_key=(p_data->>'key')::uuid then return jsonb_build_object('id',entry.id,'replayed',true);end if;
  if entry.status<>'open' or entry.version<>(p_data->>'version')::integer then raise exception 'Attendance changed' using errcode='40001';end if;
  update public.internal_attendance set checked_out_at=clock_timestamp(),out_key=(p_data->>'key')::uuid,status='closed',version=version+1 where id=entry.id;result:=jsonb_build_object('id',entry.id);
 end if;
 insert into public.audit_logs(actor_user_id,action,target_type,target_id) values(p_actor,'employee.'||p_action,case when p_action like 'leave.%' then 'internal_leave_request' else 'internal_attendance' end,result->>'id');
 return result;
end$$;
revoke all on function public.internal_self_service(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.internal_self_service(uuid,text,uuid,jsonb) to service_role;

create function public.internal_hrms(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare target uuid; authz jsonb; role text; request public.internal_leave_requests; entry public.internal_attendance; key text; rows_data jsonb; items jsonb;
begin
 if p_action is null or p_action not in ('leave.list','leave.review','attendance.list','attendance.incomplete') or jsonb_typeof(p_data) is distinct from 'object' then raise exception 'Invalid HR command' using errcode='22023';end if;
 for key in select jsonb_object_keys(p_data) loop
  if key not in (select unnest(case p_action when 'leave.list' then array['currentHash','afterId','status'] when 'attendance.list' then array['currentHash','afterId'] when 'leave.review' then array['currentHash','version','decision','note','confirmed'] else array['currentHash','version','note','confirmed'] end)) then raise exception 'Invalid HR fields' using errcode='22023';end if;
 end loop;
 if p_action='leave.review' then select employee_id into target from public.internal_leave_requests where id=p_id;elsif p_action='attendance.incomplete' then select employee_id into target from public.internal_attendance where id=p_id;end if;
 authz:=public.internal_hrms_guard(p_actor,p_data->>'currentHash',target,true);role:=authz->>'role';
 if p_action in ('leave.list','attendance.list') then
  if p_id is not null or (p_data?'afterId' and p_data->>'afterId'!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then raise exception 'Invalid HR cursor' using errcode='22023';end if;
  if p_action='leave.list' then
   if coalesce(p_data->>'status','pending') not in ('pending','approved','rejected','cancelled','all') then raise exception 'Invalid leave status' using errcode='22023';end if;
   select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]') into rows_data from(select r.id,r.employee_id,e.full_name employee_name,r.start_on,r.end_on,r.kind,r.reason,r.status,r.version,r.requested_at,r.decision_note
    from public.internal_leave_requests r join public.internal_employees e on e.id=r.employee_id where (not p_data?'afterId' or r.id>(p_data->>'afterId')::uuid) and (coalesce(p_data->>'status','pending')='all' or r.status=coalesce(p_data->>'status','pending'))
    and (role='owner' or (not exists(select 1 from public.internal_hr_managers where employee_id=e.id) and not exists(select 1 from public.profiles where email=e.email and platform_role='super_admin')))
    order by r.id limit 26)x;
  else
   select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]') into rows_data from(select a.id,a.employee_id,e.full_name employee_name,a.work_day,a.checked_in_at,a.checked_out_at,a.status,a.version,a.recovery_note
    from public.internal_attendance a join public.internal_employees e on e.id=a.employee_id where (not p_data?'afterId' or a.id>(p_data->>'afterId')::uuid)
    and (role='owner' or (not exists(select 1 from public.internal_hr_managers where employee_id=e.id) and not exists(select 1 from public.profiles where email=e.email and platform_role='super_admin')))
    order by a.id limit 26)x;
  end if;
  select coalesce(jsonb_agg(value order by ordinality),'[]') into items from jsonb_array_elements(rows_data) with ordinality where ordinality<=25;
  return jsonb_build_object('items',items,'nextId',case when jsonb_array_length(rows_data)>25 then items->24->>'id' else null end,'role',role);
 end if;
 if jsonb_typeof(p_data->'version') is distinct from 'number' or coalesce(p_data->>'version','')!~'^[1-9][0-9]{0,9}$' or (p_data->>'version')::numeric>2147483646 or p_data->'confirmed' is distinct from 'true'::jsonb or jsonb_typeof(p_data->'note') is distinct from 'string' or length(p_data->>'note')>300 then raise exception 'Review the current HR record' using errcode='22023';end if;
 if p_action='leave.review' then
  select * into request from public.internal_leave_requests where id=p_id for update;
  if not found then raise exception 'Request unavailable' using errcode='P0002';end if;
  if request.status<>'pending' or request.version<>(p_data->>'version')::integer then raise exception 'Leave already reviewed or changed' using errcode='40001';end if;
  if p_data->>'decision' not in ('approved','rejected') or p_data->>'decision' is null then raise exception 'Invalid decision' using errcode='22023';end if;
  if exists(select 1 from public.internal_employee_identity_links where employee_id=request.employee_id and user_id=p_actor) then raise exception 'Self approval is forbidden' using errcode='42501';end if;
  if p_data->>'decision'='approved' and not exists(select 1 from public.internal_employees where id=request.employee_id and status in ('active','on_leave')) then raise exception 'Current employment required for approval' using errcode='42501';end if;
  update public.internal_leave_requests set status=p_data->>'decision',decision_note=p_data->>'note',reviewed_by=p_actor,reviewed_at=now(),version=version+1 where id=request.id;
 else
  select * into entry from public.internal_attendance where id=p_id for update;
  if not found then raise exception 'Attendance unavailable' using errcode='P0002';end if;
  if entry.status<>'open' or entry.work_day>=(clock_timestamp() at time zone 'Asia/Kolkata')::date or entry.version<>(p_data->>'version')::integer or length(btrim(p_data->>'note'))<8 then raise exception 'Only a past open record may be marked incomplete with a reason' using errcode='40001';end if;
  update public.internal_attendance set status='incomplete',recovered_by=p_actor,recovery_note=p_data->>'note',version=version+1 where id=entry.id;
 end if;
 insert into public.audit_logs(actor_user_id,action,target_type,target_id,details) values(p_actor,'hr.'||p_action,'internal_workforce',p_id::text,jsonb_build_object('version',(p_data->>'version')::integer+1));
 return jsonb_build_object('saved',true);
end$$;
revoke all on function public.internal_hrms(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.internal_hrms(uuid,text,uuid,jsonb) to service_role;

-- Own-task notices survive contributor privacy restrictions, without permitting
-- milestone, repository or coworker notifications through this narrow helper.
create function public.internal_owns_task(p_actor uuid,p_project uuid,p_task uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.project_tasks t
 join public.projects pr on pr.id=t.project_id
 join public.project_memberships pm on pm.project_id=pr.id and pm.user_id=p_actor and pm.status='active' and pm.role in ('manager','contributor')
 join public.internal_employee_identity_links l on l.user_id=p_actor and l.status='linked'
 join public.internal_employees e on e.id=l.employee_id and e.status in ('active','on_leave')
 join public.profiles p on p.id=p_actor and p.status='active' and p.email=e.email
 where t.id=p_task and t.project_id=p_project and t.assignee_id=p_actor
 and (pr.customer_organization_id is null or exists(select 1 from public.organizations o where o.id=pr.customer_organization_id and o.status='active')))
$$;
revoke all on function public.internal_owns_task(uuid,uuid,uuid) from public,anon,authenticated,service_role;

create or replace function public.notification_command(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.project_notification_outbox; allowed boolean; n integer:=0;
begin
 if p_action='scan' and p_actor is null then
  insert into public.project_notification_outbox(project_id,user_id,event_key,category,entity_id,event_type)
  select t.project_id,t.assignee_id,'overdue:'||t.id::text||':'||(now() at time zone 'UTC')::date::text,'overdue',t.id,'task.overdue'
  from public.project_tasks t join public.projects p on p.id=t.project_id where t.assignee_id is not null and t.due_on<(now() at time zone 'UTC')::date and t.status not in ('done','cancelled') and p.status in ('planned','active','paused')
  and (public.project_permission(t.assignee_id,t.project_id) in ('manager','contributor','viewer') or public.internal_owns_task(t.assignee_id,t.project_id,t.id))
  and not exists(select 1 from public.project_notification_outbox prior where prior.user_id=t.assignee_id and prior.event_key='overdue:'||t.id::text||':'||(now() at time zone 'UTC')::date::text) order by t.id limit 500 on conflict do nothing;
  insert into public.project_notification_outbox(project_id,user_id,event_key,category,entity_id,event_type)
  select m.project_id,pm.user_id,'overdue-milestone:'||m.id::text||':'||(now() at time zone 'UTC')::date::text,'overdue',m.id,'milestone.overdue'
  from public.project_milestones m join public.projects p on p.id=m.project_id
  join public.project_memberships pm on pm.project_id=m.project_id and pm.status='active' and pm.role='manager'
  where m.due_on<(now() at time zone 'UTC')::date and m.status not in ('done','cancelled') and p.status in ('planned','active','paused')
   and public.project_permission(pm.user_id,m.project_id)='manager'
   and not exists(select 1 from public.project_notification_outbox prior where prior.user_id=pm.user_id and prior.event_key='overdue-milestone:'||m.id::text||':'||(now() at time zone 'UTC')::date::text)
  order by m.id,pm.user_id limit 500 on conflict do nothing;
  return '{"scanned":true}';
 end if;
 if p_actor is not null then
  perform 1 from public.profiles where id=p_actor and status='active' for share;
  if not found then raise exception 'Account unavailable' using errcode='42501';end if;
 elsif p_action<>'dispatch' then raise exception 'Actor required' using errcode='42501';end if;
 if p_action='dispatch' then
  for o in select * from public.project_notification_outbox where state='queued' and available_at<=now() and (p_actor is null or user_id=p_actor) order by id for update skip locked limit 50 loop
   begin
    allowed:=coalesce(public.project_permission(o.user_id,o.project_id) in ('manager','contributor','viewer'),false) or (o.event_type like 'task.%' and public.internal_owns_task(o.user_id,o.project_id,o.entity_id));
    if exists(select 1 from public.project_notification_preferences f where user_id=o.user_id and not case o.category when 'assignments' then assignments when 'delivery' then delivery else overdue end) then allowed:=false;end if;
    if o.event_type='milestone.overdue' and (not exists(select 1 from public.project_memberships pm where pm.project_id=o.project_id and pm.user_id=o.user_id and pm.role='manager' and pm.status='active') or public.project_permission(o.user_id,o.project_id) is distinct from 'manager' or not exists(select 1 from public.project_milestones m join public.projects pr on pr.id=m.project_id where m.id=o.entity_id and m.project_id=o.project_id and m.status not in ('done','cancelled') and m.due_on<(now() at time zone 'UTC')::date and pr.status in ('planned','active','paused'))) then allowed:=false;end if;
    if o.event_type='task.overdue' and not exists(select 1 from public.project_tasks t join public.projects pr on pr.id=t.project_id where t.id=o.entity_id and t.project_id=o.project_id and t.assignee_id=o.user_id and t.status not in ('done','cancelled') and t.due_on<(now() at time zone 'UTC')::date and pr.status in ('planned','active','paused')) then allowed:=false;end if;
    if allowed then insert into public.project_notifications(outbox_id,user_id,project_id) values(o.id,o.user_id,o.project_id) on conflict do nothing;end if;
    update public.project_notification_outbox set state=case when allowed then 'delivered' else 'suppressed' end where id=o.id;n:=n+1;
   exception when others then
    update public.project_notification_outbox set attempts=attempts+1,state=case when attempts>=4 then 'attention' else 'queued' end,available_at=now()+make_interval(secs=>least(3600,60*(2^least(attempts,6))::integer)) where id=o.id;
   end;
  end loop;return jsonb_build_object('processed',n);
 elsif p_action='retry' then
  update public.project_notification_outbox set state='queued',attempts=0,available_at=now() where user_id=p_actor and state='attention';return '{"saved":true}';
 elsif p_action='preferences' then
  return coalesce((select to_jsonb(f)-'user_id' from public.project_notification_preferences f where user_id=p_actor),'{"assignments":true,"delivery":true,"overdue":true}');
 elsif p_action='preferences.save' then
  insert into public.project_notification_preferences(user_id,assignments,delivery,overdue) values(p_actor,(p_data->>'assignments')::boolean,(p_data->>'delivery')::boolean,(p_data->>'overdue')::boolean)
  on conflict(user_id) do update set assignments=excluded.assignments,delivery=excluded.delivery,overdue=excluded.overdue;
  return '{"saved":true}';
 elsif p_action='read' then
  update public.project_notifications set read_at=coalesce(read_at,now()) where id=(p_data->>'notificationId')::bigint and user_id=p_actor;
  return '{"saved":true}';
 elsif p_action='inbox' then
  return jsonb_build_object('queued',(select count(*) from public.project_notification_outbox where user_id=p_actor and state='queued'),'attention',(select count(*) from public.project_notification_outbox where user_id=p_actor and state='attention'),'notifications',coalesce((select jsonb_agg(x) from (
   select n.id,n.project_id,n.read_at,n.created_at,p.name project_name,notice.event_type,
    case when notice.event_type like 'task.%' then (select title from public.project_tasks where id=notice.entity_id)
     when notice.event_type like 'milestone.%' then (select title from public.project_milestones where id=notice.entity_id)
     else (select d.title from public.project_delivery_records d join public.project_repositories c on c.id=d.connection_id join public.project_github_installations g on g.project_id=c.project_id and g.installation_id=c.installation_id where d.id=notice.entity_id and c.status='active' and g.status='active') end title
   from public.project_notifications n join public.projects p on p.id=n.project_id join public.project_notification_outbox notice on notice.id=n.outbox_id
   where n.user_id=p_actor and (public.project_permission(p_actor,n.project_id) in ('manager','contributor','viewer') or (notice.event_type like 'task.%' and public.internal_owns_task(p_actor,n.project_id,notice.entity_id)))
    and (notice.event_type<>'milestone.overdue' or exists(select 1 from public.project_memberships pm where pm.project_id=n.project_id and pm.user_id=p_actor and pm.role='manager' and pm.status='active'))
    and (notice.event_type not like 'github.%' or exists(select 1 from public.project_delivery_records d join public.project_repositories c on c.id=d.connection_id join public.project_github_installations g on g.project_id=c.project_id and g.installation_id=c.installation_id where d.id=notice.entity_id and c.status='active' and g.status='active'))
   order by n.id desc limit 100) x),'[]'));
 end if;
 raise exception 'Unknown notification action' using errcode='22023';
end$$;
revoke all on function public.notification_command(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.notification_command(uuid,text,uuid,jsonb) to service_role;


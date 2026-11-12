-- Forward repair: all workforce RPCs lock profiles -> roster rows -> HR grants.
-- Original business/authorization/audit behavior is retained behind the wrapper.
-- No employee, identity, assignment or historical migration is rewritten.
alter function public.internal_employee_command(uuid,text,uuid,jsonb) rename to internal_employee_core_command;
revoke all on function public.internal_employee_core_command(uuid,text,uuid,jsonb) from public,anon,authenticated,service_role;
create function public.internal_employee_command(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if p_action is null or p_action not in ('access','list','create','update','grant_hr','revoke_hr') or jsonb_typeof(p_data) is distinct from 'object' then
  raise exception 'Invalid workforce command' using errcode='22023';
 end if;
 if p_action in ('update','grant_hr','revoke_hr') and (
  jsonb_typeof(p_data->'version') is distinct from 'number' or
  coalesce(p_data->>'version','')!~'^[1-9][0-9]{0,9}$' or
  (p_data->>'version')::numeric>2147483647) then
  raise exception 'Invalid employee version' using errcode='22023';
 end if;
 -- Same platform-first profile order as account deactivation. Grant targets
 -- are resolved before taking any employee/grant lock, never afterwards.
 perform 1 from public.profiles u where u.id=p_actor or
  (p_action='grant_hr' and u.email=(select e.email from public.internal_employees e where e.id=p_id))
 order by case when u.platform_role='super_admin' then 0 else 1 end,u.id for share;
 if not exists(select 1 from public.profiles where id=p_actor and status='active') then
  raise exception 'Active portal identity required' using errcode='42501';
 end if;
 -- HR's own roster and a mutation target are locked in immutable ID order.
 -- Take these BEFORE any grant row, including on read/access requests.
 perform 1 from public.internal_employees e where
  e.id in (select h.employee_id from public.internal_hr_managers h where h.user_id=p_actor)
  or (p_action in ('update','grant_hr','revoke_hr') and e.id=p_id)
  or (p_action='create' and e.idempotency_key=p_id)
 order by e.id for update;
 perform 1 from public.internal_hr_managers h where h.user_id=p_actor or
  (p_action in ('update','grant_hr','revoke_hr') and h.employee_id=p_id)
 order by h.employee_id for update;
 -- Core rechecks the current actor, current grant/roster, protected targets,
 -- optimistic versions and all mutation fields after lock waits.
 return public.internal_employee_core_command(p_actor,p_action,p_id,p_data);
end$$;
revoke all on function public.internal_employee_command(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.internal_employee_command(uuid,text,uuid,jsonb) to service_role;

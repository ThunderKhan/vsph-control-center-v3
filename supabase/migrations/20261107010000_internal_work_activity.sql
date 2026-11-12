-- The employee heatmap counts recorded transitions to "done" from My Work.
-- This is a history of activity events, not an employee performance score.
-- No existing records are changed or backfilled.
create index if not exists internal_work_activity_audit_idx
 on public.audit_logs(actor_user_id,created_at desc)
 where action='employee.task_status' and details->>'to'='done';

create function public.internal_work_activity(p_actor uuid,p_session_hash text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 work_day date:=(clock_timestamp() at time zone 'Asia/Kolkata')::date;
 start_day date:=work_day-364;
 result jsonb;
begin
 -- Reuse the exact session-bound, employee-identity authorization required by
 -- internal_self_service. Neither HR nor the platform owner may impersonate
 -- an employee or obtain this data through the API.
 perform public.internal_hrms_guard(p_actor,p_session_hash);
 with events as materialized (
  select (a.created_at at time zone 'Asia/Kolkata')::date activity_day,
         p.id project_id,p.name project_name
  from public.audit_logs a
  join public.project_tasks t on t.id=case
   when a.target_type='project_task'
    and a.target_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
   then a.target_id::uuid else null end
  join public.projects p on p.id=t.project_id
  join public.project_memberships m on m.project_id=p.id
   and m.user_id=p_actor and m.status='active'
   and m.role in ('manager','contributor')
  where a.actor_user_id=p_actor
   and a.action='employee.task_status'
   and a.details->>'to'='done'
   and t.assignee_id=p_actor
   and a.created_at >= (start_day::timestamp at time zone 'Asia/Kolkata')
   and a.created_at < ((work_day+1)::timestamp at time zone 'Asia/Kolkata')
   and (p.customer_organization_id is null or exists (
    select 1 from public.organizations o where o.id=p.customer_organization_id and o.status='active'
   ))
 ), days as (
  select activity_day,count(*)::integer count from events group by activity_day
 ), top_projects as (
  select project_id,project_name,count(*)::integer count
  from events group by project_id,project_name
  order by count desc,project_name limit 3
 )
 select jsonb_build_object(
  'windowStart',start_day::text,
  'windowEnd',work_day::text,
  'timeZone','Asia/Kolkata',
  'source','employee.task_status',
  'total',(select count(*) from events),
  'days',coalesce((select jsonb_agg(jsonb_build_object('date',activity_day::text,'count',count) order by activity_day) from days),'[]'::jsonb),
  'projects',coalesce((select jsonb_agg(jsonb_build_object('name',project_name,'count',count) order by count desc,project_name) from top_projects),'[]'::jsonb)
 ) into result;
 return result;
end$$;

revoke all on function public.internal_work_activity(uuid,text) from public,anon,authenticated;
grant execute on function public.internal_work_activity(uuid,text) to service_role;

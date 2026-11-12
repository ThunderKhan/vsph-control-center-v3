-- Add overdue milestone reminders for current project managers. In-app only.
create index project_tasks_open_due on public.project_tasks(due_on,project_id,id) where assignee_id is not null and status not in ('done','cancelled');
create index project_milestones_open_due on public.project_milestones(due_on,project_id,id) where status not in ('done','cancelled');
create or replace function public.notification_command(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.project_notification_outbox; allowed boolean; n integer:=0;
begin
 if p_action='scan' and p_actor is null then
  insert into public.project_notification_outbox(project_id,user_id,event_key,category,entity_id,event_type)
  select t.project_id,t.assignee_id,'overdue:'||t.id::text||':'||(now() at time zone 'UTC')::date::text,'overdue',t.id,'task.overdue'
  from public.project_tasks t join public.projects p on p.id=t.project_id where t.assignee_id is not null and t.due_on<(now() at time zone 'UTC')::date and t.status not in ('done','cancelled') and p.status in ('planned','active','paused')
  and public.project_permission(t.assignee_id,t.project_id) in ('manager','contributor','viewer')
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
    allowed:=coalesce(public.project_permission(o.user_id,o.project_id) in ('manager','contributor','viewer'),false);
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
   where n.user_id=p_actor and public.project_permission(p_actor,n.project_id) in ('manager','contributor','viewer')
    and (notice.event_type<>'milestone.overdue' or exists(select 1 from public.project_memberships pm where pm.project_id=n.project_id and pm.user_id=p_actor and pm.role='manager' and pm.status='active'))
    and (notice.event_type not like 'github.%' or exists(select 1 from public.project_delivery_records d join public.project_repositories c on c.id=d.connection_id join public.project_github_installations g on g.project_id=c.project_id and g.installation_id=c.installation_id where d.id=notice.entity_id and c.status='active' and g.status='active'))
   order by n.id desc limit 100) x),'[]'));
 end if;
 raise exception 'Unknown notification action' using errcode='22023';
end$$;
revoke all on function public.notification_command(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.notification_command(uuid,text,uuid,jsonb) to service_role;


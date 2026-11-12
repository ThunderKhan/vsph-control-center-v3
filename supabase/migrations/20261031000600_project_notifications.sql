-- In-app delivery only. No SMTP/provider side effects; requires 005.
create table public.project_notification_preferences(
 user_id uuid primary key references public.profiles(id),assignments boolean not null default true,delivery boolean not null default true,overdue boolean not null default true
);
create table public.project_notification_outbox(
 id bigint generated always as identity primary key,project_id uuid not null references public.projects(id),user_id uuid not null references public.profiles(id),
 event_key text not null,category text not null check(category in ('assignments','delivery','overdue')),entity_id uuid,event_type text not null,
 state text not null default 'queued' check(state in ('queued','delivered','suppressed','attention')),attempts integer not null default 0,
 available_at timestamptz not null default now(),created_at timestamptz not null default now(),unique(user_id,event_key)
);
create table public.project_notifications(
 id bigint generated always as identity primary key,outbox_id bigint not null unique references public.project_notification_outbox(id),
 user_id uuid not null references public.profiles(id),project_id uuid not null references public.projects(id),read_at timestamptz,created_at timestamptz not null default now()
);
create index on public.project_notification_outbox(state,available_at);
create index on public.project_notifications(user_id,id desc);
do $$declare t text;begin foreach t in array array['project_notification_preferences','project_notification_outbox','project_notifications'] loop
 execute format('alter table public.%I enable row level security',t);execute format('revoke all on public.%I from public,anon,authenticated',t);end loop;end$$;

create function public.capture_project_notification() returns trigger language plpgsql security definer set search_path='' as $$
declare person uuid; event text; category text; entity uuid; project uuid; key text;
begin
 project:=new.project_id;if tg_table_name<>'project_delivery_events' then entity:=new.id;end if;
 if tg_table_name='project_tasks' then
  if new.assignee_id is null then return new;end if;
  if tg_op='UPDATE' and new.assignee_id is not distinct from old.assignee_id then return new;end if;
  person:=new.assignee_id;event:='task.assigned';category:='assignments';
 elsif tg_table_name='project_milestones' then
  if new.status<>'done' or (tg_op='UPDATE' and old.status='done') then return new;end if;
  event:='milestone.completed';category:='delivery';
 else
  entity:=new.record_id;event:='github.'||(new.snapshot->>'kind')||'.'||(new.snapshot->>'state');category:='delivery';
  if new.snapshot->>'kind' not in ('pull','release','workflow','check') then return new;end if;
  if new.snapshot->>'kind' in ('workflow','check') and new.snapshot->>'state' not in ('failure','timed_out','cancelled','action_required','success') then return new;end if;
 end if;
 key:=tg_table_name||':'||new.id::text||':'||case when tg_table_name='project_delivery_events' then 'source' else txid_current()::text end;
 insert into public.project_notification_outbox(project_id,user_id,event_key,category,entity_id,event_type)
 select project,m.user_id,key,category,entity,event from public.project_memberships m where m.project_id=project and m.status='active' and m.role<>'client' and (person is null or m.user_id=person)
 on conflict(user_id,event_key) do nothing;
 return new;
end$$;
revoke all on function public.capture_project_notification() from public,anon,authenticated;
create trigger task_assignment_notice after insert or update on public.project_tasks for each row execute function public.capture_project_notification();
create trigger milestone_notice after insert or update on public.project_milestones for each row execute function public.capture_project_notification();
create trigger github_notice after insert on public.project_delivery_events for each row execute function public.capture_project_notification();

create function public.notification_command(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.project_notification_outbox; allowed boolean; n integer:=0;
begin
 if p_action='scan' and p_actor is null then
  insert into public.project_notification_outbox(project_id,user_id,event_key,category,entity_id,event_type)
  select t.project_id,t.assignee_id,'overdue:'||t.id::text||':'||(now() at time zone 'UTC')::date::text,'overdue',t.id,'task.overdue'
  from public.project_tasks t join public.projects p on p.id=t.project_id where t.assignee_id is not null and t.due_on<(now() at time zone 'UTC')::date and t.status not in ('done','cancelled') and p.status in ('planned','active','paused')
  and public.project_permission(t.assignee_id,t.project_id) in ('manager','contributor','viewer')
  and not exists(select 1 from public.project_notification_outbox prior where prior.user_id=t.assignee_id and prior.event_key='overdue:'||t.id::text||':'||(now() at time zone 'UTC')::date::text) order by t.id limit 500 on conflict do nothing;
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
     when notice.event_type='milestone.completed' then (select title from public.project_milestones where id=notice.entity_id)
     else (select d.title from public.project_delivery_records d join public.project_repositories c on c.id=d.connection_id join public.project_github_installations g on g.project_id=c.project_id and g.installation_id=c.installation_id where d.id=notice.entity_id and c.status='active' and g.status='active') end title
   from public.project_notifications n join public.projects p on p.id=n.project_id join public.project_notification_outbox notice on notice.id=n.outbox_id
   where n.user_id=p_actor and public.project_permission(p_actor,n.project_id) in ('manager','contributor','viewer')
    and (notice.event_type not like 'github.%' or exists(select 1 from public.project_delivery_records d join public.project_repositories c on c.id=d.connection_id join public.project_github_installations g on g.project_id=c.project_id and g.installation_id=c.installation_id where d.id=notice.entity_id and c.status='active' and g.status='active'))
   order by n.id desc limit 100) x),'[]'));
 end if;
 raise exception 'Unknown notification action' using errcode='22023';
end$$;
revoke all on function public.notification_command(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.notification_command(uuid,text,uuid,jsonb) to service_role;

create function public.project_report(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.profiles where id=p_actor and status='active') then raise exception 'Account unavailable' using errcode='42501';end if;
 return jsonb_build_object('generatedAt',now(),'deploymentStatus','unconfigured','projects',coalesce((select jsonb_agg(x) from (
  select p.id,p.key,p.name,p.status,p.owner_id,p.customer_organization_id,p.due_on,
  (select full_name from public.profiles where id=p.owner_id) owner_name,(select name from public.organizations where id=p.customer_organization_id) organization_name,
  (select count(*) from public.project_tasks t where t.project_id=p.id and t.status='done') completed_tasks,
  (select count(*) from public.project_tasks t where t.project_id=p.id and t.status<>'cancelled') total_tasks,
  (select count(*) from public.project_tasks t where t.project_id=p.id and t.assignee_id=p_actor and t.status not in ('done','cancelled')) assigned_to_me,
  (select count(*) from public.project_tasks t where t.project_id=p.id and t.due_on<current_date and t.status not in ('done','cancelled')) overdue_tasks,
  (select count(*) from public.project_milestones m where m.project_id=p.id and m.status='done') completed_milestones,
  (select count(*) from public.project_milestones m where m.project_id=p.id and m.status not in ('done','cancelled')) pending_milestones,
  (select count(*) from public.project_delivery_records d join public.project_repositories c on c.id=d.connection_id join public.project_github_installations g on g.project_id=c.project_id and g.installation_id=c.installation_id where d.project_id=p.id and c.status='active' and g.status='active' and d.kind='pull' and d.state='open') open_prs,
  (select count(*) from public.project_delivery_records d join public.project_repositories c on c.id=d.connection_id join public.project_github_installations g on g.project_id=c.project_id and g.installation_id=c.installation_id where d.project_id=p.id and c.status='active' and g.status='active' and d.kind='pull' and d.state='open' and coalesce((d.details->>'reviewRequested')::integer,0)>0) prs_awaiting_requested_review,
  (select count(*) from public.project_delivery_records d join public.project_repositories c on c.id=d.connection_id join public.project_github_installations g on g.project_id=c.project_id and g.installation_id=c.installation_id where d.project_id=p.id and c.status='active' and g.status='active' and d.kind in ('workflow','check') and d.state in ('failure','timed_out','action_required')) failed_build_records,
  (select max(last_success_at) from public.project_repositories c where c.project_id=p.id and c.status='active') last_sync_at,
  (select max(created_at) from public.project_activity a where a.project_id=p.id) last_activity_at
  from public.projects p where public.project_permission(p_actor,p.id) in ('manager','contributor','viewer')
   and (p_id is null or p.id=p_id) and (p_data->>'organizationId' is null or p.customer_organization_id=(p_data->>'organizationId')::uuid)
   and (p_data->>'ownerId' is null or p.owner_id=(p_data->>'ownerId')::uuid) and (coalesce(p_data->>'status','')='' or p.status=p_data->>'status')
   and (p_data->>'from' is null or p.created_at>=(p_data->>'from')::date) and (p_data->>'to' is null or p.created_at<(p_data->>'to')::date+interval '1 day')
  order by p.id desc limit 100) x),'[]'));
end$$;
revoke all on function public.project_report(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.project_report(uuid,text,uuid,jsonb) to service_role;

-- Internal workforce scheduler. All operations use a current portal session;
-- event titles/descriptions and private appointments are invisible to customers.
create table public.internal_calendar_events(
 id uuid primary key,
 organizer_id uuid not null references public.profiles(id),
 scope text not null check(scope in ('personal','team','company')),
 title text not null check(length(btrim(title)) between 1 and 120),
 description text not null default '' check(length(description)<=1000),
 category text not null check(category in ('meeting','task','reminder','personal')),
 color text not null check(color in ('blue','green','purple','orange','pink','red')),
 tags text[] not null default '{}',
 meet_url text not null default '' check(length(meet_url)<=300),
 starts_at timestamptz not null,
 ends_at timestamptz not null,
 version integer not null default 1 check(version between 1 and 2147483646),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 check(ends_at>starts_at and ends_at<=starts_at+interval '14 days')
);
create table public.internal_calendar_attendees(
 event_id uuid not null references public.internal_calendar_events(id) on delete cascade,
 user_id uuid not null references public.profiles(id),
 added_at timestamptz not null default now(),
 primary key(event_id,user_id)
);
create index internal_calendar_organizer_idx on public.internal_calendar_events(organizer_id,starts_at);
create index internal_calendar_attendee_idx on public.internal_calendar_attendees(user_id,event_id);
create index internal_calendar_time_idx on public.internal_calendar_events(starts_at,ends_at);
alter table public.internal_calendar_events enable row level security;
alter table public.internal_calendar_attendees enable row level security;
revoke all on public.internal_calendar_events,public.internal_calendar_attendees from public,anon,authenticated;
grant select,insert,update,delete on public.internal_calendar_events,public.internal_calendar_attendees to service_role;

create function public.internal_calendar(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 x public.internal_calendar_events;
 own_staff boolean;
 can_manage boolean;
 k text;
 from_at timestamptz;
 until_at timestamptz;
 start_time timestamptz;
 end_time timestamptz;
 event_scope text;
 emails text[];
 matched integer;
 requested integer;
 result jsonb;
begin
 if p_action not in ('list','create','save','delete') or
    jsonb_typeof(p_data) is distinct from 'object' then
  raise exception 'Invalid calendar operation' using errcode='22023';
 end if;
 if nullif(p_data->>'currentHash','') is null then
  raise exception 'Current session required' using errcode='42501';
 end if;
 select exists(
  select 1 from public.internal_employee_identity_links l
  join public.internal_employees e on e.id=l.employee_id
  join public.profiles p on p.id=l.user_id and lower(p.email)=lower(e.email)
  where l.user_id=p_actor and l.status='linked' and e.status in ('active','on_leave')
 ) into own_staff;
 if own_staff then
  perform public.internal_hrms_guard(p_actor,p_data->>'currentHash');
 else
  perform public.internal_hrms_guard(p_actor,p_data->>'currentHash',null,true);
 end if;
 can_manage:=coalesce(public.internal_workforce_authority(p_actor) in ('owner','hr'),false);

 if p_action='list' then
  if p_id is not null or (select count(*) from jsonb_object_keys(p_data))<>3
      or not (p_data?'from' and p_data?'to') then
   raise exception 'Invalid calendar range' using errcode='22023';
  end if;
  if (p_data->>'from') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' or
     (p_data->>'to') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' then
   raise exception 'Invalid calendar dates' using errcode='22023';
  end if;
  from_at:=(p_data->>'from')::timestamptz;
  until_at:=(p_data->>'to')::timestamptz;
  if until_at<=from_at or until_at>from_at+interval '370 days' then
   raise exception 'Calendar range too large' using errcode='22023';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
   'id',v.id,'title',v.title,'description',v.description,
   'startAt',v.starts_at,'endAt',v.ends_at,'color',v.color,
   'category',v.category,'scope',v.scope,'tags',to_jsonb(v.tags),
   'meetUrl',v.meet_url,'version',v.version,'canEdit',v.organizer_id=p_actor,
   'attendees',coalesce((select jsonb_agg(p.email order by p.email)
      from public.internal_calendar_attendees a
      join public.profiles p on p.id=a.user_id where a.event_id=v.id),'[]'::jsonb)
  ) order by v.starts_at,v.id),'[]'::jsonb) into result
  from (
   select e.* from public.internal_calendar_events e
   where e.starts_at<until_at and e.ends_at>from_at
     and (e.organizer_id=p_actor or exists(
      select 1 from public.internal_calendar_attendees a
      where a.event_id=e.id and a.user_id=p_actor))
   order by e.starts_at,e.id limit 500
  ) v;
  return jsonb_build_object('events',result,'canCompanySchedule',can_manage);
 end if;

 if p_action='delete' then
  if p_id is null or (select count(*) from jsonb_object_keys(p_data))<>2
     or not p_data?'version' or (p_data->>'version') !~ '^[1-9][0-9]{0,9}$' then
   raise exception 'Invalid delete request' using errcode='22023';
  end if;
  select * into x from public.internal_calendar_events where id=p_id for update;
  if not found then raise exception 'Event not found' using errcode='P0002';end if;
  if x.organizer_id<>p_actor then raise exception 'Not the organizer' using errcode='42501';end if;
  if x.version<>(p_data->>'version')::integer then
   raise exception 'Event changed' using errcode='40001';
  end if;
  if x.scope='company' then
   perform public.internal_hrms_guard(p_actor,p_data->>'currentHash',null,true);
  end if;
  delete from public.internal_calendar_events where id=p_id;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,details)
   values(p_actor,'calendar.delete','calendar_event',p_id::text,jsonb_build_object('scope',x.scope));
  return jsonb_build_object('deleted',true,'id',p_id);
 end if;

 if p_id is null or
    (p_action='create' and (select count(*) from jsonb_object_keys(p_data))<>11) or
    (p_action='save' and (select count(*) from jsonb_object_keys(p_data))<>12) then
  raise exception 'Invalid event fields' using errcode='22023';
 end if;
 for k in select jsonb_object_keys(p_data) loop
  if k not in ('currentHash','title','description','startAt','endAt',
               'category','color','scope','tags','attendees','meetUrl','version') then
   raise exception 'Unexpected event field' using errcode='22023';
  end if;
 end loop;
 if p_action='create' and p_data?'version' or
    p_action='save' and not p_data?'version' then
  raise exception 'Invalid event version' using errcode='22023';
 end if;
 if length(btrim(coalesce(p_data->>'title',''))) not between 1 and 120 or
    length(coalesce(p_data->>'description',''))>1000 or
    p_data->>'scope' not in ('personal','team','company') or
    p_data->>'category' not in ('meeting','task','reminder','personal') or
    p_data->>'color' not in ('blue','green','purple','orange','pink','red') or
    jsonb_typeof(p_data->'tags') is distinct from 'array' or
    jsonb_typeof(p_data->'attendees') is distinct from 'array' or
    jsonb_array_length(p_data->'tags')>8 or
    jsonb_array_length(p_data->'attendees')>20 then
  raise exception 'Invalid event details' using errcode='22023';
 end if;
 if exists(select 1 from jsonb_array_elements_text(p_data->'tags') as t(tag)
     where length(t.tag)>32 or length(t.tag)<1) then
  raise exception 'Invalid tags' using errcode='22023';
 end if;
 if coalesce(p_data->>'meetUrl','')<>'' and
    (length(p_data->>'meetUrl')>300 or
     p_data->>'meetUrl' !~* '^https://meet[.]google[.]com/[a-z0-9/_-]+$') then
  raise exception 'Invalid meeting link' using errcode='22023';
 end if;
 if (p_data->>'startAt') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' or
    (p_data->>'endAt') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' then
  raise exception 'Invalid event time' using errcode='22023';
 end if;
 start_time:=(p_data->>'startAt')::timestamptz;
 end_time:=(p_data->>'endAt')::timestamptz;
 if end_time<=start_time or end_time>start_time+interval '14 days' then
  raise exception 'Invalid event duration' using errcode='22023';
 end if;
 event_scope:=p_data->>'scope';
 if event_scope='company' then
  perform public.internal_hrms_guard(p_actor,p_data->>'currentHash',null,true);
 end if;
 if event_scope='personal' and jsonb_array_length(p_data->'attendees')>0 then
  raise exception 'Private events cannot have attendees' using errcode='22023';
 end if;
 if p_action='save' then
  if (p_data->>'version') !~ '^[1-9][0-9]{0,9}$' then
   raise exception 'Invalid version' using errcode='22023';
  end if;
  select * into x from public.internal_calendar_events where id=p_id for update;
  if not found then raise exception 'Event not found' using errcode='P0002';end if;
  if x.organizer_id<>p_actor then raise exception 'Not the organizer' using errcode='42501';end if;
  if x.version<>(p_data->>'version')::integer then raise exception 'Event changed' using errcode='40001';end if;
  if x.scope='company' then
   perform public.internal_hrms_guard(p_actor,p_data->>'currentHash',null,true);
  end if;
 end if;

 -- Every invited account must be an active portal identity with an accepted,
 -- currently active internal workforce link. No customer users are accepted.
 select coalesce(array_agg(distinct lower(btrim(t.val))),'{}') into emails
 from jsonb_array_elements_text(p_data->'attendees') as t(val);
 select cardinality(emails) into requested;
 if exists(select 1 from unnest(emails) as t(v) where length(t.v) not between 3 and 254 or position('@' in t.v)=0) then
  raise exception 'Invalid invitee' using errcode='22023';
 end if;
 select count(distinct p.id) into matched
 from unnest(emails) as t(v)
 join public.profiles p on lower(p.email)=t.v and p.status='active'
 join public.internal_employee_identity_links l on l.user_id=p.id and l.status='linked'
 join public.internal_employees e on e.id=l.employee_id and e.status in ('active','on_leave')
  and lower(e.email)=lower(p.email);
 if matched<>requested then
  raise exception 'Invited employee unavailable' using errcode='22023';
 end if;

 if p_action='create' then
  insert into public.internal_calendar_events(id,organizer_id,scope,title,description,category,color,tags,meet_url,starts_at,ends_at)
  values(p_id,p_actor,event_scope,btrim(p_data->>'title'),coalesce(p_data->>'description',''),
   p_data->>'category',p_data->>'color',
   array(select jsonb_array_elements_text(p_data->'tags')),coalesce(p_data->>'meetUrl',''),
   start_time,end_time);
 else
  update public.internal_calendar_events
  set scope=event_scope,title=btrim(p_data->>'title'),description=coalesce(p_data->>'description',''),
   category=p_data->>'category',color=p_data->>'color',
   tags=array(select jsonb_array_elements_text(p_data->'tags')),
   meet_url=coalesce(p_data->>'meetUrl',''),starts_at=start_time,ends_at=end_time,
   updated_at=clock_timestamp(),version=version+1
  where id=p_id;
  delete from public.internal_calendar_attendees where event_id=p_id;
 end if;
 insert into public.internal_calendar_attendees(event_id,user_id)
 select p_id,p.id from unnest(emails) as t(v)
 join public.profiles p on lower(p.email)=t.v
 where p.id<>p_actor;
 insert into public.audit_logs(actor_user_id,action,target_type,target_id,details)
 values(p_actor,case when p_action='create' then 'calendar.create' else 'calendar.update' end,
   'calendar_event',p_id::text,jsonb_build_object('scope',event_scope,'invitees',requested));
 return jsonb_build_object('id',p_id,'saved',true);
end$$;
revoke all on function public.internal_calendar(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.internal_calendar(uuid,text,uuid,jsonb) to service_role;

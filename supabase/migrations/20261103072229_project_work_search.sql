-- Additive read-only search. No duplicate index, source copy or new browser grant.
create function public.project_search(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}')
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare
 query_text text; entity_kind text; cursor_kind integer:=0; cursor_id uuid:='00000000-0000-0000-0000-000000000000';
 matches jsonb; next_cursor text;
begin
 if not exists(select 1 from public.profiles where id=p_actor and status='active') then
  raise exception 'Account unavailable' using errcode='42501';
 end if;
 if p_action is distinct from 'list' or p_data is null or jsonb_typeof(p_data)<>'object' then
  raise exception 'Invalid search' using errcode='22023';
 end if;
 if exists(select 1 from jsonb_each(p_data) e where e.key not in ('q','kind','organizationId','assigneeId','status','from','to','after') or jsonb_typeof(e.value)<>'string') then
  raise exception 'Invalid search fields' using errcode='22023';
 end if;
 query_text:=btrim(p_data->>'q');entity_kind:=coalesce(nullif(p_data->>'kind',''),'all');
 if query_text is null or char_length(query_text) not between 2 and 100 or query_text ~ '[[:cntrl:]]' or
    entity_kind not in ('all','project','task','milestone') or
    (coalesce(p_data->>'status','')<>'' and p_data->>'status' not in ('planned','active','paused','completed','archived','todo','in_progress','blocked','in_review','done','cancelled')) or
    (coalesce(p_data->>'assigneeId','')<>'' and entity_kind<>'task') then
  raise exception 'Invalid search filters' using errcode='22023';
 end if;
 -- Explicit filters never grant authority. Inaccessible IDs and absent IDs both return no matches.
 if coalesce(p_data->>'after','')<>'' then
  if p_data->>'after' !~ '^[123]:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then raise exception 'Invalid cursor' using errcode='22023';end if;
  cursor_kind:=split_part(p_data->>'after',':',1)::integer;cursor_id:=split_part(p_data->>'after',':',2)::uuid;
 end if;
 if nullif(p_data->>'from','')::date > nullif(p_data->>'to','')::date then raise exception 'Invalid dates' using errcode='22023';end if;
 with authorized as materialized (
  select p.id,p.key,p.name,p.status,p.owner_id,p.due_on,public.project_permission(p_actor,p.id) role
  from public.projects p
  where (p_id is null or p.id=p_id)
   and (nullif(p_data->>'organizationId','') is null or p.customer_organization_id=(p_data->>'organizationId')::uuid)
 ), visible as materialized (select * from authorized where role is not null),
 entities as (
  select 1 rank,p.id,p.id project_id,p.key project_key,p.name project_name,'project'::text kind,p.name title,p.status,p.due_on
  from visible p where entity_kind in ('all','project') and (strpos(lower(p.name),lower(query_text))>0 or strpos(lower(p.key),lower(query_text))>0)
  union all
  select 2,m.id,p.id,p.key,p.name,'milestone',m.title,m.status,m.due_on from visible p join public.project_milestones m on m.project_id=p.id
  where entity_kind in ('all','milestone') and (p.role<>'client' or m.shared) and strpos(lower(m.title),lower(query_text))>0
  union all
  select 3,t.id,p.id,p.key,p.name,'task',t.title,t.status,t.due_on from visible p join public.project_tasks t on t.project_id=p.id
  where entity_kind in ('all','task') and (p.role<>'client' or t.shared) and strpos(lower(t.title),lower(query_text))>0
   and (nullif(p_data->>'assigneeId','') is null or t.assignee_id=(p_data->>'assigneeId')::uuid)
 ), page as (
  select * from entities e where (e.rank,e.id)>(cursor_kind,cursor_id)
   and (coalesce(p_data->>'status','')='' or e.status=p_data->>'status')
   and (nullif(p_data->>'from','') is null or e.due_on>=(p_data->>'from')::date)
   and (nullif(p_data->>'to','') is null or e.due_on<=(p_data->>'to')::date)
  order by e.rank,e.id limit 26
 ), numbered as (select *,row_number() over(order by rank,id) row_number from page)
 select coalesce(jsonb_agg(to_jsonb(item)-'rank'-'row_number' order by rank,id) filter(where item.row_number<=25),'[]'),
  case when count(*)>25 then max(rank::text||':'||id::text) filter(where item.row_number=25) end
 into matches,next_cursor from numbered item;
 return jsonb_build_object('results',matches,'nextCursor',next_cursor,'pageSize',25,'scope','authorized-project-work');
end$$;
revoke all on function public.project_search(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.project_search(uuid,text,uuid,jsonb) to service_role;

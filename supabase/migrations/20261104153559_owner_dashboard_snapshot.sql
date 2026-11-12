-- One owner-only stable snapshot replaces twenty remote operating-model reads.
-- No business rows are inserted/updated and no client role receives execution.
create function public.owner_dashboard_snapshot(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}')
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare customers jsonb;delivery jsonb;workforce jsonb;products jsonb;attention jsonb;activity jsonb;
 today date:=(now() at time zone 'UTC')::date;
begin
 if p_action is distinct from 'get' or p_id is not null or jsonb_typeof(p_data) is distinct from 'object' or (select count(*) from jsonb_object_keys(p_data))<>1 or not p_data?'currentHash' then raise exception 'Invalid operating snapshot query' using errcode='22023';end if;
 if not exists(select 1 from public.profiles p join public.portal_sessions s on s.user_id=p.id
  where p.id=p_actor and p.status='active' and p.platform_role='super_admin' and s.token_hash=p_data->>'currentHash' and s.expires_at>now()) then
  raise exception 'Current owner session required' using errcode='42501';end if;
 begin
  select jsonb_build_object('status','ready','total',count(*),'active',count(*) filter(where status='active'),'suspended',count(*) filter(where status='suspended')) into customers from public.organizations;
 exception when undefined_table or undefined_column then customers:='{"status":"unavailable"}';end;
 begin
  select jsonb_build_object('status','ready','active',count(*) filter(where status='active'),'completed',count(*) filter(where status='completed')) into delivery from public.projects;
  delivery:=delivery||(select jsonb_build_object('tasks',count(*),'done',count(*) filter(where status='done'),'cancelled',count(*) filter(where status='cancelled'),'blocked',count(*) filter(where status='blocked')) from public.project_tasks);
  delivery:=delivery||jsonb_build_object('recent',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id desc) from
   (select id,name,status,kind,created_at from public.projects where status='active' order by created_at desc,id desc limit 6)x),'[]'));
  -- Match the original DTO: ordering timestamps stay internal.
  delivery:=jsonb_set(delivery,'{recent}',coalesce((select jsonb_agg(value-'created_at' order by ordinality) from jsonb_array_elements(delivery->'recent') with ordinality),'[]'));
 exception when undefined_table or undefined_column then delivery:='{"status":"unavailable"}';end;
 begin
  select jsonb_build_object('status','ready','total',count(*),'active',count(*) filter(where status='active'),'onboarding',count(*) filter(where status='onboarding')) into workforce from public.internal_employees;
 exception when undefined_table or undefined_column then workforce:='{"status":"unavailable"}';end;
 begin
  select jsonb_build_object('status','ready','total',count(*),'active',count(*) filter(where status='active')) into products from public.applications;
  products:=products||jsonb_build_object('catalog',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id desc) from
   (select id,name,code,status,created_at from public.applications order by created_at desc,id desc limit 3)x),'[]'));
  products:=jsonb_set(products,'{catalog}',coalesce((select jsonb_agg(value-'created_at' order by ordinality) from jsonb_array_elements(products->'catalog') with ordinality),'[]'));
 exception when undefined_table or undefined_column then products:='{"status":"unavailable"}';end;
 begin
  select jsonb_build_object('status','ready','overdueTasks',count(*),'asOf',today) into attention from public.project_tasks where status in ('todo','in_progress','blocked','in_review') and due_on<today;
  attention:=attention||(select jsonb_build_object('overdueMilestones',count(*)) from public.project_milestones where status in ('planned','active') and due_on<today);
  attention:=attention||jsonb_build_object('upcoming',coalesce((select jsonb_agg(jsonb_build_object('id',id,'projectId',project_id,'title',title,'dueOn',due_on,'status',status) order by due_on,id) from
   (select id,project_id,title,due_on,status from public.project_milestones where status in ('planned','active') and due_on>=today order by due_on,id limit 5)x),'[]'));
 exception when undefined_table or undefined_column then attention:='{"status":"unavailable"}';end;
 begin
  select jsonb_build_object('status','ready','items',coalesce((select jsonb_agg(jsonb_build_object('projectId',project_id,'action',action,'createdAt',created_at) order by id desc) from
   (select id,project_id,action,created_at from public.project_activity order by id desc limit 6)x),'[]')) into activity;
 exception when undefined_table or undefined_column then activity:='{"status":"unavailable"}';end;
 return jsonb_build_object('observedAt',now(),'customers',customers,'delivery',delivery,'workforce',workforce,'products',products,'attention',attention,'activity',activity);
end$$;
revoke all on function public.owner_dashboard_snapshot(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.owner_dashboard_snapshot(uuid,text,uuid,jsonb) to service_role;

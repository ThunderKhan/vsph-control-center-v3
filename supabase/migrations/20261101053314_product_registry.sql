-- Controlled metadata and atomic product administration. Secrets never belong here.
alter table public.applications drop constraint applications_status_check;
alter table public.applications add constraint applications_status_check check(status in ('active','disabled','maintenance','retired'));
alter table public.applications add column version integer not null default 1,
 add column description text not null default '' check(length(description)<=2000),
 add column owner_id uuid references public.profiles(id),
 add column support_email text check(length(support_email)<=190),
 add column docs_url text check(length(docs_url)<=1000),
 add column visibility text not null default 'listed' check(visibility in ('listed','unlisted')),
 add column integration_mode text not null default 'adapter' check(integration_mode in ('adapter','portal_only')),
 add column created_by uuid references public.profiles(id),
 add column creation_hash text;
create table public.product_health_observations(
 application_id uuid primary key references public.applications(id),
 observed_by uuid not null references public.profiles(id),
 observed_at timestamptz not null default now(),
 observation jsonb not null
);
alter table public.product_health_observations enable row level security;
revoke all on public.product_health_observations from public,anon,authenticated;
create function public.product_command(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.applications; result jsonb; v_owner uuid; removed integer:=0;
begin
 perform 1 from public.profiles where id=p_actor and platform_role='super_admin' and status='active' for update;
 if not found then raise exception 'Platform administrator required' using errcode='42501';end if;
 if p_action in ('list','read') then
  if p_data->>'afterCode' is not null and p_data->>'afterCode'!~'^[A-Z][A-Z0-9_]{1,39}$' then raise exception 'Invalid cursor' using errcode='22023';end if;
  result:=coalesce((select jsonb_agg(x) from(select prod.id,prod.code,prod.name,prod.login_path,prod.status,prod.version,prod.description,prod.owner_id,prod.support_email,prod.docs_url,prod.visibility,prod.integration_mode,p.full_name owner_name,h.observation latest_health,h.observed_at health_observed_at from public.applications prod left join public.profiles p on p.id=prod.owner_id left join public.product_health_observations h on h.application_id=prod.id where (p_action='read' and prod.id=p_id) or (p_action='list' and (p_data->>'afterCode' is null or prod.code>p_data->>'afterCode')) order by prod.code limit 100)x),'[]');
  if p_action='read' then if jsonb_array_length(result)=0 then raise exception 'Product missing' using errcode='P0002';end if;return result->0;end if;return result;
 elsif p_action='probe' then
  select * into a from public.applications where id=p_id for update;
  if not found then raise exception 'Product missing' using errcode='P0002';end if;
  if a.version is distinct from (p_data->>'version')::integer then raise exception 'Product changed during check' using errcode='40001';end if;
  if coalesce(p_data->>'state','') not in ('configured','reachable','degraded','unavailable') or p_data->'verified' is distinct from 'false'::jsonb then raise exception 'Unsupported health claim' using errcode='22023';end if;
  insert into public.product_health_observations(application_id,observed_by,observation) values(a.id,p_actor,p_data-'version') on conflict(application_id) do update set observed_by=excluded.observed_by,observed_at=now(),observation=excluded.observation;
  return '{"ok":true}';
 elsif p_action in ('create','update') then
  if p_id is null or jsonb_typeof(p_data) is distinct from 'object' or exists(select 1 from jsonb_object_keys(p_data) k where k not in ('code','name','loginPath','status','version','description','ownerId','supportEmail','docsUrl','visibility','integrationMode')) then raise exception 'Invalid fields' using errcode='22023';end if;
  if coalesce(p_data->>'code','')!~'^[A-Z][A-Z0-9_]{1,39}$' or length(coalesce(p_data->>'name','')) not between 1 and 150 or
   coalesce(p_data->>'loginPath','')<>('/apps/'||lower(p_data->>'code')||'/login') or
   coalesce(p_data->>'status','') not in ('active','disabled','maintenance','retired') or
   length(coalesce(p_data->>'description',''))>2000 or coalesce(p_data->>'visibility','') not in ('listed','unlisted') or
   coalesce(p_data->>'integrationMode','') not in ('adapter','portal_only') or
   (nullif(p_data->>'supportEmail','') is not null and (length(p_data->>'supportEmail')>190 or p_data->>'supportEmail'!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$')) or
   (nullif(p_data->>'docsUrl','') is not null and (length(p_data->>'docsUrl')>1000 or p_data->>'docsUrl'!~'^https://[a-zA-Z0-9][a-zA-Z0-9.-]+(:[0-9]+)?(/[^[:space:]]*)?$' or p_data->>'docsUrl'~'[<>"\\]')) then raise exception 'Invalid metadata' using errcode='22023';end if;
  v_owner:=nullif(p_data->>'ownerId','')::uuid;
  if v_owner is not null and not exists(select 1 from public.profiles where id=v_owner and status='active') then raise exception 'Active owner required' using errcode='22023';end if;
  select * into a from public.applications where id=p_id for update;
  if p_action='create' then
   if found then
    if a.created_by=p_actor and a.creation_hash=md5(p_data::text) then return jsonb_build_object('id',a.id);end if;
    raise exception 'Create conflict' using errcode='23505';
   end if;
   insert into public.applications(id,code,name,login_path,status,description,owner_id,support_email,docs_url,visibility,integration_mode,created_by,creation_hash)
    values(p_id,p_data->>'code',p_data->>'name',p_data->>'loginPath',p_data->>'status',coalesce(p_data->>'description',''),v_owner,nullif(p_data->>'supportEmail',''),nullif(p_data->>'docsUrl',''),p_data->>'visibility',p_data->>'integrationMode',p_actor,md5(p_data::text)) returning * into a;
   insert into public.app_roles(application_id,code,name) select a.id,r,r from unnest(array['super_admin','admin','manager','user','viewer']) r;
  else
   if not found then raise exception 'Product missing' using errcode='P0002';end if;
   if a.version is distinct from (p_data->>'version')::integer then raise exception 'Reload product' using errcode='40001';end if;
   if a.code<>p_data->>'code' or (a.status='retired' and p_data->>'status'<>'retired') then raise exception 'Code immutable; retirement terminal' using errcode='22023';end if;
   if a.code in ('CRM','MUSIC') and p_data->>'integrationMode'<>'adapter' then raise exception 'Reviewed built-in adapter required' using errcode='22023';end if;
   update public.applications set name=p_data->>'name',login_path=p_data->>'loginPath',status=p_data->>'status',description=coalesce(p_data->>'description',''),owner_id=v_owner,support_email=nullif(p_data->>'supportEmail',''),docs_url=nullif(p_data->>'docsUrl',''),visibility=p_data->>'visibility',integration_mode=p_data->>'integrationMode',version=version+1 where id=a.id;
   if p_data->>'status'<>'active' then
    delete from public.app_sessions where application_id=a.id;get diagnostics removed=row_count;
    delete from public.sso_launch_codes where application_id=a.id;
   end if;
  end if;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,details) values(p_actor,'product.'||p_action,'application',a.id::text,jsonb_build_object('before',case when p_action='update' then to_jsonb(a)-'creation_hash' else null end,'requested',p_data,'revoked_product_sessions',removed));
  return jsonb_build_object('id',a.id);
 end if;
 raise exception 'Invalid command' using errcode='22023';
end$$;
revoke all on function public.product_command(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.product_command(uuid,text,uuid,jsonb) to service_role;

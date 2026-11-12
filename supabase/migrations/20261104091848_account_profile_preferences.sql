-- Self-owned presentation only. Never changes identity email, status or permissions.
create table public.account_profile_preferences(
 user_id uuid primary key references public.profiles(id),
 bio text not null default '' check(length(bio)<=500 and replace(bio,chr(10),'')!~'[[:cntrl:]]'),
 time_zone text not null default 'Asia/Kolkata' check(length(time_zone)<=100),
 avatar_tone text not null default 'navy' check(avatar_tone in ('navy','blue','slate')),
 version integer not null default 1 check(version>0),
 updated_at timestamptz not null default now()
);
alter table public.account_profile_preferences enable row level security;
revoke all on public.account_profile_preferences from public,anon,authenticated;
grant select,insert,update,delete on public.account_profile_preferences to service_role;
create function public.account_profile(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor public.profiles; settings public.account_profile_preferences; expected integer; result jsonb;
begin
 if p_action is null or p_action not in ('get','save') or p_id is not null or jsonb_typeof(p_data) is distinct from 'object' then raise exception 'Invalid profile command' using errcode='22023';end if;
 if exists(select 1 from jsonb_object_keys(p_data) k where k not in ('currentHash','displayName','bio','timeZone','avatarTone','version')) then raise exception 'Invalid profile fields' using errcode='22023';end if;
 -- Same profile -> session order as current identity consent and revocation.
 select * into actor from public.profiles where id=p_actor and status='active' for update;
 if not found then raise exception 'Active identity required' using errcode='42501';end if;
 perform 1 from public.portal_sessions where user_id=p_actor and token_hash=p_data->>'currentHash' and expires_at>clock_timestamp() for share;
 if not found then raise exception 'Current session required' using errcode='42501';end if;
 select * into settings from public.account_profile_preferences where user_id=p_actor for update;
 if p_action='save' then
  if (select count(*) from jsonb_object_keys(p_data))<>6 or
   jsonb_typeof(p_data->'displayName') is distinct from 'string' or length(btrim(p_data->>'displayName')) not between 1 and 150 or p_data->>'displayName'~'[[:cntrl:]]' or
   jsonb_typeof(p_data->'bio') is distinct from 'string' or length(p_data->>'bio')>500 or replace(p_data->>'bio',chr(10),'')~'[[:cntrl:]]' or
   jsonb_typeof(p_data->'timeZone') is distinct from 'string' or not exists(select 1 from pg_catalog.pg_timezone_names where name=p_data->>'timeZone') or
   jsonb_typeof(p_data->'avatarTone') is distinct from 'string' or p_data->>'avatarTone' not in ('navy','blue','slate') or
   jsonb_typeof(p_data->'version') is distinct from 'number' or coalesce(p_data->>'version','')!~'^(0|[1-9][0-9]{0,9})$' then raise exception 'Invalid profile values' using errcode='22023';end if;
  if (p_data->>'version')::numeric>2147483646 then raise exception 'Invalid profile version' using errcode='22023';end if;
  expected:=(p_data->>'version')::integer;
  if expected is distinct from coalesce(settings.version,0) then raise exception 'Profile changed; reload' using errcode='40001';end if;
  update public.profiles set full_name=btrim(p_data->>'displayName') where id=p_actor;
  insert into public.account_profile_preferences(user_id,bio,time_zone,avatar_tone)
   values(p_actor,p_data->>'bio',p_data->>'timeZone',p_data->>'avatarTone')
   on conflict(user_id) do update set bio=excluded.bio,time_zone=excluded.time_zone,avatar_tone=excluded.avatar_tone,version=account_profile_preferences.version+1,updated_at=now()
   returning * into settings;
  actor.full_name:=btrim(p_data->>'displayName');
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,details) values(p_actor,'account.profile_updated','profile',p_actor::text,jsonb_build_object('version',settings.version,'fields',array['displayName','bio','timeZone','avatarTone']));
 elsif (select count(*) from jsonb_object_keys(p_data))<>1 then raise exception 'Invalid profile read fields' using errcode='22023';
 end if;
 return jsonb_build_object('displayName',actor.full_name,'email',actor.email,'platformRole',actor.platform_role,'bio',coalesce(settings.bio,''),'timeZone',coalesce(settings.time_zone,'Asia/Kolkata'),'avatarTone',coalesce(settings.avatar_tone,'navy'),'version',coalesce(settings.version,0),'updatedAt',coalesce(settings.updated_at,actor.created_at));
end$$;
revoke all on function public.account_profile(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.account_profile(uuid,text,uuid,jsonb) to service_role;

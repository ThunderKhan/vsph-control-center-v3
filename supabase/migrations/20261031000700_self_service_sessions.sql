-- Safe public identifiers replace exposing token hashes in account/session UI.
alter table public.portal_sessions add column public_id uuid not null default gen_random_uuid();
create unique index portal_sessions_public_id on public.portal_sessions(public_id);
create function public.session_command(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare n integer;
begin
 perform 1 from public.profiles where id=p_actor and status='active' for update;
 if not found then raise exception 'Account unavailable' using errcode='42501';end if;
 perform 1 from public.portal_sessions where user_id=p_actor and token_hash=p_data->>'currentHash' and expires_at>now() for share;
 if not found then raise exception 'Session unavailable' using errcode='42501';end if;
 if p_action='list' then
  return jsonb_build_object('sessions',coalesce((select jsonb_agg(x) from (select public_id id,created_at,expires_at,token_hash=p_data->>'currentHash' current_session from public.portal_sessions where user_id=p_actor and expires_at>now() order by (token_hash=p_data->>'currentHash') desc,created_at desc limit 100) x),'[]'));
 elsif p_action='revoke' then
  delete from public.portal_sessions where user_id=p_actor and public_id=p_id and token_hash<>p_data->>'currentHash';
 elsif p_action='revoke_others' then
  delete from public.portal_sessions where user_id=p_actor and token_hash<>p_data->>'currentHash';
 else raise exception 'Unknown session action' using errcode='22023';end if;
 get diagnostics n=row_count;
 insert into public.audit_logs(actor_user_id,action,target_type,target_id,details) values(p_actor,'session.'||p_action,'profile',p_actor::text,jsonb_build_object('revoked_count',n));
 return jsonb_build_object('revoked',n);
end$$;
revoke all on function public.session_command(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.session_command(uuid,text,uuid,jsonb) to service_role;

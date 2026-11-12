-- Forward-only function addition. Apply after the two historical Music migrations.
-- No production rows are changed by installing this function.
create or replace function public.set_profile_status(
 p_actor uuid, p_target uuid, p_status text
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
 v_previous text;
 v_role text;
 v_sessions integer := 0;
 v_codes integer := 0;
begin
 if p_status is null or p_status not in ('active','disabled') then
  raise exception 'Invalid account status' using errcode = '22023';
 end if;
 -- Recheck the actor in the same transaction as the mutation, not just HTTP middleware.
 perform 1 from public.profiles where id=p_actor and status='active'
  and platform_role='super_admin' for update;
 if not found then raise exception 'Platform administrator required' using errcode='42501'; end if;
 if p_actor=p_target and p_status='disabled' then
  raise exception 'Self-disable is not permitted' using errcode='22023';
 end if;
 select status, platform_role into v_previous, v_role from public.profiles where id=p_target for update;
 if not found then raise exception 'Account not found' using errcode='P0002'; end if;
 if v_role='super_admin' then
  raise exception 'Platform administrator lifecycle requires governed recovery' using errcode='VS001';
 end if;
 if p_status='disabled' then
  delete from public.portal_sessions where user_id=p_target;
  get diagnostics v_sessions = row_count;
  -- app_sessions cascade through portal_sessions; outstanding Music codes do not have that FK.
  delete from public.sso_launch_codes where user_id=p_target;
  get diagnostics v_codes = row_count;
 end if;
 if v_previous=p_status and v_sessions=0 and v_codes=0 then return p_target; end if;
 update public.profiles set status=p_status where id=p_target;
 insert into public.audit_logs(actor_user_id,action,target_type,target_id,details)
 values(p_actor,'user.status_changed','user',p_target::text,
  jsonb_build_object('before_status',v_previous,'status',p_status,
   'revoked_portal_sessions',v_sessions,'revoked_launch_codes',v_codes));
 return p_target;
end;
$$;
revoke all on function public.set_profile_status(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.set_profile_status(uuid,uuid,text) to service_role;

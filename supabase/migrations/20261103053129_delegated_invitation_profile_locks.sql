-- A queued invitation to an existing identity has no user_id until worker bind.
-- Resolve that recipient by its stable email before the core takes actor locks.
-- Keep prior source/checksums immutable and repair forward.
alter function public.organization_invitation(uuid,text,uuid,jsonb) rename to organization_invitation_core;
create function public.organization_invitation(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare recipient uuid;
begin
 if p_action='queue' then
  select id into recipient from public.profiles where email=p_data->'request'->>'adminEmail';
 elsif p_action in ('cancel','reissue') then
  select coalesce(i.user_id,p.id) into recipient from public.membership_invitations i left join public.profiles p on p.email=i.email where i.id=(p_data->>'invitationId')::uuid;
 end if;
 perform 1 from public.profiles where id=p_actor or id=recipient order by (platform_role='super_admin') desc,id for update;
 return public.organization_invitation_core(p_actor,p_action,p_id,p_data);
end$$;
revoke all on function public.organization_invitation(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.organization_invitation(uuid,text,uuid,jsonb) to service_role;

create table public.organization_owner_transfer_grants(
 token_hash text primary key check(token_hash~'^[0-9a-f]{64}$'),
 session_hash text not null references public.portal_sessions(token_hash) on delete cascade,
 organization_id uuid not null references public.organizations(id) on delete cascade,
 actor_user_id uuid not null references public.profiles(id) on delete cascade,
 target_user_id uuid not null references public.profiles(id) on delete cascade,
 organization_version integer not null check(organization_version>0),
 owner_version integer not null check(owner_version>0),target_version integer not null check(target_version>0),
 assurance text not null check(assurance in ('aal1','aal2')),
 verified_at timestamptz not null,expires_at timestamptz not null,
 consumed_at timestamptz,revoked_at timestamptz,
 check(actor_user_id<>target_user_id),check(expires_at>verified_at)
);
create index organization_owner_transfer_grants_session on public.organization_owner_transfer_grants(session_hash);
create index organization_owner_transfer_grants_expiry on public.organization_owner_transfer_grants(actor_user_id,expires_at);
alter table public.organization_owner_transfer_grants enable row level security;
revoke all on public.organization_owner_transfer_grants from public,anon,authenticated;
grant select,insert,update,delete on public.organization_owner_transfer_grants to service_role;

create function public.organization_ownership(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare target_id uuid; org public.organizations; owner_member public.organization_memberships;
 target_member public.organization_memberships; portal public.portal_sessions;
 proof public.organization_owner_transfer_grants; verified_time timestamptz; expiration timestamptz;
begin
 if p_action not in ('preview','authorize','transfer') or jsonb_typeof(p_data) is distinct from 'object' then raise exception 'Invalid ownership command' using errcode='22023';end if;
 if exists(select 1 from jsonb_object_keys(p_data) k where k not in ('currentHash','targetUserId','organizationVersion','ownerVersion','targetVersion','proofHash','assurance','verifiedAt','confirmed')) then raise exception 'Invalid ownership fields' using errcode='22023';end if;
 target_id:=(p_data->>'targetUserId')::uuid;
 if target_id is null or target_id=p_actor then raise exception 'Choose another existing administrator' using errcode='22023';end if;
 -- Global profile ordering precedes session, organization and membership locks.
 perform 1 from public.profiles where id=p_actor or id=target_id order by (platform_role='super_admin') desc,id for update;
 perform 1 from public.profiles where id=p_actor and status='active';
 if not found then raise exception 'Active owner required' using errcode='42501';end if;
 perform 1 from public.profiles where id=target_id and status='active' and platform_role='user';
 if not found then raise exception 'Target requires account governance' using errcode='42501';end if;
 select * into portal from public.portal_sessions where token_hash=p_data->>'currentHash' and user_id=p_actor and expires_at>clock_timestamp() for share;
 if not found then raise exception 'Current session unavailable' using errcode='42501';end if;
 select * into org from public.organizations where id=p_id and status='active' for no key update;
 if not found then raise exception 'Organization unavailable' using errcode='42501';end if;
 select * into owner_member from public.organization_memberships where organization_id=p_id and user_id=p_actor and role='owner' and status='active' for update;
 if not found then raise exception 'Current owner required' using errcode='42501';end if;
 if (select count(*) from public.organization_memberships where organization_id=p_id and role='owner' and status='active')<>1 then raise exception 'Multiple owners require platform review' using errcode='40001';end if;
 select * into target_member from public.organization_memberships where organization_id=p_id and user_id=target_id and role='admin' and status='active' for update;
 if not found then raise exception 'Accepted active administrator required' using errcode='42501';end if;
 if p_action='preview' then
  return jsonb_build_object('organizationId',p_id,'organizationVersion',org.version,'ownerVersion',owner_member.version,'targetVersion',target_member.version,'targetUserId',target_id,'targetName',(select full_name from public.profiles where id=target_id),'targetEmail',(select email from public.profiles where id=target_id),'previousOwnerRole','admin');
 end if;
 if (p_data->>'organizationVersion')::integer is distinct from org.version or (p_data->>'ownerVersion')::integer is distinct from owner_member.version or (p_data->>'targetVersion')::integer is distinct from target_member.version then raise exception 'Ownership review is stale' using errcode='40001';end if;
 if coalesce(p_data->>'proofHash','')!~'^[0-9a-f]{64}$' then raise exception 'Invalid step-up proof' using errcode='22023';end if;
 if p_action='authorize' then
  verified_time:=(p_data->>'verifiedAt')::timestamptz;
  -- Only the server credential verifier may attest this time/assurance; browser
  -- execution is denied and HTTP callers cannot supply these trusted fields.
  if verified_time is null or verified_time<clock_timestamp()-interval '30 seconds' or verified_time>clock_timestamp()+interval '5 seconds' or coalesce(p_data->>'assurance','') not in ('aal1','aal2') then raise exception 'Fresh authentication required' using errcode='42501';end if;
  expiration:=least(clock_timestamp()+interval '2 minutes',portal.expires_at);
  delete from public.organization_owner_transfer_grants where token_hash in(select token_hash from public.organization_owner_transfer_grants where actor_user_id=p_actor and expires_at<=clock_timestamp() order by expires_at limit 1000);
  update public.organization_owner_transfer_grants set revoked_at=clock_timestamp() where actor_user_id=p_actor and organization_id=p_id and session_hash=portal.token_hash and consumed_at is null and revoked_at is null;
  insert into public.organization_owner_transfer_grants(token_hash,session_hash,organization_id,actor_user_id,target_user_id,organization_version,owner_version,target_version,assurance,verified_at,expires_at)
   values(p_data->>'proofHash',portal.token_hash,p_id,p_actor,target_id,org.version,owner_member.version,target_member.version,p_data->>'assurance',verified_time,expiration);
  insert into public.audit_logs(actor_user_id,organization_id,action,target_type,target_id,details) values(p_actor,p_id,'organization.owner_transfer_authorized','membership',target_id::text,jsonb_build_object('assurance',p_data->>'assurance','expiresAt',expiration));
  return jsonb_build_object('expiresAt',expiration);
 end if;
 if p_data->'confirmed' is distinct from 'true'::jsonb then raise exception 'Explicit ownership confirmation required' using errcode='22023';end if;
 select * into proof from public.organization_owner_transfer_grants where token_hash=p_data->>'proofHash' and session_hash=portal.token_hash and actor_user_id=p_actor and organization_id=p_id and target_user_id=target_id and organization_version=org.version and owner_version=owner_member.version and target_version=target_member.version and consumed_at is null and revoked_at is null and expires_at>clock_timestamp() for update;
 if not found or portal.expires_at<=clock_timestamp() then raise exception 'Step-up proof expired, revoked or unavailable' using errcode='42501';end if;
 update public.organization_memberships set role='owner',version=version+1 where organization_id=p_id and user_id=target_id;
 update public.organization_memberships set role='admin',version=version+1 where organization_id=p_id and user_id=p_actor;
 update public.organizations set version=version+1 where id=p_id;
 update public.organization_owner_transfer_grants set consumed_at=clock_timestamp() where token_hash=proof.token_hash;
 update public.organization_owner_transfer_grants set revoked_at=clock_timestamp() where organization_id=p_id and token_hash<>proof.token_hash and consumed_at is null and revoked_at is null;
 delete from public.app_sessions where organization_id=p_id and user_id in (p_actor,target_id);
 delete from public.sso_launch_codes where organization_id=p_id and user_id in (p_actor,target_id);
 insert into public.audit_logs(actor_user_id,organization_id,action,target_type,target_id,details) values(p_actor,p_id,'organization.owner_transferred','organization',p_id::text,jsonb_build_object('previousOwnerId',p_actor,'newOwnerId',target_id,'assurance',proof.assurance,'beforeOrganizationVersion',org.version));
 return jsonb_build_object('organizationVersion',org.version+1,'ownerId',target_id,'previousOwnerRole','admin');
end$$;
revoke all on function public.organization_ownership(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.organization_ownership(uuid,text,uuid,jsonb) to service_role;

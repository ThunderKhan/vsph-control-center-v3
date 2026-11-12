-- New Music-only staff and musician roles; apply after PR #5 migration.
-- The existing user_app_roles foreign key validates that role belongs to the app.
alter table public.app_roles
  drop constraint if exists app_roles_code_check;
alter table public.app_roles
  add constraint app_roles_code_check check (
    code in ('super_admin','admin','manager','user','viewer','staff','musician')
  );

insert into public.app_roles (application_id,code,name)
select id,role.code,role.name
from public.applications
cross join (values ('staff','Music staff'),('musician','Musician')) role(code,name)
where public.applications.code='MUSIC'
on conflict (application_id,code) do nothing;

-- No new session tables or browser-exposed credentials.

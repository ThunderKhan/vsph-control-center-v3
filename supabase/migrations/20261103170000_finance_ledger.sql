-- Phase 1: owner-only, manually recorded INR receivables/cash ledger.
-- Amounts are integer paise, not floats. Subscription entitlement is NOT a payment.
-- No imported ledger rows, external payment provider, or automated recognition.
create table public.finance_invoices(
 id uuid primary key default gen_random_uuid(),
 idempotency_key uuid not null unique,
 request_hash text not null check(request_hash ~ '^[0-9a-f]{32}$'),
 reference text not null unique check(length(btrim(reference)) between 3 and 80),
 organization_id uuid not null references public.organizations(id),
 project_id uuid references public.projects(id),
 amount_paise bigint not null check(amount_paise between 1 and 1000000000000),
 currency text not null default 'INR' check(currency='INR'),
 issued_on date not null,
 due_on date not null,
 status text not null default 'issued' check(status in ('issued','void')),
 version integer not null default 1 check(version>0),
 created_by uuid not null references public.profiles(id),
 created_at timestamptz not null default now(),
 voided_at timestamptz,
 void_reason text,
 constraint finance_invoice_dates check(due_on>=issued_on),
 constraint finance_void_fields check((status='void')=(voided_at is not null))
);
create index finance_invoices_organization on public.finance_invoices(organization_id,status,due_on);
create index finance_invoices_project on public.finance_invoices(project_id,status);
create table public.finance_payments(
 id uuid primary key default gen_random_uuid(),
 idempotency_key uuid not null unique,
 request_hash text not null check(request_hash ~ '^[0-9a-f]{32}$'),
 invoice_id uuid not null references public.finance_invoices(id),
 reference text not null unique check(length(btrim(reference)) between 3 and 100),
 amount_paise bigint not null check(amount_paise between 1 and 1000000000000),
 received_on date not null,
 recorded_by uuid not null references public.profiles(id),
 recorded_at timestamptz not null default now()
);
create index finance_payments_invoice on public.finance_payments(invoice_id);
create index finance_payments_received on public.finance_payments(received_on,invoice_id);
create table public.finance_payment_reversals(
 payment_id uuid primary key references public.finance_payments(id),
 reason text not null check(length(btrim(reason)) between 8 and 300),
 reversed_by uuid not null references public.profiles(id),
 reversed_at timestamptz not null default now()
);
do $$declare t text;begin
 foreach t in array array['finance_invoices','finance_payments','finance_payment_reversals'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from public,anon,authenticated',t);
  execute format('grant select,insert,update,delete on public.%I to service_role',t);
 end loop;
end$$;

create function public.finance_command(
 p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}'
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
 actor public.profiles;
 invoice public.finance_invoices;
 payment public.finance_payments;
 saved public.finance_payment_reversals;
 normalized text;
 digest text;
 amount bigint;
 active_paid bigint;
 expected_version integer;
 summary jsonb;
 clients jsonb;
 projects jsonb;
 months jsonb;
 invoices jsonb;
 result jsonb;
 begin_day date;
 end_day date;
begin
 if p_action not in ('dashboard','invoice.create','payment.record','payment.reverse','invoice.void')
  or jsonb_typeof(p_data) is distinct from 'object' then
  raise exception 'Invalid finance command' using errcode='22023';
 end if;
 select * into actor from public.profiles
 where id=p_actor and status='active' and platform_role='super_admin' for share;
 if not found then raise exception 'Only an active VSPH platform owner may manage finance' using errcode='42501';end if;

 if p_action='dashboard' then
  if p_id is not null or p_data<>'{}'::jsonb then raise exception 'Invalid report fields' using errcode='22023';end if;
  with balance as (
   select i.id,i.amount_paise,i.status,i.due_on,i.organization_id,i.project_id,
    coalesce((select sum(p.amount_paise) from public.finance_payments p
     where p.invoice_id=i.id and not exists(
       select 1 from public.finance_payment_reversals r where r.payment_id=p.id)),0)::bigint collected
   from public.finance_invoices i
  )
  select jsonb_build_object(
   'invoicedPaise',coalesce(sum(amount_paise) filter(where status='issued'),0),
   'collectedPaise',coalesce(sum(collected) filter(where status='issued'),0),
   'outstandingPaise',coalesce(sum(amount_paise-collected) filter(where status='issued'),0),
   'pastDuePaise',coalesce(sum(amount_paise-collected) filter(where status='issued' and due_on<current_date),0),
   'issuedInvoices',count(*) filter(where status='issued'),
   'voidInvoices',count(*) filter(where status='void'),
   'clients',count(distinct organization_id) filter(where status='issued'),
   'projects',count(distinct project_id) filter(where status='issued' and project_id is not null)
  ) into summary from balance;
  with balances as (
   select i.organization_id,i.amount_paise,
    coalesce((select sum(p.amount_paise) from public.finance_payments p
     where p.invoice_id=i.id and not exists(select 1 from public.finance_payment_reversals r where r.payment_id=p.id)),0)::bigint collected
   from public.finance_invoices i where i.status='issued'
  )
  select coalesce(jsonb_agg(to_jsonb(x) order by x.collected_paise desc,x.organization_name),'[]'::jsonb) into clients
  from (select o.id organization_id,o.name organization_name,sum(b.amount_paise)::bigint invoiced_paise,
    sum(b.collected)::bigint collected_paise,sum(b.amount_paise-b.collected)::bigint outstanding_paise
    from balances b join public.organizations o on o.id=b.organization_id
    group by o.id,o.name order by sum(b.collected) desc,o.name limit 20) x;
  with balances as (
   select i.project_id,i.amount_paise,
    coalesce((select sum(p.amount_paise) from public.finance_payments p
      where p.invoice_id=i.id and not exists(select 1 from public.finance_payment_reversals r where r.payment_id=p.id)),0)::bigint collected
   from public.finance_invoices i where i.status='issued' and i.project_id is not null
  )
  select coalesce(jsonb_agg(to_jsonb(x) order by x.collected_paise desc,x.project_name),'[]'::jsonb) into projects
  from (select pr.id project_id,pr.name project_name,sum(b.amount_paise)::bigint invoiced_paise,
    sum(b.collected)::bigint collected_paise,sum(b.amount_paise-b.collected)::bigint outstanding_paise
    from balances b join public.projects pr on pr.id=b.project_id
    group by pr.id,pr.name order by sum(b.collected) desc,pr.name limit 20) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.month_start),'[]'::jsonb) into months
  from (select gs::date month_start,coalesce(sum(p.amount_paise),0)::bigint collected_paise
   from generate_series(date_trunc('month',current_date)-interval '5 months',
      date_trunc('month',current_date), interval '1 month') gs
   left join public.finance_payments p
    on p.received_on>=gs::date and p.received_on<(gs+interval '1 month')::date
    and not exists(select 1 from public.finance_payment_reversals r where r.payment_id=p.id)
    and exists(select 1 from public.finance_invoices i where i.id=p.invoice_id and i.status='issued')
   group by gs order by gs) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id desc),'[]'::jsonb) into invoices
  from (select i.id,i.reference,i.organization_id,o.name organization_name,
    i.project_id,pr.name project_name,i.amount_paise,i.currency,i.issued_on,i.due_on,
    i.status,i.version,i.created_at,
    coalesce((select sum(p.amount_paise) from public.finance_payments p where p.invoice_id=i.id
      and not exists(select 1 from public.finance_payment_reversals r where r.payment_id=p.id)),0)::bigint collected_paise
    from public.finance_invoices i
    join public.organizations o on o.id=i.organization_id
    left join public.projects pr on pr.id=i.project_id
    order by i.created_at desc,i.id desc limit 50) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.recorded_at desc,x.id desc),'[]'::jsonb) into result
  from (select p.id,p.invoice_id,i.reference invoice_reference,p.reference payment_reference,
   p.amount_paise,p.received_on,p.recorded_at,
   exists(select 1 from public.finance_payment_reversals r where r.payment_id=p.id) reversed
   from public.finance_payments p join public.finance_invoices i on i.id=p.invoice_id
   order by p.recorded_at desc,p.id desc limit 50) x;
  return jsonb_build_object('summary',summary,'byClient',clients,'byProject',projects,
    'monthly',months,'invoices',invoices,'payments',result,'currency','INR','basis','manual_cash_receipts',
    'asOf',current_date);
 end if;

 if p_action='invoice.create' then
  if p_id is null or (select count(*) from jsonb_object_keys(p_data))<>6 or
   exists(select 1 from jsonb_object_keys(p_data) k where k not in
      ('reference','organizationId','projectId','amountPaise','issuedOn','dueOn')) then
    raise exception 'Invalid invoice fields' using errcode='22023';
  end if;
  normalized:=upper(btrim(p_data->>'reference'));
  if length(normalized) not between 3 and 80 or normalized!~'^[A-Z0-9][A-Z0-9/_-]+$'
    or coalesce(p_data->>'amountPaise','')!~'^[1-9][0-9]{0,12}$'
    or coalesce(p_data->>'issuedOn','')!~'^\d{4}-\d{2}-\d{2}$'
    or coalesce(p_data->>'dueOn','')!~'^\d{4}-\d{2}-\d{2}$'
    or coalesce(p_data->>'organizationId','')!~'^[0-9a-fA-F-]{36}$'
    or (p_data->>'projectId' is not null and p_data->>'projectId'!~'^[0-9a-fA-F-]{36}$') then
    raise exception 'Invalid invoice data' using errcode='22023';
  end if;
  amount:=(p_data->>'amountPaise')::bigint;
  begin_day:=(p_data->>'issuedOn')::date;
  end_day:=(p_data->>'dueOn')::date;
  if amount>1000000000000 or end_day<begin_day then raise exception 'Invalid invoice amount or dates' using errcode='22023';end if;
  digest:=md5(jsonb_build_object('reference',normalized,'organizationId',p_data->>'organizationId',
    'projectId',p_data->>'projectId','amountPaise',amount,'issuedOn',begin_day,'dueOn',end_day)::text);
  perform pg_advisory_xact_lock(hashtextextended('fin-invoice:'||p_id::text,0));
  select * into invoice from public.finance_invoices where idempotency_key=p_id for update;
  if found then
   if invoice.request_hash<>digest then raise exception 'Idempotency key reused with new values' using errcode='23505';end if;
   return jsonb_build_object('id',invoice.id,'version',invoice.version,'replayed',true);
  end if;
  perform 1 from public.organizations where id=(p_data->>'organizationId')::uuid and status='active';
  if not found then raise exception 'Active customer organization required' using errcode='42501';end if;
  if p_data->>'projectId' is not null then
   perform 1 from public.projects where id=(p_data->>'projectId')::uuid and kind='customer'
      and customer_organization_id=(p_data->>'organizationId')::uuid;
   if not found then raise exception 'Project must belong to the invoiced customer' using errcode='42501';end if;
  end if;
  insert into public.finance_invoices(idempotency_key,request_hash,reference,
    organization_id,project_id,amount_paise,issued_on,due_on,created_by)
  values(p_id,digest,normalized,(p_data->>'organizationId')::uuid,
    (p_data->>'projectId')::uuid,amount,begin_day,end_day,p_actor)
  returning * into invoice;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,details)
   values(p_actor,'finance.invoice_created','finance_invoice',invoice.id::text,
     jsonb_build_object('reference',invoice.reference,'amountPaise',amount,
       'organizationId',invoice.organization_id,'projectId',invoice.project_id));
  return jsonb_build_object('id',invoice.id,'version',invoice.version,'replayed',false);
 end if;

 if p_action='payment.record' then
  if p_id is null or (select count(*) from jsonb_object_keys(p_data))<>4 or
   exists(select 1 from jsonb_object_keys(p_data) k where k not in
     ('idempotencyKey','reference','amountPaise','receivedOn')) or
   coalesce(p_data->>'reference','')!~'^[A-Za-z0-9][A-Za-z0-9/_-]{2,99}$' or
   coalesce(p_data->>'amountPaise','')!~'^[1-9][0-9]{0,12}$' or
   coalesce(p_data->>'receivedOn','')!~'^\d{4}-\d{2}-\d{2}$' or
   coalesce(p_data->>'idempotencyKey','')!~'^[0-9a-fA-F-]{36}$' then
   raise exception 'Invalid receipt fields' using errcode='22023';
  end if;
  amount:=(p_data->>'amountPaise')::bigint;
  begin_day:=(p_data->>'receivedOn')::date;
  if amount>1000000000000 or begin_day>current_date then raise exception 'Invalid payment amount/date' using errcode='22023';end if;
  normalized:=upper(btrim(p_data->>'reference'));
  digest:=md5(jsonb_build_object('invoiceId',p_id,'reference',normalized,'amountPaise',amount,'receivedOn',begin_day)::text);
  select * into invoice from public.finance_invoices where id=p_id for update;
  if not found then raise exception 'Invoice not found' using errcode='P0002';end if;
  select * into payment from public.finance_payments where idempotency_key=(p_data->>'idempotencyKey')::uuid for update;
  if found then
   if payment.request_hash<>digest then raise exception 'Idempotency key changed' using errcode='23505';end if;
   return jsonb_build_object('id',payment.id,'invoiceId',p_id,'replayed',true);
  end if;
  if invoice.status<>'issued' then raise exception 'Cannot collect against void invoice' using errcode='40001';end if;
  select coalesce(sum(p.amount_paise),0)::bigint into active_paid
  from public.finance_payments p where p.invoice_id=invoice.id
   and not exists(select 1 from public.finance_payment_reversals r where r.payment_id=p.id);
  if active_paid+amount>invoice.amount_paise then raise exception 'Receipt exceeds invoice balance' using errcode='23514';end if;
  insert into public.finance_payments(idempotency_key,request_hash,invoice_id,reference,
    amount_paise,received_on,recorded_by)
  values((p_data->>'idempotencyKey')::uuid,digest,invoice.id,normalized,amount,begin_day,p_actor)
  returning * into payment;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,details)
    values(p_actor,'finance.payment_recorded','finance_payment',payment.id::text,
     jsonb_build_object('invoiceId',invoice.id,'amountPaise',amount,'reference',payment.reference));
  return jsonb_build_object('id',payment.id,'invoiceId',invoice.id,'replayed',false);
 end if;

 if p_action='payment.reverse' then
  if p_id is null or (select count(*) from jsonb_object_keys(p_data))<>2
   or exists(select 1 from jsonb_object_keys(p_data) k where k not in ('reason','confirmed'))
   or p_data->'confirmed' is distinct from 'true'::jsonb or
   length(btrim(coalesce(p_data->>'reason',''))) not between 8 and 300 then
   raise exception 'Confirmed reversal reason required' using errcode='22023';
  end if;
  select * into payment from public.finance_payments where id=p_id;
  if not found then raise exception 'Receipt not found' using errcode='P0002';end if;
  select * into invoice from public.finance_invoices where id=payment.invoice_id for update;
  select * into payment from public.finance_payments where id=p_id for update;
  if exists(select 1 from public.finance_payment_reversals where payment_id=payment.id) then
    raise exception 'Receipt already reversed' using errcode='40001';end if;
  insert into public.finance_payment_reversals(payment_id,reason,reversed_by)
   values(payment.id,btrim(p_data->>'reason'),p_actor);
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,details)
   values(p_actor,'finance.payment_reversed','finance_payment',payment.id::text,
    jsonb_build_object('invoiceId',invoice.id,'amountPaise',payment.amount_paise));
  return jsonb_build_object('id',payment.id,'reversed',true);
 end if;

 if p_action='invoice.void' then
  if p_id is null or (select count(*) from jsonb_object_keys(p_data))<>3
   or exists(select 1 from jsonb_object_keys(p_data) k where k not in ('version','reason','confirmed'))
   or p_data->'confirmed' is distinct from 'true'::jsonb
   or coalesce(p_data->>'version','')!~'^[1-9][0-9]{0,8}$'
   or length(btrim(coalesce(p_data->>'reason',''))) not between 8 and 300 then
    raise exception 'Confirmed current invoice version and reason required' using errcode='22023';
  end if;
  expected_version:=(p_data->>'version')::integer;
  select * into invoice from public.finance_invoices where id=p_id for update;
  if not found then raise exception 'Invoice not found' using errcode='P0002';end if;
  if invoice.status<>'issued' or invoice.version<>expected_version then raise exception 'Stale or void invoice' using errcode='40001';end if;
  if exists(select 1 from public.finance_payments p where p.invoice_id=p_id
    and not exists(select 1 from public.finance_payment_reversals r where r.payment_id=p.id)) then
   raise exception 'Cannot void an invoice with unreversed receipts' using errcode='40001';
  end if;
  update public.finance_invoices set status='void',version=version+1,voided_at=now(),
    void_reason=btrim(p_data->>'reason') where id=p_id returning * into invoice;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,details)
   values(p_actor,'finance.invoice_voided','finance_invoice',invoice.id::text,
    jsonb_build_object('reason',invoice.void_reason));
  return jsonb_build_object('id',invoice.id,'status',invoice.status,'version',invoice.version);
 end if;
 raise exception 'Invalid finance action' using errcode='22023';
end;
$$;
revoke all on function public.finance_command(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.finance_command(uuid,text,uuid,jsonb) to service_role;

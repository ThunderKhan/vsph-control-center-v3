-- Additive report repair. Preserve invoice/payment/reversal rows and original write commands.
-- Requires finance_ledger; no Auth/provider changes or historical checksum edits.
-- STABLE fixes one caller snapshot for all sections. Monetary JSON uses decimal strings.
create function public.finance_report(
 p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}'
) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare summary jsonb; clients jsonb; projects jsonb; months jsonb; invoices jsonb; result jsonb;
begin
 if p_action is distinct from 'dashboard' or jsonb_typeof(p_data) is distinct from 'object' then
  raise exception 'Invalid report action' using errcode='22023';
 end if;
 if not exists(select 1 from public.profiles where id=p_actor and status='active' and platform_role='super_admin') then
  raise exception 'Only an active VSPH platform owner may read finance' using errcode='42501';
 end if;
  if p_id is not null or p_data<>'{}'::jsonb then raise exception 'Invalid report fields' using errcode='22023';end if;
  with balance as (
   select i.id,i.amount_paise,i.status,i.due_on,i.organization_id,i.project_id,
    coalesce((select sum(p.amount_paise) from public.finance_payments p
     where p.invoice_id=i.id and not exists(
       select 1 from public.finance_payment_reversals r where r.payment_id=p.id)),0)::bigint collected
   from public.finance_invoices i
  )
  select jsonb_build_object(
   'invoicedPaise',coalesce(sum(amount_paise) filter(where status='issued'),0)::text,
   'collectedPaise',coalesce(sum(collected) filter(where status='issued'),0)::text,
   'outstandingPaise',coalesce(sum(amount_paise-collected) filter(where status='issued'),0)::text,
   'pastDuePaise',coalesce(sum(amount_paise-collected) filter(where status='issued' and due_on<current_date),0)::text,
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
  select coalesce(jsonb_agg(to_jsonb(x) order by x.collected_paise::numeric desc,x.organization_name),'[]'::jsonb) into clients
  from (select o.id organization_id,o.name organization_name,sum(b.amount_paise)::text invoiced_paise,
    sum(b.collected)::text collected_paise,sum(b.amount_paise-b.collected)::text outstanding_paise
    from balances b join public.organizations o on o.id=b.organization_id
    group by o.id,o.name order by sum(b.collected) desc,o.name limit 20) x;
  with balances as (
   select i.project_id,i.amount_paise,
    coalesce((select sum(p.amount_paise) from public.finance_payments p
      where p.invoice_id=i.id and not exists(select 1 from public.finance_payment_reversals r where r.payment_id=p.id)),0)::bigint collected
   from public.finance_invoices i where i.status='issued' and i.project_id is not null
  )
  select coalesce(jsonb_agg(to_jsonb(x) order by x.collected_paise::numeric desc,x.project_name),'[]'::jsonb) into projects
  from (select pr.id project_id,pr.name project_name,sum(b.amount_paise)::text invoiced_paise,
    sum(b.collected)::text collected_paise,sum(b.amount_paise-b.collected)::text outstanding_paise
    from balances b join public.projects pr on pr.id=b.project_id
    group by pr.id,pr.name order by sum(b.collected) desc,pr.name limit 20) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.month_start),'[]'::jsonb) into months
  from (select gs::date month_start,coalesce(sum(p.amount_paise),0)::text collected_paise
   from generate_series(date_trunc('month',current_date)-interval '5 months',
      date_trunc('month',current_date), interval '1 month') gs
   left join public.finance_payments p
    on p.received_on>=gs::date and p.received_on<(gs+interval '1 month')::date
    and not exists(select 1 from public.finance_payment_reversals r where r.payment_id=p.id)
    and exists(select 1 from public.finance_invoices i where i.id=p.invoice_id and i.status='issued')
   group by gs order by gs) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id desc),'[]'::jsonb) into invoices
  from (select i.id,i.reference,i.organization_id,o.name organization_name,
    i.project_id,pr.name project_name,i.amount_paise::text,i.currency,i.issued_on,i.due_on,
    i.status,i.version,i.created_at,
    coalesce((select sum(p.amount_paise) from public.finance_payments p where p.invoice_id=i.id
      and not exists(select 1 from public.finance_payment_reversals r where r.payment_id=p.id)),0)::text collected_paise
    from public.finance_invoices i
    join public.organizations o on o.id=i.organization_id
    left join public.projects pr on pr.id=i.project_id
    order by i.created_at desc,i.id desc limit 50) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.recorded_at desc,x.id desc),'[]'::jsonb) into result
  from (select p.id,p.invoice_id,i.reference invoice_reference,p.reference payment_reference,
   p.amount_paise::text,p.received_on,p.recorded_at,
   exists(select 1 from public.finance_payment_reversals r where r.payment_id=p.id) reversed
   from public.finance_payments p join public.finance_invoices i on i.id=p.invoice_id
   order by p.recorded_at desc,p.id desc limit 50) x;
  return jsonb_build_object('summary',summary,'byClient',clients,'byProject',projects,
    'monthly',months,'invoices',invoices,'payments',result,'currency','INR','basis','manual_cash_receipts',
    'asOf',current_date);

end;
$$;
revoke all on function public.finance_report(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.finance_report(uuid,text,uuid,jsonb) to service_role;

-- Keep server-side legacy dashboard callers exact as well. Verify the prerequisite
-- body before replacing only the read branch; mutation/audit/locking code is untouched.
do $repair$
declare definition text; prior text; replacement text;
begin
 definition:=pg_get_functiondef('public.finance_command(uuid,text,uuid,jsonb)'::regprocedure);
 prior:=$prior$ if p_action='dashboard' then
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
$prior$;
 replacement:=$next$ if p_action='dashboard' then
  return public.finance_report(p_actor,p_action,p_id,p_data);
 end if;
$next$;
 if strpos(definition,prior)=0 then
  raise exception 'Unexpected finance prerequisite body; stop for reviewed reconciliation';
 end if;
 execute replace(definition,prior,replacement);
end;
$repair$;

-- Read-only owner journal. Additive indexes/RPC; no historical row/permission rewrite.
create index finance_invoices_journal_order on public.finance_invoices(created_at desc,id desc);
create index finance_invoices_journal_date on public.finance_invoices(issued_on,created_at desc,id desc);
create index finance_payments_journal_order on public.finance_payments(recorded_at desc,id desc);
create index finance_payments_journal_date on public.finance_payments(received_on,recorded_at desc,id desc);

create function public.finance_journal(p_actor uuid,p_action text,p_id uuid default null,p_data jsonb default '{}')
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare
 key text; filter_organization uuid; filter_project uuid; state text; search text;
 from_day date; to_day date; cursor_at timestamptz; cursor_id uuid; scope text;
 selected jsonb; items jsonb; last_item jsonb; cursor jsonb;
begin
 if not exists(select 1 from public.profiles where id=p_actor and platform_role='super_admin' and status='active') then
  raise exception 'Active platform owner required' using errcode='42501';
 end if;
 if p_action is null or p_action not in ('invoices','receipts') or p_id is not null or jsonb_typeof(p_data) is distinct from 'object' then
  raise exception 'Invalid journal command' using errcode='22023';
 end if;
 if exists(select 1 from jsonb_object_keys(p_data) k where k not in ('organizationId','projectId','status','search','from','to','cursor')) then
  raise exception 'Unknown journal field' using errcode='22023';
 end if;
 foreach key in array array['organizationId','projectId','status','search','from','to'] loop
  if p_data?key and jsonb_typeof(p_data->key) is distinct from 'string' then raise exception 'Invalid journal field type' using errcode='22023';end if;
 end loop;
 foreach key in array array['organizationId','projectId'] loop
  if p_data?key and p_data->>key !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then raise exception 'Invalid journal identifier' using errcode='22023';end if;
 end loop;
 foreach key in array array['from','to'] loop
  if p_data?key and p_data->>key !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Invalid journal date' using errcode='22023';end if;
 end loop;
 filter_organization:=(p_data->>'organizationId')::uuid;filter_project:=(p_data->>'projectId')::uuid;
 from_day:=(p_data->>'from')::date;to_day:=(p_data->>'to')::date;
 if from_day>to_day then raise exception 'Invalid date range' using errcode='22023';end if;
 state:=coalesce(p_data->>'status','all');search:=btrim(coalesce(p_data->>'search',''));
 if length(search)>100 or search~'[[:cntrl:]]' then raise exception 'Invalid journal search' using errcode='22023';end if;
 if (p_action='invoices' and state not in ('all','issued','void')) or (p_action='receipts' and state not in ('all','active','reversed')) then raise exception 'Invalid journal status' using errcode='22023';end if;
 -- Consistency fence, not a capability/signature. Actor and filters are always reauthorized.
 scope:=md5(jsonb_build_object('actor',p_actor,'kind',p_action,'organization',filter_organization,'project',filter_project,'status',state,'search',search,'from',from_day,'to',to_day)::text);
 if p_data?'cursor' then
  cursor:=p_data->'cursor';
  if jsonb_typeof(cursor) is distinct from 'object' then raise exception 'Invalid journal cursor' using errcode='22023';end if;
  if (select count(*) from jsonb_object_keys(cursor))<>3 or exists(select 1 from jsonb_object_keys(cursor) k where k not in ('at','id','scope')) then raise exception 'Invalid cursor fields' using errcode='22023';end if;
  if jsonb_typeof(cursor->'at') is distinct from 'string' or jsonb_typeof(cursor->'id') is distinct from 'string' or jsonb_typeof(cursor->'scope') is distinct from 'string' then raise exception 'Invalid cursor types' using errcode='22023';end if;
  if cursor->>'scope' is distinct from scope or cursor->>'id' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' or cursor->>'at' !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$' then raise exception 'Stale or invalid cursor' using errcode='22023';end if;
  begin cursor_at:=(cursor->>'at')::timestamptz;cursor_id:=(cursor->>'id')::uuid;
  exception when data_exception then raise exception 'Invalid cursor value' using errcode='22023';end;
 end if;
 if p_action='invoices' then
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id desc),'[]') into selected
  from(select i.id,i.reference,i.organization_id,o.name organization_name,i.project_id,pr.name project_name,
    i.amount_paise::text,i.currency,i.issued_on,i.due_on,i.status,i.version,i.created_at,
    coalesce((select sum(p.amount_paise) from public.finance_payments p where p.invoice_id=i.id and not exists(select 1 from public.finance_payment_reversals r where r.payment_id=p.id)),0)::text collected_paise
   from public.finance_invoices i join public.organizations o on o.id=i.organization_id left join public.projects pr on pr.id=i.project_id
   where (filter_organization is null or i.organization_id=filter_organization) and (filter_project is null or i.project_id=filter_project)
    and (state='all' or i.status=state) and (from_day is null or i.issued_on>=from_day) and (to_day is null or i.issued_on<=to_day)
    and (cursor_at is null or (i.created_at,i.id)<(cursor_at,cursor_id))
    and (search='' or position(lower(search) in lower(i.reference||' '||o.name||' '||coalesce(pr.name,'')))>0)
   order by i.created_at desc,i.id desc limit 26)x;
 else
  select coalesce(jsonb_agg(to_jsonb(x) order by x.recorded_at desc,x.id desc),'[]') into selected
  from(select p.id,p.invoice_id,i.reference invoice_reference,p.reference payment_reference,i.organization_id,o.name organization_name,i.project_id,pr.name project_name,
    p.amount_paise::text,p.received_on,p.recorded_at,
    exists(select 1 from public.finance_payment_reversals r where r.payment_id=p.id) reversed
   from public.finance_payments p join public.finance_invoices i on i.id=p.invoice_id
    join public.organizations o on o.id=i.organization_id left join public.projects pr on pr.id=i.project_id
   where (filter_organization is null or i.organization_id=filter_organization) and (filter_project is null or i.project_id=filter_project)
    and (state='all' or (state='reversed')=exists(select 1 from public.finance_payment_reversals r where r.payment_id=p.id))
    and (from_day is null or p.received_on>=from_day) and (to_day is null or p.received_on<=to_day)
    and (cursor_at is null or (p.recorded_at,p.id)<(cursor_at,cursor_id))
    and (search='' or position(lower(search) in lower(p.reference||' '||i.reference||' '||o.name||' '||coalesce(pr.name,'')))>0)
   order by p.recorded_at desc,p.id desc limit 26)x;
 end if;
 select coalesce(jsonb_agg(e.value order by e.ordinality),'[]') into items from jsonb_array_elements(selected) with ordinality e where e.ordinality<=25;
 last_item:=items->(jsonb_array_length(items)-1);
 return jsonb_build_object('items',items,'nextCursor',case when jsonb_array_length(selected)>25 then jsonb_build_object('at',case when p_action='invoices' then last_item->'created_at' else last_item->'recorded_at' end,'id',last_item->'id','scope',scope) else null end);
end$$;
revoke all on function public.finance_journal(uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.finance_journal(uuid,text,uuid,jsonb) to service_role;

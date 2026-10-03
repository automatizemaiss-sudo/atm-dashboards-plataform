begin;
alter table public.sales add constraint sale_amount_precision check(amount is null or amount=round(amount,2));
alter table public.sales add column reference text;
update public.sales set reference=id::text;
alter table public.sales alter column reference set not null;
alter table public.sales add constraint sales_reference_nonempty check(length(trim(reference))>0);
alter table public.sales add constraint sales_org_reference unique(organization_id,reference);
alter table public.sales add column notes text;
alter table public.sales add column voided boolean not null default false;
alter table public.sales add column version bigint not null default 1;
alter table public.sales add column updated_at timestamptz not null default now();
create function public.sale_version() returns trigger language plpgsql set search_path='' as $$ begin new.version=old.version+1;new.updated_at=now();return new;end; $$;
create trigger sale_version before update on public.sales for each row execute function public.sale_version();
create function public.sale_audit() returns trigger language plpgsql security definer set search_path='' as $$ begin
 insert into public.customer_events(organization_id,customer_id,event_type,old_value,new_value,source,user_id) values(new.organization_id,new.customer_id,'sale_'||lower(TG_OP),case when TG_OP='UPDATE' then to_jsonb(old) end,to_jsonb(new),case when auth.uid() is null then 'google_sheets' else 'dashboard' end,auth.uid());return new;
end; $$;
create trigger sale_audit after insert or update on public.sales for each row execute function public.sale_audit();
create function public.save_sale(org uuid,sale uuid,expected_version bigint,data jsonb) returns uuid language plpgsql security invoker set search_path='' as $$
declare s public.sales; cid uuid=(data->>'customer_id')::uuid; campaign uuid=nullif(data->>'campaign_id','')::uuid; day date=nullif(data->>'purchased_on','')::date;
begin
 if not public.is_member(org) then raise exception 'Acesso negado';end if;
 if nullif(data->>'amount','')::numeric is distinct from round(nullif(data->>'amount','')::numeric,2) then raise exception 'Valor deve ter até duas casas decimais';end if;
 if day>(now() at time zone 'America/Sao_Paulo')::date then raise exception 'Data de compra futura';end if;
 if not exists(select 1 from public.customers where organization_id=org and id=cid) then raise exception 'Contato inválido';end if;
 if campaign is not null and not exists(select 1 from public.campaigns where organization_id=org and id=campaign) then raise exception 'Campanha inválida';end if;
 if sale is null then
 insert into public.sales(organization_id,customer_id,campaign_id,reference,amount,purchased_at,notes,voided) values(org,cid,campaign,trim(data->>'reference'),nullif(data->>'amount','')::numeric,day::timestamp at time zone 'America/Sao_Paulo',nullif(trim(data->>'notes'),''),coalesce((data->>'voided')::boolean,false)) returning * into s;
 else
 select * into s from public.sales where id=sale and organization_id=org for update;
 if not found or s.version is distinct from expected_version then raise exception 'Venda alterada por outra operação. Atualize e tente novamente.';end if;
 update public.sales set customer_id=cid,campaign_id=campaign,reference=trim(data->>'reference'),amount=nullif(data->>'amount','')::numeric,purchased_at=day::timestamp at time zone 'America/Sao_Paulo',notes=nullif(trim(data->>'notes'),''),voided=coalesce((data->>'voided')::boolean,false) where id=s.id;
 end if;
 return s.id;
end; $$;
create function public.list_sales(org uuid,page_number integer default 0,campaign_filter uuid default null) returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare result jsonb;
begin
 if not public.is_member(org) then raise exception 'Acesso negado';end if;
 if page_number<0 then raise exception 'Paginação inválida';end if;
 with matches as (select s.*,c.name contact_name,c.phone,ca.name campaign_name,(s.purchased_at at time zone 'America/Sao_Paulo')::date purchased_on from public.sales s join public.customers c on c.id=s.customer_id left join public.campaigns ca on ca.id=s.campaign_id where s.organization_id=org and (campaign_filter is null or s.campaign_id=campaign_filter)),paged as(select * from matches order by created_at desc,id limit 20 offset page_number*20)
 select jsonb_build_object('total',(select count(*) from matches),'rows',coalesce((select jsonb_agg(to_jsonb(p)) from paged p),'[]'::jsonb)) into result;
 return result;
end; $$;
create function public.sync_sale_value(sale uuid) returns jsonb language sql stable set search_path='' as $$ select jsonb_build_object('reference',reference,'customer_id',customer_id,'campaign_id',campaign_id,'amount',amount,'purchased_on',(purchased_at at time zone 'America/Sao_Paulo')::date,'notes',notes,'voided',voided) from public.sales where id=sale; $$;
create table public.sales_sync_state(organization_id uuid not null references public.organizations,sale_id uuid not null references public.sales,base jsonb not null,synced_at timestamptz not null default now(),primary key(organization_id,sale_id));
create table public.sales_sync_runs(id uuid primary key default gen_random_uuid(),organization_id uuid not null references public.organizations,status text not null default 'running' check(status in('running','done','expired')),expires_at timestamptz not null default now()+interval '10 minutes',plan jsonb);
create unique index sales_sync_running on public.sales_sync_runs(organization_id) where status='running';
alter table public.sales_sync_state enable row level security;
alter table public.sales_sync_runs enable row level security;
create policy member_read on public.sales_sync_state for select to authenticated using(public.is_member(organization_id));
create policy member_read on public.sales_sync_runs for select to authenticated using(public.is_member(organization_id));
create function public.sales_sync_begin() returns jsonb language plpgsql security definer set search_path='' as $$
declare org uuid;run uuid;
begin
 select id into org from public.organizations where slug='futpb';
 perform pg_advisory_xact_lock(hashtextextended('sales-sync-'||org::text,0));
 update public.sales_sync_runs set status='expired' where organization_id=org and status='running' and expires_at<=now();
 if exists(select 1 from public.sales_sync_runs where organization_id=org and status='running') then raise exception 'Outra sincronização de vendas está em andamento; aguarde até dez minutos';end if;
 insert into public.sales_sync_runs(organization_id) values(org) returning id into run;return jsonb_build_object('run_id',run);
end; $$;
create function public.sales_sync_plan(run_id uuid,rows jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare run public.sales_sync_runs;s public.sales;r jsonb;incoming jsonb;current_value jsonb;baseline jsonb;merged jsonb;field text;bad boolean;seen uuid[]='{}';writes jsonb='[]';conflicts jsonb='[]';original_id uuid;day date;
begin
 select * into run from public.sales_sync_runs where id=run_id for update;
 if not found or run.status<>'running' or run.expires_at<=now() then raise exception 'Reserva de vendas expirada';end if;
 if run.plan is not null then return run.plan;end if;
 if jsonb_typeof(rows)<>'array' then raise exception 'Linhas inválidas';end if;
 if exists(select 1 from jsonb_array_elements(rows) entry group by entry.value->'value'->>'reference' having count(*)>1) then raise exception 'Referência duplicada na aba Vendas';end if;
 for r in select value from jsonb_array_elements(rows) loop
 incoming=r->'value';original_id=nullif(r->>'sale_id','')::uuid;
 if length(trim(coalesce(incoming->>'reference','')))=0 then raise exception 'Referência obrigatória';end if;
 if not exists(select 1 from public.customers where id=(incoming->>'customer_id')::uuid and organization_id=run.organization_id) then raise exception 'ID Contato inválido';end if;
 if incoming->>'campaign_id' is not null and not exists(select 1 from public.campaigns where id=(incoming->>'campaign_id')::uuid and organization_id=run.organization_id) then raise exception 'ID Campanha inválido';end if;
 if (incoming->>'amount')::numeric is distinct from round((incoming->>'amount')::numeric,2) then raise exception 'Valor deve ter até duas casas decimais';end if;
 day=(incoming->>'purchased_on')::date;if day>(now() at time zone 'America/Sao_Paulo')::date then raise exception 'Data de compra futura';end if;
 if original_id is not null then select * into s from public.sales where id=original_id and organization_id=run.organization_id for update;if not found then raise exception 'ID Venda inválido';end if;
 else select * into s from public.sales where organization_id=run.organization_id and reference=incoming->>'reference' for update;
 if not found then
 insert into public.sales(organization_id,customer_id,campaign_id,reference,amount,purchased_at,notes,voided) values(run.organization_id,(incoming->>'customer_id')::uuid,(incoming->>'campaign_id')::uuid,incoming->>'reference',(incoming->>'amount')::numeric,day::timestamp at time zone 'America/Sao_Paulo',incoming->>'notes',(incoming->>'voided')::boolean) returning * into s;
 end if;end if;
 if s.id=any(seen) then raise exception 'ID Venda duplicado';end if;seen=array_append(seen,s.id);
 current_value=public.sync_sale_value(s.id);merged=current_value;bad=false;
 select base into baseline from public.sales_sync_state where sale_id=s.id and organization_id=run.organization_id;
 for field in select jsonb_object_keys(incoming) loop
 if not current_value ? field then raise exception 'Campo de venda inválido';end if;
 if baseline is null then
 if current_value->field is distinct from incoming->field and current_value->field<>'null'::jsonb then bad=true;end if;
 merged=jsonb_set(merged,array[field],incoming->field);
 elsif incoming->field is distinct from baseline->field then
 if current_value->field is distinct from baseline->field and current_value->field is distinct from incoming->field then bad=true;else merged=jsonb_set(merged,array[field],incoming->field);end if;
 end if;end loop;
 if bad then conflicts=conflicts||jsonb_build_array(jsonb_build_object('sale_id',s.id,'reason','Alterações incompatíveis no mesmo campo','sheet',incoming,'database',current_value));continue;end if;
 if merged is distinct from current_value then
 update public.sales set reference=merged->>'reference',customer_id=(merged->>'customer_id')::uuid,campaign_id=(merged->>'campaign_id')::uuid,amount=(merged->>'amount')::numeric,purchased_at=(merged->>'purchased_on')::date::timestamp at time zone 'America/Sao_Paulo',notes=merged->>'notes',voided=(merged->>'voided')::boolean where id=s.id;
 end if;
 writes=writes||jsonb_build_array(jsonb_build_object('sale_id',s.id,'expected',incoming,'value',merged,'version',(select version from public.sales where id=s.id)));
 end loop;
 for s in select * from public.sales where organization_id=run.organization_id and not(id=any(seen)) order by id for update loop
 if exists(select 1 from public.sales_sync_state where sale_id=s.id) then conflicts=conflicts||jsonb_build_array(jsonb_build_object('sale_id',s.id,'reason','Linha removida; use Cancelada? em vez de apagar'));
 else writes=writes||jsonb_build_array(jsonb_build_object('sale_id',s.id,'expected',null,'value',public.sync_sale_value(s.id),'version',s.version));end if;
 end loop;
 -- Descriptive labels are read-only and do not participate in conflict detection.
 select coalesce(jsonb_agg(w.value||jsonb_build_object('labels',jsonb_build_object('contact_name',c.name,'phone',c.phone,'campaign_name',ca.name))),'[]'::jsonb) into writes from jsonb_array_elements(writes) w join public.customers c on c.id=(w.value->'value'->>'customer_id')::uuid left join public.campaigns ca on ca.id=(w.value->'value'->>'campaign_id')::uuid;
 update public.sales_sync_runs set plan=jsonb_build_object('run_id',run_id,'writes',writes,'conflicts',conflicts) where id=run_id;
 return jsonb_build_object('run_id',run_id,'writes',writes,'conflicts',conflicts);
end; $$;
create function public.sales_sync_validate(run_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$ begin
 if not exists(select 1 from public.sales_sync_runs where id=run_id and status='running' and expires_at>now()+interval '1 minute' and plan is not null) then raise exception 'Reserva expirada; não gravar vendas';end if;return jsonb_build_object('run_id',run_id);
end; $$;
create function public.sales_sync_ack(run_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare run public.sales_sync_runs;item jsonb;
begin
 select * into run from public.sales_sync_runs where id=run_id for update;
 if not found then raise exception 'Reserva desconhecida';end if;
 if run.status='done' then return jsonb_build_object('status','done');end if;
 if run.status<>'running' or run.expires_at<=now() or run.plan is null then raise exception 'Reserva expirada';end if;
 for item in select value from jsonb_array_elements(run.plan->'writes') loop
 insert into public.sales_sync_state(organization_id,sale_id,base) values(run.organization_id,(item->>'sale_id')::uuid,item->'value') on conflict(organization_id,sale_id) do update set base=excluded.base,synced_at=now();
 end loop;
 update public.sales_sync_runs set status='done' where id=run_id;return jsonb_build_object('status','done','synced',jsonb_array_length(run.plan->'writes'),'conflicts',run.plan->'conflicts');
end; $$;
revoke all on function public.save_sale(uuid,uuid,bigint,jsonb),public.list_sales(uuid,integer,uuid) from public,anon;
grant execute on function public.save_sale(uuid,uuid,bigint,jsonb),public.list_sales(uuid,integer,uuid) to authenticated;
revoke all on function public.sync_sale_value(uuid),public.sales_sync_begin(),public.sales_sync_plan(uuid,jsonb),public.sales_sync_validate(uuid),public.sales_sync_ack(uuid) from public,anon,authenticated;
grant execute on function public.sync_sale_value(uuid),public.sales_sync_begin(),public.sales_sync_plan(uuid,jsonb),public.sales_sync_validate(uuid),public.sales_sync_ack(uuid) to service_role;
notify pgrst,'reload schema';
commit;

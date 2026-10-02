begin;
create table public.sheet_sync_state (
 organization_id uuid not null references public.organizations,
 customer_id uuid not null, base jsonb not null, synced_at timestamptz not null default now(),
 primary key(organization_id,customer_id),
 foreign key(organization_id,customer_id) references public.customers(organization_id,id)
);
create table public.sheet_sync_runs (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations,
 status text not null default 'running' check(status in ('running','done','expired')),
 expires_at timestamptz not null default now()+interval '10 minutes', plan jsonb, created_at timestamptz not null default now()
);
create unique index sheet_sync_one_run on public.sheet_sync_runs(organization_id) where status='running';
create table public.sheet_sync_conflicts (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations,
 customer_id uuid, reason text not null, sheet_value jsonb, database_value jsonb, created_at timestamptz not null default now(),
 unique(organization_id,customer_id,reason)
);
alter table public.sheet_sync_state enable row level security;
alter table public.sheet_sync_runs enable row level security;
alter table public.sheet_sync_conflicts enable row level security;
create policy member_read on public.sheet_sync_state for select to authenticated using(public.is_member(organization_id));
create policy member_read on public.sheet_sync_runs for select to authenticated using(public.is_member(organization_id));
create policy member_read on public.sheet_sync_conflicts for select to authenticated using(public.is_member(organization_id));
create function public.sync_customer_value(customer uuid) returns jsonb language sql stable set search_path='' as $$
 select jsonb_build_object('name',c.name,'phone',c.phone,'desired_shirt',c.desired_shirt,'size',c.size,'birthday',c.birthday,
 'has_purchased',c.has_purchased,'can_receive_campaigns',c.can_receive_campaigns,'has_referrals',c.has_referrals,
 'total_spent',c.total_spent,'order_count',c.order_count,'last_purchase_at',c.last_purchase_at,
 'teams',coalesce((select jsonb_agg(t.name order by t.name collate "C") from public.customer_teams ct join public.teams t on t.id=ct.team_id where ct.customer_id=c.id),'[]'::jsonb))
 from public.customers c where c.id=customer;
$$;
create function public.sheet_sync_begin() returns jsonb language plpgsql security definer set search_path='' as $$
declare org uuid; token uuid;
begin
 select id into org from public.organizations where slug='futpb';
 if org is null then raise exception 'Organização FUTPB não encontrada'; end if;
 perform pg_advisory_xact_lock(hashtext(org::text));
 update public.sheet_sync_runs set status='expired' where organization_id=org and status='running' and expires_at<=now();
 if exists(select 1 from public.sheet_sync_runs where organization_id=org and status='running') then raise exception 'Outra sincronização está em andamento; aguarde até dez minutos'; end if;
 insert into public.sheet_sync_runs(organization_id) values(org) returning id into token;
 return jsonb_build_object('run_id',token);
end; $$;
create function public.sheet_sync_plan(run_id uuid, rows jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare run public.sheet_sync_runs; r jsonb; c public.customers; base jsonb; current_value jsonb; incoming jsonb; merged jsonb;
 field_name text; bad boolean; seen uuid[]='{}'; writes jsonb='[]'; conflicts jsonb='[]'; team_name text; team_id uuid;
begin
 select * into run from public.sheet_sync_runs where id=run_id and status='running' and expires_at>now() for update;
 if not found then raise exception 'Execução inválida ou expirada'; end if;
 if run.plan is not null then return run.plan; end if;
 if jsonb_typeof(rows)<>'array' or jsonb_array_length(rows)>9999 then raise exception 'Leitura inválida ou acima do limite'; end if;
 if exists(select 1 from jsonb_array_elements(rows) x group by x->'value'->>'phone' having count(*)>1) then raise exception 'Telefones duplicados na planilha'; end if;
 if exists(select 1 from jsonb_array_elements(rows) x where coalesce(x->>'customer_id','')<>'' group by x->>'customer_id' having count(*)>1) then raise exception 'UUIDs duplicados na planilha'; end if;
 perform set_config('futpb.sync_from_sheet','true',true);
 for r in select value from jsonb_array_elements(rows) loop
 incoming=r->'value';
 incoming=jsonb_set(incoming,'{teams}',coalesce((select jsonb_agg(v order by v collate "C") from (select distinct jsonb_array_elements_text(incoming->'teams') v) names),'[]'::jsonb));
 if jsonb_typeof(incoming)<>'object' or incoming->>'phone' is null then raise exception 'Registro inválido'; end if;
 c=null;
 if coalesce(r->>'customer_id','')<>'' then
 select * into c from public.customers where id=(r->>'customer_id')::uuid and organization_id=run.organization_id for update;
 if not found then raise exception 'UUID desconhecido: %',r->>'customer_id'; end if;
 else
 select * into c from public.customers where organization_id=run.organization_id and phone=incoming->>'phone' for update;
 end if;
 if c.id is null then
 insert into public.customers(organization_id,name,phone,last_update_source)
 values(run.organization_id,incoming->>'name',incoming->>'phone','google_sheets') returning * into c;
 end if;
 if c.id=any(seen) then raise exception 'Duas linhas correspondem ao mesmo cliente'; end if;
 seen=array_append(seen,c.id);
 select s.base into base from public.sheet_sync_state s where s.organization_id=run.organization_id and s.customer_id=c.id;
 current_value=public.sync_customer_value(c.id); merged=current_value; bad=false;
 for field_name in select jsonb_object_keys(incoming) loop
 if not current_value ? field_name then raise exception 'Campo não permitido: %',field_name; end if;
 if base is null then
 -- New imports start with minimal values. Existing unlinked rows require review if populated values differ.
 if current_value->field_name is distinct from incoming->field_name and current_value->field_name<>'null'::jsonb and current_value->field_name<>'[]'::jsonb then bad=true; end if;
 merged=jsonb_set(merged,array[field_name],incoming->field_name);
 elsif incoming->field_name is distinct from base->field_name then
 if current_value->field_name is distinct from base->field_name and current_value->field_name is distinct from incoming->field_name then bad=true;
 else merged=jsonb_set(merged,array[field_name],incoming->field_name); end if;
 end if;
 end loop;
 if bad then
 insert into public.sheet_sync_conflicts(organization_id,customer_id,reason,sheet_value,database_value) values(run.organization_id,c.id,'field_conflict',incoming,current_value)
 on conflict(organization_id,customer_id,reason) do update set sheet_value=excluded.sheet_value,database_value=excluded.database_value,created_at=now();
 conflicts=conflicts||jsonb_build_array(jsonb_build_object('customer_id',c.id,'reason','Alterações incompatíveis no mesmo campo', 'sheet',incoming,'database',current_value));
 continue;
 end if;
 if merged is distinct from current_value then
 update public.customers set name=merged->>'name',phone=merged->>'phone',desired_shirt=merged->>'desired_shirt',size=merged->>'size',birthday=(merged->>'birthday')::date,
 has_purchased=(merged->>'has_purchased')::boolean,can_receive_campaigns=(merged->>'can_receive_campaigns')::boolean,has_referrals=(merged->>'has_referrals')::boolean,
 total_spent=(merged->>'total_spent')::numeric,order_count=(merged->>'order_count')::integer,last_purchase_at=(merged->>'last_purchase_at')::date,last_update_source='google_sheets'
 where id=c.id;
 if merged->'teams' is distinct from current_value->'teams' then
 delete from public.customer_teams where customer_id=c.id;
 for team_name in select jsonb_array_elements_text(merged->'teams') loop
 insert into public.teams(organization_id,name) values(run.organization_id,team_name) on conflict(organization_id,name) do update set name=excluded.name returning id into team_id;
 insert into public.customer_teams(organization_id,customer_id,team_id) values(run.organization_id,c.id,team_id) on conflict do nothing;
 end loop;
 end if;
 end if;
 delete from public.sheet_sync_conflicts where organization_id=run.organization_id and customer_id=c.id;
 writes=writes||jsonb_build_array(jsonb_build_object('customer_id',c.id,'expected',incoming,'original_id',r->>'customer_id','value',merged,'version',(select version from public.customers where id=c.id)));
 end loop;
 for c in select * from public.customers where organization_id=run.organization_id and not(id=any(seen)) order by id for update loop
 if exists(select 1 from public.sheet_sync_state where customer_id=c.id) then
 insert into public.sheet_sync_conflicts(organization_id,customer_id,reason,database_value) values(run.organization_id,c.id,'missing_sheet_row',public.sync_customer_value(c.id)) on conflict do nothing;
 conflicts=conflicts||jsonb_build_array(jsonb_build_object('customer_id',c.id,'reason','Linha sincronizada removida da planilha; revisão necessária'));
 else
 writes=writes||jsonb_build_array(jsonb_build_object('customer_id',c.id,'expected',null,'original_id',null,'value',public.sync_customer_value(c.id),'version',c.version));
 end if;
 end loop;
 update public.sheet_sync_runs set plan=jsonb_build_object('run_id',run_id,'writes',writes,'conflicts',conflicts) where id=run_id;
 return jsonb_build_object('run_id',run_id,'writes',writes,'conflicts',conflicts);
end; $$;
create function public.sheet_sync_ack(run_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare run public.sheet_sync_runs; item jsonb;
begin
 select * into run from public.sheet_sync_runs where id=run_id for update;
 if not found then raise exception 'Execução desconhecida'; end if;
 if run.status='done' then return jsonb_build_object('status','done'); end if;
 if run.status<>'running' or run.expires_at<=now() or run.plan is null then raise exception 'Execução expirada ou não planejada'; end if;
 for item in select value from jsonb_array_elements(run.plan->'writes') loop
 insert into public.sheet_sync_state(organization_id,customer_id,base) values(run.organization_id,(item->>'customer_id')::uuid,item->'value')
 on conflict(organization_id,customer_id) do update set base=excluded.base,synced_at=now();
 update public.integration_jobs set status='done' where organization_id=run.organization_id and kind='customer.sync_to_sheet' and payload->'customer'->>'id'=item->>'customer_id' and (payload->'customer'->>'version')::bigint<=(item->>'version')::bigint;
 end loop;
 update public.sheet_sync_runs set status='done' where id=run_id;
 return jsonb_build_object('status','done','synced',jsonb_array_length(run.plan->'writes'),'conflicts',run.plan->'conflicts');
end; $$;
create function public.sheet_sync_validate(run_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$ begin
 if not exists(select 1 from public.sheet_sync_runs where id=run_id and status='running' and expires_at>now()+interval '1 minute' and plan is not null) then raise exception 'Execução expirada ou próxima de expirar; não gravar a planilha'; end if;
 return jsonb_build_object('run_id',run_id);
end; $$;
revoke all on function public.sheet_sync_validate(uuid) from public,anon,authenticated;
grant execute on function public.sheet_sync_validate(uuid) to service_role;
-- Every integration RPC is private to the server credential used by n8n.
revoke all on function public.sheet_sync_begin() from public,anon,authenticated;
revoke all on function public.sheet_sync_plan(uuid,jsonb) from public,anon,authenticated;
revoke all on function public.sheet_sync_ack(uuid) from public,anon,authenticated;
grant execute on function public.sheet_sync_begin() to service_role;
grant execute on function public.sheet_sync_plan(uuid,jsonb) to service_role;
grant execute on function public.sheet_sync_ack(uuid) to service_role;
commit;

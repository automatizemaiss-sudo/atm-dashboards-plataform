begin;
alter table public.customers add column shirt_types text[] not null default '{}';
alter table public.customers add constraint valid_shirt_types check (shirt_types <@ array['Jogador','Torcedor','Retrô']::text[]);
update public.sheet_sync_state set base=base||'{"shirt_types":[]}'::jsonb;
create or replace function public.matches_rules(c public.customers, r jsonb) returns boolean language plpgsql stable set search_path='' as $$
declare item jsonb; result boolean; actual jsonb; field_name text; op text;
begin
 if r ? 'conditions' then
 if r->>'operator' not in ('and','or') or jsonb_typeof(r->'conditions')<>'array' then raise exception 'Regras inválidas'; end if;
 result=(r->>'operator'='and');
 for item in select value from jsonb_array_elements(r->'conditions') loop
 if r->>'operator'='and' then result=result and public.matches_rules(c,item); else result=result or public.matches_rules(c,item); end if;
 end loop; return result;
 end if;
 field_name=r->>'field'; op=r->>'op';
 if field_name='query' then return c.name ilike '%'||(r->>'value')||'%' or c.phone like '%'||nullif(regexp_replace(r->>'value','[^0-9]','','g'),'')||'%'; end if;
 if field_name='purchase_unknown' then return c.has_purchased is null; end if;
 if field_name='id' then return op='eq' and c.id::text=r->>'value'; end if;
 if field_name='shirt_type' then return op='eq' and r->>'value'=any(c.shirt_types); end if;
 if field_name='team' then
 if op<>'eq' then raise exception 'Operador de time inválido'; end if;
 return exists(select 1 from public.customer_teams ct join public.teams t on t.id=ct.team_id where ct.customer_id=c.id and t.name=r->>'value');
 end if;
 if field_name not in ('desired_shirt','size','birthday','birthday_month','has_purchased','has_referrals','can_receive_campaigns','total_spent','order_count','last_purchase_at','created_at') then raise exception 'Campo de segmento inválido'; end if;
 actual=case when field_name='birthday_month' then to_jsonb(extract(month from c.birthday)::integer) when field_name='created_at' then to_jsonb((c.created_at at time zone 'America/Sao_Paulo')::date) else to_jsonb(c)->field_name end;
 if field_name='can_receive_campaigns' and actual='null'::jsonb then actual='true'::jsonb; end if;
 if actual is null or actual='null'::jsonb then return false; end if;
 case op
 when 'eq' then return actual=r->'value';
 when 'gte' then return actual>=r->'value';
 when 'lte' then return actual<=r->'value';
 when 'contains' then return strpos(lower(actual #>> '{}'),lower(r->>'value'))>0;
 else raise exception 'Operador inválido'; end case;
end; $$;
create or replace function public.save_customer(org uuid, customer uuid, expected_version bigint, data jsonb, team_names jsonb) returns uuid language plpgsql security invoker set search_path='' as $$
declare c public.customers; tid uuid; t text; previous_teams jsonb;
begin
 if not public.is_member(org) then raise exception 'Acesso negado'; end if;
 if jsonb_typeof(team_names)<>'array' then raise exception 'Times inválidos'; end if;
 if customer is not null then
 select * into c from public.customers where id=customer and organization_id=org for update;
 if not found or c.version is distinct from expected_version then raise exception 'Cliente alterado por outra operação. Atualize a lista e tente novamente.'; end if;
 previous_teams=(select coalesce(jsonb_agg(te.name order by te.name),'[]'::jsonb) from public.customer_teams ct join public.teams te on te.id=ct.team_id where ct.customer_id=c.id);
 update public.customers set name=data->>'name',phone=data->>'phone',shirt_types=case when data ? 'shirt_types' then array(select jsonb_array_elements_text(data->'shirt_types')) else shirt_types end,desired_shirt=data->>'desired_shirt',size=data->>'size',birthday=(data->>'birthday')::date,has_purchased=(data->>'has_purchased')::boolean,has_referrals=(data->>'has_referrals')::boolean,can_receive_campaigns=(data->>'can_receive_campaigns')::boolean,total_spent=(data->>'total_spent')::numeric,order_count=(data->>'order_count')::integer,last_purchase_at=(data->>'last_purchase_at')::date where id=c.id;
 else
 insert into public.customers(organization_id,name,phone,shirt_types,desired_shirt,size,birthday,has_purchased,has_referrals,can_receive_campaigns,total_spent,order_count,last_purchase_at)
 values(org,data->>'name',data->>'phone',array(select jsonb_array_elements_text(coalesce(data->'shirt_types','[]'::jsonb))),data->>'desired_shirt',data->>'size',(data->>'birthday')::date,(data->>'has_purchased')::boolean,(data->>'has_referrals')::boolean,(data->>'can_receive_campaigns')::boolean,(data->>'total_spent')::numeric,(data->>'order_count')::integer,(data->>'last_purchase_at')::date) returning * into c;
 previous_teams='[]';
 end if;
 delete from public.customer_teams where customer_id=c.id;
 for t in select distinct trim(value) from jsonb_array_elements_text(team_names) where trim(value)<>'' loop
 select id into tid from public.teams where organization_id=org and name=t;
 if tid is null then insert into public.teams(organization_id,name) values(org,t) on conflict(organization_id,name) do update set name=excluded.name returning id into tid; end if;
 insert into public.customer_teams(organization_id,customer_id,team_id) values(org,c.id,tid) on conflict do nothing;
 end loop;
 return c.id;
end; $$;
create or replace function public.browse_contacts(org uuid, query text default '', page_number integer default 0, page_size integer default 20, size_filter text default '', bought_filter text default '', marketing_filter text default '', sort_field text default 'created_at', ascending boolean default false, rules jsonb default '{"operator":"and","conditions":[]}') returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare rows jsonb; total bigint;
begin
 if not public.is_member(org) then raise exception 'Acesso negado'; end if;
 if page_number<0 or page_size<1 or page_size>100 then raise exception 'Paginação inválida'; end if;
 if sort_field not in ('name','created_at','last_purchase_at') then raise exception 'Ordenação inválida'; end if;
 with matches as (
 select c.* from public.customers c where c.organization_id=org and c.archived_at is null and public.matches_rules(c,rules)
 and (query='' or c.name ilike '%'||query||'%' or c.phone like '%'||nullif(regexp_replace(query,'[^0-9]','','g'),'')||'%')
 and(size_filter='' or c.size=size_filter)
 and(bought_filter='' or (bought_filter='true' and c.has_purchased=true) or (bought_filter='false' and c.has_purchased=false) or(bought_filter='unknown' and c.has_purchased is null))
 and(marketing_filter='' or(marketing_filter='true' and c.can_receive_campaigns is distinct from false) or(marketing_filter='false' and c.can_receive_campaigns=false))
 ), paged as (
 select * from matches order by
 case when ascending and sort_field='name' then name end asc,
 case when not ascending and sort_field='name' then name end desc,
 case when ascending and sort_field='created_at' then created_at end asc,
 case when not ascending and sort_field='created_at' then created_at end desc,
 case when ascending and sort_field='last_purchase_at' then last_purchase_at end asc nulls last,
 case when not ascending and sort_field='last_purchase_at' then last_purchase_at end desc nulls last,id
 limit page_size offset page_number*page_size
 ) select (select count(*) from matches),coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('customer_teams',coalesce((select jsonb_agg(jsonb_build_object('teams',jsonb_build_object('name',t.name))) from public.customer_teams ct join public.teams t on t.id=ct.team_id where ct.customer_id=p.id),'[]'::jsonb))) from paged p),'[]'::jsonb) into total,rows;
 return jsonb_build_object('total',total,'rows',rows);
end; $$;
create or replace function public.sync_customer_value(customer uuid) returns jsonb language sql stable set search_path='' as $$
 select jsonb_build_object('shirt_types',to_jsonb(array(select distinct unnest(c.shirt_types) order by 1)),'archived',c.archived_at is not null,'name',c.name,'phone',c.phone,'desired_shirt',c.desired_shirt,'size',c.size,'birthday',c.birthday,
 'has_purchased',c.has_purchased,'can_receive_campaigns',c.can_receive_campaigns,'has_referrals',c.has_referrals,
 'total_spent',c.total_spent,'order_count',c.order_count,'last_purchase_at',c.last_purchase_at,
 'teams',coalesce((select jsonb_agg(t.name order by t.name collate "C") from public.customer_teams ct join public.teams t on t.id=ct.team_id where ct.customer_id=c.id),'[]'::jsonb))
 from public.customers c where c.id=customer;
$$;
create or replace function public.sheet_sync_plan(run_id uuid, rows jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
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
 update public.customers set shirt_types=array(select jsonb_array_elements_text(merged->'shirt_types')),name=merged->>'name',phone=merged->>'phone',desired_shirt=merged->>'desired_shirt',size=merged->>'size',birthday=(merged->>'birthday')::date,
 has_purchased=(merged->>'has_purchased')::boolean,can_receive_campaigns=(merged->>'can_receive_campaigns')::boolean,has_referrals=(merged->>'has_referrals')::boolean,
 total_spent=(merged->>'total_spent')::numeric,order_count=(merged->>'order_count')::integer,last_purchase_at=(merged->>'last_purchase_at')::date,archived_at=case when (merged->>'archived')::boolean then coalesce(archived_at,now()) else null end,last_update_source='google_sheets'
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
revoke all on function public.browse_contacts(uuid,text,integer,integer,text,text,text,text,boolean,jsonb) from public,anon;
grant execute on function public.browse_contacts(uuid,text,integer,integer,text,text,text,text,boolean,jsonb) to authenticated;
create or replace function public.customer_summary(org uuid) returns jsonb language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('total',count(*),'buyers',count(*) filter(where has_purchased=true),'allowed',count(*) filter(where can_receive_campaigns is distinct from false),'unknown_purchase',count(*) filter(where has_purchased is null),
 'interested',count(*) filter(where cardinality(shirt_types)>0),'shirt_types',coalesce((select jsonb_object_agg(kind,n) from (select kind,count(*) n from public.customers c cross join lateral (select distinct unnest(c.shirt_types) kind) kinds where c.organization_id=org and c.archived_at is null group by kind) ranked),'{}'::jsonb),
 'teams',coalesce((select jsonb_object_agg(name,n) from (select t.name,count(*) n from public.customer_teams ct join public.teams t on t.id=ct.team_id where ct.organization_id=org and exists(select 1 from public.customers c where c.id=ct.customer_id and c.archived_at is null) group by t.name) ranked),'{}'::jsonb),
 'sizes',coalesce((select jsonb_object_agg(size,n) from (select size,count(*) n from public.customers where organization_id=org and archived_at is null and size is not null group by size) ranked),'{}'::jsonb))
 from public.customers where organization_id=org and archived_at is null and public.is_member(org);
$$;
notify pgrst, 'reload schema';
commit;

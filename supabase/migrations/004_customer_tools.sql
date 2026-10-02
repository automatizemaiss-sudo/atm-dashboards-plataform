begin;
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
create function public.save_customer(org uuid, customer uuid, expected_version bigint, data jsonb, team_names jsonb) returns uuid language plpgsql security invoker set search_path='' as $$
declare c public.customers; tid uuid; t text; previous_teams jsonb;
begin
 if not public.is_member(org) then raise exception 'Acesso negado'; end if;
 if jsonb_typeof(team_names)<>'array' then raise exception 'Times inválidos'; end if;
 if customer is not null then
 select * into c from public.customers where id=customer and organization_id=org for update;
 if not found or c.version is distinct from expected_version then raise exception 'Cliente alterado por outra operação. Atualize a lista e tente novamente.'; end if;
 previous_teams=(select coalesce(jsonb_agg(te.name order by te.name),'[]'::jsonb) from public.customer_teams ct join public.teams te on te.id=ct.team_id where ct.customer_id=c.id);
 update public.customers set name=data->>'name',phone=data->>'phone',desired_shirt=data->>'desired_shirt',size=data->>'size',birthday=(data->>'birthday')::date,has_purchased=(data->>'has_purchased')::boolean,has_referrals=(data->>'has_referrals')::boolean,can_receive_campaigns=(data->>'can_receive_campaigns')::boolean,total_spent=(data->>'total_spent')::numeric,order_count=(data->>'order_count')::integer,last_purchase_at=(data->>'last_purchase_at')::date where id=c.id;
 else
 insert into public.customers(organization_id,name,phone,desired_shirt,size,birthday,has_purchased,has_referrals,can_receive_campaigns,total_spent,order_count,last_purchase_at)
 values(org,data->>'name',data->>'phone',data->>'desired_shirt',data->>'size',(data->>'birthday')::date,(data->>'has_purchased')::boolean,(data->>'has_referrals')::boolean,(data->>'can_receive_campaigns')::boolean,(data->>'total_spent')::numeric,(data->>'order_count')::integer,(data->>'last_purchase_at')::date) returning * into c;
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
-- Security-definer audit, invoked only by the relation trigger; never by a frontend call.
create function public.audit_customer_team() returns trigger language plpgsql security definer set search_path='' as $$
declare cid uuid; org uuid;
begin
 cid=case when TG_OP='DELETE' then old.customer_id else new.customer_id end;
 org=case when TG_OP='DELETE' then old.organization_id else new.organization_id end;
 insert into public.customer_events(organization_id,customer_id,event_type,old_value,new_value,source,user_id)
 values(org,cid,'team_'||lower(TG_OP),case when TG_OP='DELETE' then to_jsonb(old) end,case when TG_OP='INSERT' then to_jsonb(new) end,case when auth.uid() is null then 'google_sheets' else 'dashboard' end,auth.uid());
 return null;
end; $$;
create trigger customer_team_audit after insert or delete on public.customer_teams for each row execute function public.audit_customer_team();
create function public.list_customers(org uuid, query text default '', page_number integer default 0, page_size integer default 20, size_filter text default '', bought_filter text default '', marketing_filter text default '', sort_field text default 'created_at', ascending boolean default false) returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare rows jsonb; total bigint;
begin
 if not public.is_member(org) then raise exception 'Acesso negado'; end if;
 if page_number<0 or page_size<1 or page_size>100 then raise exception 'Paginação inválida'; end if;
 if sort_field not in ('name','created_at','last_purchase_at') then raise exception 'Ordenação inválida'; end if;
 with matches as (
 select c.* from public.customers c where c.organization_id=org
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
create function public.customer_summary(org uuid) returns jsonb language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('total',count(*),'buyers',count(*) filter(where has_purchased=true),'allowed',count(*) filter(where can_receive_campaigns is distinct from false),'unknown_purchase',count(*) filter(where has_purchased is null),
 'teams',coalesce((select jsonb_object_agg(name,n) from (select t.name,count(*) n from public.customer_teams ct join public.teams t on t.id=ct.team_id where ct.organization_id=org group by t.name) ranked),'{}'::jsonb),
 'sizes',coalesce((select jsonb_object_agg(size,n) from (select size,count(*) n from public.customers where organization_id=org and size is not null group by size) ranked),'{}'::jsonb))
 from public.customers where organization_id=org and public.is_member(org);
$$;
revoke all on function public.save_customer(uuid,uuid,bigint,jsonb,jsonb) from public,anon;
grant execute on function public.save_customer(uuid,uuid,bigint,jsonb,jsonb) to authenticated;
revoke all on function public.list_customers(uuid,text,integer,integer,text,text,text,text,boolean) from public,anon;
grant execute on function public.list_customers(uuid,text,integer,integer,text,text,text,text,boolean) to authenticated;
revoke all on function public.customer_summary(uuid) from public,anon;
grant execute on function public.customer_summary(uuid) to authenticated;
commit;

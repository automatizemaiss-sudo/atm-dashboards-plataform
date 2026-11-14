begin;
alter table public.customers add column segment_tags text[] not null default '{}';
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
 if field_name='segment_tag' then return op='eq' and r->>'value'=any(c.segment_tags); end if;
 if field_name='query' then return c.name ilike '%'||(r->>'value')||'%' or c.phone like '%'||nullif(regexp_replace(r->>'value','[^0-9]','','g'),'')||'%'; end if;
 if field_name='purchase_unknown' then return c.has_purchased is null; end if;
 if field_name='id' then return op='eq' and c.id::text=r->>'value'; end if;
 if field_name='shirt_type' then return op='eq' and r->>'value'=any(c.shirt_types); end if;
 if field_name='team' then
 if op not in ('eq','contains') then raise exception 'Operador de time inválido'; end if;
 return exists(select 1 from public.customer_teams ct join public.teams t on t.id=ct.team_id where ct.customer_id=c.id and (case when op='eq' then public.normalize_team_search(t.name)=public.normalize_team_search(r->>'value') else strpos(public.normalize_team_search(t.name),public.normalize_team_search(r->>'value'))>0 end));
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

-- Preview and approval share validation. Approval is a single atomic transaction.
create function public.import_contacts(org uuid, contacts jsonb, approve boolean default false) returns jsonb
language plpgsql security definer set search_path='' as $$
declare item jsonb; c public.customers; tag text; sid uuid; result jsonb='[]'; state text; tags text[];
begin
 if not public.is_member(org) then raise exception 'Acesso negado'; end if;
 if jsonb_typeof(contacts) is distinct from 'array' or jsonb_array_length(contacts)>2000 or jsonb_array_length(contacts)=0 then raise exception 'Envie de 1 a 2000 contatos por arquivo'; end if;
 perform pg_advisory_xact_lock(hashtextextended(org::text,0));
 for item in select value from jsonb_array_elements(contacts) loop
 if coalesce(item->>'phone','') !~ '^\+55[0-9]{10,11}$' or length(trim(coalesce(item->>'name','')))=0 then raise exception 'Nome ou telefone inválido'; end if;
 tags=array(select distinct trim(value) from jsonb_array_elements_text(item->'tags') where trim(value)<>'');
 select * into c from public.customers where organization_id=org and phone=item->>'phone' for update;
 state=case when c.id is null then 'Novo' when c.archived_at is not null then 'Arquivado: ignorado' else 'Existente: adicionar segmentações' end;
 if approve and c.archived_at is null then
 if c.id is null then
 insert into public.customers(organization_id,name,phone,segment_tags) values(org,trim(item->>'name'),item->>'phone',tags) returning * into c;
 elsif not tags <@ c.segment_tags then
 update public.customers set segment_tags=array(select distinct unnest(c.segment_tags||tags)) where id=c.id;
 end if;
 foreach tag in array tags loop
 select id into sid from public.segments where organization_id=org and name=tag order by id limit 1;
 if sid is null then
 insert into public.segments(organization_id,name,rules) values(org,tag,jsonb_build_object('operator','and','conditions',jsonb_build_array(jsonb_build_object('field','segment_tag','op','eq','value',tag))));
 else
 if not exists(select 1 from public.segments where id=sid and rules @> jsonb_build_object('conditions',jsonb_build_array(jsonb_build_object('field','segment_tag','op','eq','value',tag)))) then
 update public.segments set rules=jsonb_build_object('operator','or','conditions',jsonb_build_array(rules,jsonb_build_object('field','segment_tag','op','eq','value',tag))) where id=sid;
 end if;
 end if;
 end loop;
 end if;
 result=result||jsonb_build_array(jsonb_build_object('phone',item->>'phone','status',state));
 end loop;
 return result;
end; $$;
revoke all on function public.import_contacts(uuid,jsonb,boolean) from public,anon;
grant execute on function public.import_contacts(uuid,jsonb,boolean) to authenticated;
notify pgrst,'reload schema';
commit;

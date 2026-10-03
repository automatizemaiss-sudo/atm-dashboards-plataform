begin;
alter table public.customers drop constraint valid_shirt_types;
alter table public.customers add constraint valid_shirt_types check (shirt_types <@ array['Jogador','Torcedor','Retrô','Feminina']::text[]);
-- No extension required. Alias normalization applies to search only, preserving stored names.
create or replace function public.normalize_team_search(value text) returns text language sql immutable set search_path='' as $$
 select replace(translate(lower(trim(value)),'áàâãäéèêëíìîïóòôõöúùûüç','aaaaaeeeeiiiiooooouuuuc'),'barca','barcelona');
$$;
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
notify pgrst, 'reload schema';
commit;

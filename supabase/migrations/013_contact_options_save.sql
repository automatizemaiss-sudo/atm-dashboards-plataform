begin;
alter table public.customers drop constraint valid_shirt_types;
alter table public.customers add constraint valid_shirt_types check (shirt_types <@ array['Jogador','Torcedor','Retrô','Feminina','NBA']::text[]);
-- Atomic save checks membership before writes, uses org-scoped customer lookup
-- and org-scoped teams. RLS remains enabled for direct table access.
create or replace function public.save_customer(org uuid, customer uuid, expected_version bigint, data jsonb, team_names jsonb) returns uuid language plpgsql security definer set search_path='' as $$
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
revoke all on function public.save_customer(uuid,uuid,bigint,jsonb,jsonb) from public,anon;
grant execute on function public.save_customer(uuid,uuid,bigint,jsonb,jsonb) to authenticated;
notify pgrst,'reload schema';
commit;

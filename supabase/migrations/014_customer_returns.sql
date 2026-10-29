begin;
alter table public.customers
 add column return_date date,
 add column return_automatic boolean not null default false,
 add column return_message text,
 add column return_instance_id uuid,
 add column return_campaign_id uuid,
 add foreign key(organization_id,return_instance_id) references public.whatsapp_instances(organization_id,id),
 add foreign key(organization_id,return_campaign_id) references public.campaigns(organization_id,id),
 add constraint automatic_return_config check(not return_automatic or (return_date is not null and coalesce(length(trim(return_message)),0)>0 and return_instance_id is not null));
create index customers_return_date on public.customers(organization_id,return_date) where archived_at is null and return_date is not null;
-- Replacing or removing a return cancels its previous pending campaign atomically.
create function public.schedule_customer_return() returns trigger language plpgsql security definer set search_path='' as $$
declare cid uuid;
begin
 if TG_OP='UPDATE' then
 if row(new.return_date,new.return_automatic,new.return_message,new.return_instance_id,new.archived_at,new.can_receive_campaigns,new.name,new.phone)
 is not distinct from row(old.return_date,old.return_automatic,old.return_message,old.return_instance_id,old.archived_at,old.can_receive_campaigns,old.name,old.phone) then return new;end if;
 if old.return_campaign_id is not null then
 -- Do not repeat a return already accepted by the provider after an unrelated edit.
 if row(new.return_date,new.return_automatic,new.return_message,new.return_instance_id) is not distinct from row(old.return_date,old.return_automatic,old.return_message,old.return_instance_id)
 and exists(select 1 from public.whatsapp_dispatches d join public.campaign_recipients r on r.id=d.recipient_id where r.campaign_id=old.return_campaign_id and d.status in('sending','accepted','unknown')) then return new;end if;
 if exists(select 1 from public.whatsapp_dispatches d join public.campaign_recipients r on r.id=d.recipient_id where r.campaign_id=old.return_campaign_id and d.status in('sending','unknown')) then raise exception 'Retorno em envio ou com resultado incerto. Confira o envio antes de reagendar.';end if;
 update public.campaigns set status='cancelled' where id=old.return_campaign_id and status in('scheduled','processing','paused','error');
 update public.whatsapp_dispatches d set status='skipped' from public.campaign_recipients r where r.id=d.recipient_id and r.campaign_id=old.return_campaign_id and d.status='reserved';
 end if;
 end if;
 new.return_campaign_id=null;
 if new.return_automatic and new.return_date is not null and new.archived_at is null and new.can_receive_campaigns is distinct from false then
 if not exists(select 1 from public.whatsapp_instances where id=new.return_instance_id and organization_id=new.organization_id and enabled) then raise exception 'Selecione uma instância de WhatsApp habilitada para o retorno automático.';end if;
 insert into public.campaigns(organization_id,name,instance_id,status,scheduled_at,snapshot_at)
 values(new.organization_id,'Retorno · '||new.name,new.return_instance_id,'scheduled',new.return_date::timestamp at time zone 'America/Sao_Paulo',now()) returning id into cid;
 new.return_campaign_id=cid;
 end if;
 return new;
end; $$;
-- Recipients are inserted AFTER the customer exists (including on first registration).
create function public.populate_customer_return() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.return_campaign_id is not null and (TG_OP='INSERT' or new.return_campaign_id is distinct from old.return_campaign_id) then
 insert into public.campaign_messages(organization_id,campaign_id,position,kind,body) values(new.organization_id,new.return_campaign_id,0,'text',new.return_message);
 insert into public.campaign_recipients(organization_id,campaign_id,customer_id,snapshot) values(new.organization_id,new.return_campaign_id,new.id,jsonb_build_object('name',new.name,'phone',new.phone));
 end if;
 return new;
end; $$;
create trigger customer_return_schedule before insert or update on public.customers for each row execute function public.schedule_customer_return();
create trigger customer_return_recipient after insert or update on public.customers for each row execute function public.populate_customer_return();
create or replace function public.save_customer(org uuid, customer uuid, expected_version bigint, data jsonb, team_names jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare c public.customers; tid uuid; t text; previous_teams jsonb;
begin
 if not public.is_member(org) then raise exception 'Acesso negado'; end if;
 if jsonb_typeof(team_names)<>'array' then raise exception 'Times inválidos'; end if;
 if customer is not null then
 select * into c from public.customers where id=customer and organization_id=org for update;
 if not found or c.version is distinct from expected_version then raise exception 'Cliente alterado por outra operação. Atualize a lista e tente novamente.'; end if;
 previous_teams=(select coalesce(jsonb_agg(te.name order by te.name),'[]'::jsonb) from public.customer_teams ct join public.teams te on te.id=ct.team_id where ct.customer_id=c.id);
 update public.customers set return_date=case when data ? 'return_date' then (data->>'return_date')::date else return_date end,return_automatic=case when data ? 'return_automatic' then (data->>'return_automatic')::boolean else return_automatic end,return_message=case when data ? 'return_message' then data->>'return_message' else return_message end,return_instance_id=case when data ? 'return_instance_id' then (data->>'return_instance_id')::uuid else return_instance_id end,name=data->>'name',phone=data->>'phone',shirt_types=case when data ? 'shirt_types' then array(select jsonb_array_elements_text(data->'shirt_types')) else shirt_types end,desired_shirt=data->>'desired_shirt',size=data->>'size',birthday=(data->>'birthday')::date,has_purchased=(data->>'has_purchased')::boolean,has_referrals=(data->>'has_referrals')::boolean,can_receive_campaigns=(data->>'can_receive_campaigns')::boolean,total_spent=(data->>'total_spent')::numeric,order_count=(data->>'order_count')::integer,last_purchase_at=(data->>'last_purchase_at')::date where id=c.id;
 else
 insert into public.customers(return_date,return_automatic,return_message,return_instance_id,organization_id,name,phone,shirt_types,desired_shirt,size,birthday,has_purchased,has_referrals,can_receive_campaigns,total_spent,order_count,last_purchase_at)
 values((data->>'return_date')::date,coalesce((data->>'return_automatic')::boolean,false),data->>'return_message',(data->>'return_instance_id')::uuid,org,data->>'name',data->>'phone',array(select jsonb_array_elements_text(coalesce(data->'shirt_types','[]'::jsonb))),data->>'desired_shirt',data->>'size',(data->>'birthday')::date,(data->>'has_purchased')::boolean,(data->>'has_referrals')::boolean,(data->>'can_receive_campaigns')::boolean,(data->>'total_spent')::numeric,(data->>'order_count')::integer,(data->>'last_purchase_at')::date) returning * into c;
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

create function public.customer_returns(org uuid, automatic boolean, page_number integer default 0) returns jsonb language sql stable security invoker set search_path='' as $$
 with due as (
 select c.*,ca.status as return_status from public.customers c left join public.campaigns ca on ca.id=c.return_campaign_id
 where c.organization_id=org and public.is_member(org) and c.archived_at is null
 and c.return_date <= (now() at time zone 'America/Sao_Paulo')::date
 and (not c.return_automatic or (ca.status in('scheduled','processing','paused','error') and not exists(select 1 from public.whatsapp_dispatches d join public.campaign_recipients r on r.id=d.recipient_id where r.campaign_id=ca.id and d.status='accepted')))
 ), page as (select * from due where return_automatic=automatic order by return_date,name,id limit 20 offset greatest(page_number,0)*20)
 select jsonb_build_object('manual',(select count(*) from due where not return_automatic),'automatic',(select count(*) from due where return_automatic),
 'rows',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('customer_teams',coalesce((select jsonb_agg(jsonb_build_object('teams',jsonb_build_object('name',t.name))) from public.customer_teams ct join public.teams t on t.id=ct.team_id where ct.customer_id=p.id),'[]'::jsonb))) from page p),'[]'::jsonb));
$$;
revoke all on function public.customer_returns(uuid,boolean,integer) from public,anon;
grant execute on function public.customer_returns(uuid,boolean,integer) to authenticated;
notify pgrst,'reload schema';
commit;

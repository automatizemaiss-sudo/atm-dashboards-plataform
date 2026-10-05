begin;
alter table public.campaigns add column delay_min_seconds integer not null default 15;
alter table public.campaigns add column delay_max_seconds integer not null default 30;
alter table public.campaigns add column archived_at timestamptz;
alter table public.campaigns add constraint campaign_delay_valid check(delay_min_seconds>=1 and delay_max_seconds>=delay_min_seconds and delay_max_seconds<=3600);
alter table public.whatsapp_instances add column next_dispatch_at timestamptz;
alter table public.whatsapp_dispatches drop constraint whatsapp_dispatches_recipient_id_message_id_key;
create unique index dispatch_one_live_attempt on public.whatsapp_dispatches(recipient_id,message_id) where status<>'skipped';
alter table public.whatsapp_dispatches add column ready_at timestamptz not null default now();
create function public.create_campaign_with_delay(org uuid,title text,segment uuid,instance uuid,content jsonb,schedule timestamptz,delay_min integer,delay_max integer) returns uuid language plpgsql security definer set search_path='' as $$
declare cid uuid;
begin
 if delay_min is null or delay_max is null or delay_min<1 or delay_max<delay_min or delay_max>3600 then raise exception 'Intervalo inválido: mínimo de 1 segundo, máximo de 3600 segundos';end if;
 cid=public.create_campaign(org,title,segment,instance,content,schedule);
 update public.campaigns set delay_min_seconds=delay_min,delay_max_seconds=delay_max where id=cid;
 return cid;
end; $$;
create function public.set_campaign_archived(campaign uuid,archived boolean) returns void language plpgsql security definer set search_path='' as $$
declare ca public.campaigns;
begin
 select * into ca from public.campaigns where id=campaign for update;
 if not found or not public.is_member(ca.organization_id) then raise exception 'Acesso negado';end if;
 update public.campaigns set archived_at=case when archived then coalesce(archived_at,now()) else null end,status=case when archived and status in('draft','scheduled','processing','paused','error') then 'cancelled' else status end where id=campaign;
 if archived then update public.whatsapp_dispatches d set status='skipped' from public.campaign_recipients r where r.id=d.recipient_id and r.campaign_id=campaign and d.status='reserved';end if;
end; $$;
create or replace function public.claim_whatsapp_dispatch() returns jsonb language plpgsql security definer set search_path='' as $$
declare campaign public.campaigns;dispatch public.whatsapp_dispatches;recipient public.campaign_recipients;msg public.campaign_messages;ready timestamptz;
begin
 -- Serialize per instance, including messages reserved by another campaign.
 select ca.* into campaign from public.campaigns ca join public.organizations o on o.id=ca.organization_id join public.whatsapp_instances i on i.id=ca.instance_id
 where o.slug='futpb' and i.enabled and ca.archived_at is null and ca.status in('processing','scheduled') and (ca.scheduled_at is null or ca.scheduled_at<=now())
 and not exists(select 1 from public.whatsapp_dispatches d where d.instance_id=i.id and d.status in('reserved','sending','unknown'))
 order by ca.created_at for update of ca,i skip locked limit 1;
 if not found then return jsonb_build_object('available',false);end if;
 update public.campaigns set status='processing' where id=campaign.id;
 select r.* into recipient from public.campaign_recipients r join public.customers c on c.id=r.customer_id
 where r.campaign_id=campaign.id and c.archived_at is null and c.can_receive_campaigns is distinct from false and exists(select 1 from public.campaign_messages m where m.campaign_id=campaign.id and not exists(select 1 from public.whatsapp_dispatches d where d.recipient_id=r.id and d.message_id=m.id and d.status<>'skipped')) order by r.id limit 1;
 if not found then update public.campaigns set status='completed' where id=campaign.id;return jsonb_build_object('available',false);end if;
 select m.* into msg from public.campaign_messages m where m.campaign_id=campaign.id and not exists(select 1 from public.whatsapp_dispatches d where d.recipient_id=recipient.id and d.message_id=m.id and d.status<>'skipped') order by m.position limit 1;
 select greatest(coalesce(next_dispatch_at,clock_timestamp()),clock_timestamp()) into ready from public.whatsapp_instances where id=campaign.instance_id;
 insert into public.whatsapp_dispatches(organization_id,recipient_id,message_id,instance_id,ready_at) values(campaign.organization_id,recipient.id,msg.id,campaign.instance_id,ready) returning * into dispatch;
 return jsonb_build_object('available',true,'dispatch_id',dispatch.id,'ready_at',ready,'wait_seconds',greatest(0,ceil(extract(epoch from ready-clock_timestamp()))),'instance_id',campaign.instance_id,'organization_id',campaign.organization_id,'number',regexp_replace(recipient.snapshot->>'phone','[^0-9]','','g'),'kind',msg.kind,'storage_path',msg.storage_path,'text',replace(coalesce(msg.body,''),'{{nome}}',split_part(recipient.snapshot->>'name',' ',1)));
end; $$;
create or replace function public.authorize_whatsapp_dispatch(dispatch_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.whatsapp_dispatches; allowed boolean;
begin
 select * into d from public.whatsapp_dispatches where id=dispatch_id for update;
 if not found then raise exception 'Envio desconhecido'; end if;
 if d.status='skipped' then return jsonb_build_object('allowed',false);end if;
 if d.status<>'reserved' then raise exception 'Envio já autorizado; não repetir';end if;
 if d.ready_at>clock_timestamp() then raise exception 'Aguardar intervalo antes de enviar';end if;
 select ca.status='processing' and ca.archived_at is null and i.enabled and c.archived_at is null and c.can_receive_campaigns is distinct from false into allowed
 from public.campaign_recipients r join public.campaigns ca on ca.id=r.campaign_id join public.customers c on c.id=r.customer_id join public.whatsapp_instances i on i.id=ca.instance_id where r.id=d.recipient_id;
 update public.whatsapp_dispatches set status=case when allowed then 'sending' else 'skipped' end where id=d.id;
 return jsonb_build_object('allowed',coalesce(allowed,false));
end; $$;
create or replace function public.control_campaign(campaign uuid, command text) returns void language plpgsql security definer set search_path='' as $$ declare c public.campaigns; next_status text; begin
 select * into c from public.campaigns where id=campaign for update;
 if not found or not public.is_member(c.organization_id) then raise exception 'Acesso negado'; end if;
 if c.archived_at is not null then raise exception 'Campanha excluída';end if;
 if command='pause' and c.status in ('processing','scheduled') then next_status='paused';
 elsif command='resume' and c.status='paused' then next_status=case when c.scheduled_at>now() then 'scheduled' else 'processing' end;
 elsif command='cancel' and c.status in ('scheduled','processing','paused','error') then next_status='cancelled';
 else raise exception 'Transição inválida'; end if;
 update public.campaigns set status=next_status where id=campaign;
 update public.whatsapp_dispatches d set status='skipped' from public.campaign_recipients r where r.id=d.recipient_id and r.campaign_id=campaign and d.status='reserved';
 insert into public.integration_jobs(organization_id,kind,payload) values(c.organization_id,'campaign.'||command,jsonb_build_object('campaign_id',campaign));
end; $$;
create or replace function public.finish_whatsapp_dispatch(dispatch_id uuid, result jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.whatsapp_dispatches; provider text; internal text; ca public.campaigns; delay integer; next_time timestamptz;
begin
 select * into d from public.whatsapp_dispatches where id=dispatch_id for update;
 if not found then raise exception 'Envio desconhecido'; end if;
 if d.status='accepted' then return jsonb_build_object('status','accepted'); end if;
 if d.status<>'sending' then raise exception 'Envio não autorizado'; end if;
 provider=result->>'messageid'; internal=result->>'id';
 if provider is null or result ? 'error' then
 update public.whatsapp_dispatches set status='unknown' where id=d.id;
 update public.campaign_recipients set error='Resultado incerto; revisar antes de reenviar' where id=d.recipient_id;
 return jsonb_build_object('status','unknown');
 end if;
 update public.whatsapp_dispatches set status='accepted',provider_id=provider,provider_internal_id=internal,
 sent_at=case when result->>'status' in ('Sent','Delivered','Read') then now() else null end where id=d.id;
 if result->>'status' in ('Sent','Delivered','Read') then update public.campaign_recipients set sent_at=coalesce(sent_at,now()) where id=d.recipient_id; end if;
 select c.* into ca from public.campaigns c join public.campaign_recipients r on r.campaign_id=c.id where r.id=d.recipient_id for update of c;
 delay=ca.delay_min_seconds+floor(random()*(ca.delay_max_seconds-ca.delay_min_seconds+1))::integer;
 next_time=clock_timestamp()+make_interval(secs=>delay);
 update public.whatsapp_instances set next_dispatch_at=next_time where id=d.instance_id;
 if ca.status='processing' and not exists(select 1 from public.campaign_recipients r join public.customers c on c.id=r.customer_id join public.campaign_messages m on m.campaign_id=r.campaign_id where r.campaign_id=ca.id and c.archived_at is null and c.can_receive_campaigns is distinct from false and not exists(select 1 from public.whatsapp_dispatches wd where wd.recipient_id=r.id and wd.message_id=m.id and wd.status<>'skipped')) then update public.campaigns set status='completed' where id=ca.id;end if;
 return jsonb_build_object('status','accepted','provider_id',provider,'delay_seconds',delay,'next_dispatch_at',next_time);
end; $$;
revoke all on function public.create_campaign_with_delay(uuid,text,uuid,uuid,jsonb,timestamptz,integer,integer),public.set_campaign_archived(uuid,boolean) from public,anon;
grant execute on function public.create_campaign_with_delay(uuid,text,uuid,uuid,jsonb,timestamptz,integer,integer),public.set_campaign_archived(uuid,boolean) to authenticated;
create function public.update_campaign_delay(campaign uuid,delay_min integer,delay_max integer) returns void language plpgsql security definer set search_path='' as $$
declare ca public.campaigns;
begin
 select * into ca from public.campaigns where id=campaign for update;
 if not found or not public.is_member(ca.organization_id) then raise exception 'Acesso negado';end if;
 if ca.archived_at is not null then raise exception 'Campanha excluída';end if;
 if delay_min is null or delay_max is null or delay_min<1 or delay_max<delay_min or delay_max>3600 then raise exception 'Intervalo inválido';end if;
 update public.campaigns set delay_min_seconds=delay_min,delay_max_seconds=delay_max where id=campaign;
end; $$;
revoke all on function public.update_campaign_delay(uuid,integer,integer) from public,anon;
grant execute on function public.update_campaign_delay(uuid,integer,integer) to authenticated;
notify pgrst,'reload schema';
commit;

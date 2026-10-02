begin;
create table public.whatsapp_dispatches (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations,
 recipient_id uuid not null, message_id uuid not null, instance_id uuid not null,
 status text not null default 'reserved' check(status in ('reserved','sending','accepted','unknown','skipped')),
 provider_id text, provider_internal_id text, sent_at timestamptz, delivered_at timestamptz, read_at timestamptz,
 created_at timestamptz not null default now(), unique(recipient_id,message_id), unique(instance_id,provider_id),
 foreign key(organization_id,recipient_id) references public.campaign_recipients(organization_id,id),
 foreign key(organization_id,message_id) references public.campaign_messages(organization_id,id),
 foreign key(organization_id,instance_id) references public.whatsapp_instances(organization_id,id)
);
create table public.whatsapp_webhook_keys(instance_id uuid primary key references public.whatsapp_instances, token_hash text not null);
alter table public.whatsapp_webhook_keys enable row level security;
alter table public.whatsapp_dispatches enable row level security;
create policy member_read on public.whatsapp_dispatches for select to authenticated using(public.is_member(organization_id));
create function public.claim_whatsapp_dispatch() returns jsonb language plpgsql security definer set search_path='' as $$
declare campaign public.campaigns; dispatch public.whatsapp_dispatches; recipient public.campaign_recipients; msg public.campaign_messages;
begin
 -- One direct dispatch per tick for FUTPB. No automatic reclaim of uncertain sends.
 select ca.* into campaign from public.campaigns ca join public.organizations o on o.id=ca.organization_id join public.whatsapp_instances i on i.id=ca.instance_id
 where o.slug='futpb' and i.enabled and ca.status in ('processing','scheduled') and (ca.scheduled_at is null or ca.scheduled_at<=now())
 order by ca.created_at for update of ca skip locked limit 1;
 if not found then return jsonb_build_object('available',false); end if;
 if exists(select 1 from public.whatsapp_dispatches d join public.campaign_recipients r on r.id=d.recipient_id where r.campaign_id=campaign.id and d.status in ('reserved','sending','unknown')) then return jsonb_build_object('available',false,'reason','Envio pendente de confirmação/reconciliação'); end if;
 update public.campaigns set status='processing' where id=campaign.id;
 select r.* into recipient from public.campaign_recipients r join public.customers c on c.id=r.customer_id
 where r.campaign_id=campaign.id and c.can_receive_campaigns is distinct from false and exists(select 1 from public.campaign_messages m where m.campaign_id=campaign.id and not exists(select 1 from public.whatsapp_dispatches d where d.recipient_id=r.id and d.message_id=m.id)) order by r.id limit 1;
 if not found then update public.campaigns set status='completed' where id=campaign.id;return jsonb_build_object('available',false); end if;
 select m.* into msg from public.campaign_messages m where m.campaign_id=campaign.id and not exists(select 1 from public.whatsapp_dispatches d where d.recipient_id=recipient.id and d.message_id=m.id) order by m.position limit 1;
 insert into public.whatsapp_dispatches(organization_id,recipient_id,message_id,instance_id) values(campaign.organization_id,recipient.id,msg.id,campaign.instance_id) returning * into dispatch;
 return jsonb_build_object('available',true,'dispatch_id',dispatch.id,'instance_id',campaign.instance_id,'organization_id',campaign.organization_id,'number',regexp_replace(recipient.snapshot->>'phone','[^0-9]','','g'),'kind',msg.kind,'storage_path',msg.storage_path,'text',replace(coalesce(msg.body,''),'{{nome}}',split_part(recipient.snapshot->>'name',' ',1)));
end; $$;
create function public.authorize_whatsapp_dispatch(dispatch_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.whatsapp_dispatches; allowed boolean;
begin
 select * into d from public.whatsapp_dispatches where id=dispatch_id for update;
 if not found or d.status<>'reserved' then raise exception 'Envio já autorizado ou desconhecido; não repetir'; end if;
 select ca.status='processing' and i.enabled and c.can_receive_campaigns is distinct from false into allowed
 from public.campaign_recipients r join public.campaigns ca on ca.id=r.campaign_id join public.customers c on c.id=r.customer_id join public.whatsapp_instances i on i.id=ca.instance_id where r.id=d.recipient_id;
 update public.whatsapp_dispatches set status=case when allowed then 'sending' else 'skipped' end where id=d.id;
 return jsonb_build_object('allowed',coalesce(allowed,false));
end; $$;
create function public.finish_whatsapp_dispatch(dispatch_id uuid, result jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.whatsapp_dispatches; provider text; internal text;
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
 return jsonb_build_object('status','accepted','provider_id',provider);
end; $$;
create function public.ingest_uazapi_webhook(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare iid uuid; org uuid; external text; evtype text; state text; msgid text; ts timestamptz; target uuid; phone text; message jsonb;
begin
 select i.id,i.organization_id into iid,org from public.whatsapp_instances i join public.whatsapp_webhook_keys k on k.instance_id=i.id
 where i.enabled and k.token_hash=encode(sha256(convert_to(coalesce(payload->>'token',''),'UTF8')),'hex');
 if iid is null then raise exception 'Webhook não autorizado'; end if;
 evtype=payload->>'EventType';
 if evtype not in ('messages','messages_update') then return jsonb_build_object('status','ignored'); end if;
 external=evtype||':'||encode(sha256(convert_to((payload-'token'-'BaseUrl')::text,'UTF8')),'hex');
 insert into public.integration_events(organization_id,provider,external_id,payload) values(org,'uazapi',external,payload-'token'-'BaseUrl') on conflict do nothing;
 if not found then return jsonb_build_object('status','duplicate'); end if;
 if evtype='messages_update' then
 state=coalesce(payload->>'state',payload->'event'->>'Type');ts=to_timestamp((payload->'event'->>'Timestamp')::double precision);
 if state not in ('Sent','Delivered','Read') or ts is null then return jsonb_build_object('status','stored'); end if;
 for msgid in select jsonb_array_elements_text(coalesce(payload->'event'->'MessageIDs','[]'::jsonb)) loop
 update public.whatsapp_dispatches set sent_at=coalesce(sent_at,ts),delivered_at=case when state in ('Delivered','Read') then coalesce(delivered_at,ts) else delivered_at end,read_at=case when state='Read' then coalesce(read_at,ts) else read_at end where instance_id=iid and(provider_id=msgid or provider_internal_id=msgid) returning recipient_id into target;
 if target is not null then update public.campaign_recipients set sent_at=coalesce(sent_at,ts),delivered_at=case when state in ('Delivered','Read') then coalesce(delivered_at,ts) else delivered_at end,read_at=case when state='Read' then coalesce(read_at,ts) else read_at end where id=target;end if;
 end loop;
 else
 message=payload->'message';ts=to_timestamp((message->>'messageTimestamp')::double precision/1000);
 if message->>'fromMe'='false' and coalesce(message->>'isGroup','false')='false' and ts is not null then
 phone=regexp_replace(split_part(coalesce(message->>'chatid',''),'@',1),'[^0-9]','','g');
 -- First implementation: response attributed to the last sent campaign for this contact.
 select r.id into target from public.campaign_recipients r join public.campaigns ca on ca.id=r.campaign_id where ca.instance_id=iid and regexp_replace(r.snapshot->>'phone','[^0-9]','','g')=phone and r.sent_at<=ts order by r.sent_at desc limit 1;
 if target is not null then update public.campaign_recipients set replied_at=coalesce(replied_at,ts) where id=target; end if;
 end if;
 end if;
 return jsonb_build_object('status','stored');
end; $$;
revoke all on function public.claim_whatsapp_dispatch() from public,anon,authenticated;
revoke all on function public.authorize_whatsapp_dispatch(uuid) from public,anon,authenticated;
revoke all on function public.finish_whatsapp_dispatch(uuid,jsonb) from public,anon,authenticated;
revoke all on function public.ingest_uazapi_webhook(jsonb) from public,anon,authenticated;
grant execute on function public.claim_whatsapp_dispatch() to service_role;
grant execute on function public.authorize_whatsapp_dispatch(uuid) to service_role;
grant execute on function public.finish_whatsapp_dispatch(uuid,jsonb) to service_role;
grant execute on function public.ingest_uazapi_webhook(jsonb) to service_role;
commit;

begin;
-- WhatsApp may report Brazilian mobile numbers without the ninth digit.
create function public.whatsapp_phone_key(value text) returns text language sql immutable set search_path='' as $$
 select case when digits ~ '^55[0-9]{2}9[6-9][0-9]{7}$' then left(digits,4)||substring(digits from 6) else digits end
 from (select regexp_replace(split_part(coalesce(value,''),'@',1),'[^0-9]','','g') digits) p;
$$;
create function public.apply_uazapi_reply(instance uuid,payload jsonb) returns boolean language plpgsql security definer set search_path='' as $$
declare m jsonb:=payload->'message'; ts timestamptz; phone text; target uuid; candidates integer;
begin
 if payload->>'EventType'<>'messages' or m->>'fromMe' is distinct from 'false' or coalesce(m->>'isGroup','false')<>'false' then return false; end if;
 if coalesce(m->>'messageTimestamp','') !~ '^[0-9]+$' then return false; end if;
 ts=to_timestamp((m->>'messageTimestamp')::double precision/1000);
 phone=public.whatsapp_phone_key(coalesce(nullif(m->>'sender_pn',''),nullif(m->>'chatid',''),payload->'chat'->>'phone'));
 if phone='' or phone !~ '^55[0-9]{10,11}$' then return false; end if;
 select count(distinct r.customer_id) into candidates from public.campaign_recipients r join public.campaigns ca on ca.id=r.campaign_id
 where ca.instance_id=instance and public.whatsapp_phone_key(r.snapshot->>'phone')=phone and r.sent_at<=ts;
 if candidates<>1 then return false; end if;
 select r.id into target from public.campaign_recipients r join public.campaigns ca on ca.id=r.campaign_id
 where ca.instance_id=instance and public.whatsapp_phone_key(r.snapshot->>'phone')=phone and r.sent_at<=ts
 order by r.sent_at desc,r.id limit 1;
 update public.campaign_recipients set replied_at=least(coalesce(replied_at,ts),ts) where id=target;
 return true;
end; $$;
revoke all on function public.apply_uazapi_reply(uuid,jsonb) from public,anon,authenticated;
create or replace function public.ingest_uazapi_webhook(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
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
 perform public.apply_uazapi_reply(iid,payload);
 end if;
 return jsonb_build_object('status','stored');
end; $$;

-- Reconcile stored replies only for organizations with exactly one instance.
-- With multiple instances, the original event does not retain authenticated instance identity.
do $$ declare e record; begin
 for e in select ev.payload,i.id from public.integration_events ev
 join public.whatsapp_instances i on i.organization_id=ev.organization_id
 where ev.provider='uazapi' and ev.payload->>'EventType'='messages'
 and (select count(*) from public.whatsapp_instances x where x.organization_id=ev.organization_id)=1
 loop perform public.apply_uazapi_reply(e.id,e.payload); end loop;
end; $$;
notify pgrst,'reload schema';
commit;

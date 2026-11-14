begin;
-- Persistent dispatch state drives alerts; nothing is auto-retried or dismissed.
create function public.campaign_delivery_alerts(org uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(a order by a.created_at),'[]'::jsonb) from (
  select d.id as dispatch_id,r.campaign_id,ca.name as campaign_name,r.snapshot->>'name' as contact_name,d.status,d.created_at,d.ready_at,
   case when d.status='unknown' then 'Envio sem confirmação. A fila desta instância está bloqueada para evitar duplicatas.'
    when d.status='sending' then 'O envio não terminou no prazo esperado. Confira o retorno da API.'
    else 'Reserva de envio parada além do horário previsto. Confira a execução do n8n.' end as message
  from public.whatsapp_dispatches d join public.campaign_recipients r on r.id=d.recipient_id join public.campaigns ca on ca.id=r.campaign_id
  where d.organization_id=org and public.is_member(org)
   and (d.status='unknown' or (d.status in ('reserved','sending') and d.ready_at<now()-interval '2 minutes'))
 ) a;
$$;
create function public.confirm_whatsapp_dispatch_sent(dispatch_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare d public.whatsapp_dispatches; ca public.campaigns;
begin
 select * into d from public.whatsapp_dispatches where id=dispatch_id for update;
 if not found or not public.is_member(d.organization_id) then raise exception 'Acesso negado';end if;
 if d.status='accepted' then return;end if;
 if d.status<>'unknown' and not(d.status='sending' and d.ready_at<now()-interval '2 minutes') then raise exception 'Este envio ainda não pode ser confirmado manualmente.';end if;
 select c.* into ca from public.campaigns c join public.campaign_recipients r on r.campaign_id=c.id where r.id=d.recipient_id;
 update public.whatsapp_dispatches set status='accepted',sent_at=coalesce(sent_at,now()) where id=d.id;
 update public.campaign_recipients set sent_at=coalesce(sent_at,d.sent_at,now()),error=case when error='Resultado incerto; revisar antes de reenviar' then null else error end where id=d.recipient_id;
 update public.whatsapp_instances set next_dispatch_at=greatest(coalesce(next_dispatch_at,now()),now()+make_interval(secs=>ca.delay_min_seconds)) where id=d.instance_id;
 insert into public.integration_events(organization_id,provider,external_id,payload)
 values(d.organization_id,'manual_dispatch_confirmation',d.id::text,jsonb_build_object('dispatch_id',d.id,'outcome','sent','confirmed_at',now(),'confirmed_by',auth.uid(),'basis','Responsável confirmou o envio. O horário registrado é o da confirmação manual.')) on conflict do nothing;
end; $$;
-- Keep the installed reservation logic intact, including partial-sync guards.
alter function public.claim_whatsapp_dispatch() rename to claim_whatsapp_dispatch_core;
revoke all on function public.claim_whatsapp_dispatch_core() from public,anon,authenticated,service_role;
create function public.claim_whatsapp_dispatch() returns jsonb language plpgsql security definer set search_path='' as $$
declare task jsonb; blocker public.whatsapp_dispatches; blocked boolean; notify boolean=false;
begin
 task=public.claim_whatsapp_dispatch_core();
 if coalesce((task->>'available')::boolean,false) then return task;end if;
  select d.* into blocker from public.whatsapp_dispatches d
   where d.organization_id in(select o.id from public.organizations o where o.slug='futpb') and d.status in('reserved','sending','unknown')
   and exists(select 1 from public.campaigns ca join public.whatsapp_instances wi on wi.id=ca.instance_id where ca.instance_id=d.instance_id and wi.enabled and ca.archived_at is null and ca.status in('processing','scheduled') and (ca.scheduled_at is null or ca.scheduled_at<=now()))
   order by case when d.status='unknown' then 0 else 1 end,d.created_at limit 1;
  if found then
   blocked=blocker.status='unknown' or blocker.ready_at<now()-interval '2 minutes';
   if blocked then
    perform pg_advisory_xact_lock(hashtext('dispatch-alert:'||blocker.id::text));
    select not exists(select 1 from public.integration_events ev where ev.organization_id=blocker.organization_id and ev.provider='dispatch_block_alert' and ev.payload->>'dispatch_id'=blocker.id::text and ev.created_at>now()-interval '15 minutes') into notify;
    if notify then
     insert into public.integration_events(organization_id,provider,external_id,payload) values(blocker.organization_id,'dispatch_block_alert',gen_random_uuid()::text,jsonb_build_object('dispatch_id',blocker.id,'status',blocker.status));
    end if;
   end if;
   return jsonb_build_object('available',false,'blocked',blocked,'notify',notify,'reason',case when blocker.status='unknown' then 'uncertain_delivery' when blocked then 'stalled_dispatch' else 'instance_busy' end,
    'dispatch_id',blocker.id,'message',case when blocker.status='unknown' then 'Envio sem confirmação bloqueando a instância. Confira o alerta na aba Campanhas antes de reenviar.' when blocked then 'Envio ou reserva parado além do horário previsto. Confira a execução do n8n e a aba Campanhas.' else 'Outro envio desta instância está em andamento ou aguardando o intervalo.' end);
  end if;
  return jsonb_build_object('available',false,'blocked',false,'reason','no_eligible_campaign','message','Nenhuma campanha habilitada para envio agora.');
end; $$;
revoke all on function public.claim_whatsapp_dispatch() from public,anon,authenticated;
grant execute on function public.claim_whatsapp_dispatch() to service_role;

revoke all on function public.campaign_delivery_alerts(uuid),public.confirm_whatsapp_dispatch_sent(uuid) from public,anon;
grant execute on function public.campaign_delivery_alerts(uuid),public.confirm_whatsapp_dispatch_sent(uuid) to authenticated;
notify pgrst,'reload schema';
commit;

begin;
create table public.registration_issues (
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations,
 source text not null check(source in ('sheet','campaign')),
 issue_key text not null, customer_id uuid, recipient_id uuid,
 row_number integer, contact_name text, field text not null, value text, message text not null,
 queued boolean not null default false, resolved_at timestamptz,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 unique(organization_id,source,issue_key),
 foreign key(organization_id,customer_id) references public.customers(organization_id,id),
 foreign key(organization_id,recipient_id) references public.campaign_recipients(organization_id,id)
);
alter table public.registration_issues enable row level security;
revoke all on public.registration_issues from anon,authenticated;
grant select on public.registration_issues to authenticated;
create policy member_read on public.registration_issues for select to authenticated using(public.is_member(organization_id));
create index registration_issues_recipient on public.registration_issues(recipient_id);
create index registration_issues_open on public.registration_issues(organization_id,source) where resolved_at is null;

-- One validator for direct saves and campaign preflight. Keep birthday years explicit.
create function public.contact_registration_errors(data jsonb) returns jsonb language plpgsql stable set search_path='' as $$
declare errors jsonb='[]'; key text; label text; v text; d date; today date=(now() at time zone 'America/Sao_Paulo')::date;
begin
 if coalesce(trim(data->>'name'),'')='' then errors=errors||jsonb_build_array(jsonb_build_object('field','Nome Completo','value',data->>'name','message','Nome obrigatório.'));end if;
 if coalesce(data->>'phone','') !~ '^\+55[0-9]{10,11}$' then errors=errors||jsonb_build_array(jsonb_build_object('field','Telefone','value',data->>'phone','message','Informe telefone com DDD.'));end if;
 foreach key in array array['birthday','last_purchase_at'] loop
  label=case key when 'birthday' then 'Data de aniversário' else 'Última Compra' end;
  v=nullif(data->>key,'');
  if v is not null then
   begin
    if v !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'Formato inválido';end if;
    d=v::date;
    if d<date '1900-01-01' or d>today then raise exception 'Data fora do intervalo';end if;
   exception when others then
    errors=errors||jsonb_build_array(jsonb_build_object('field',label,'value',v,'message',label||': informe uma data válida entre 1900 e hoje, com ano completo.'));
   end;
  end if;
 end loop;
 return errors;
end; $$;
create function public.validate_contact_registration() returns trigger language plpgsql set search_path='' as $$
declare errors jsonb;
begin
 errors=public.contact_registration_errors(to_jsonb(new));
 if jsonb_array_length(errors)>0 then raise exception '%',errors->0->>'message';end if;
 return new;
end; $$;
create trigger validate_contact_registration before insert or update of name,phone,birthday,last_purchase_at on public.customers for each row execute function public.validate_contact_registration();

-- Only a private sync lease can replace the sheet validation report.
create function public.sheet_sync_report_validation(run_id uuid, issues jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare run public.sheet_sync_runs; item jsonb;
begin
 select * into run from public.sheet_sync_runs where id=run_id and status='running' and expires_at>now() for update;
 if not found then raise exception 'Execução inválida ou expirada';end if;
 if run.plan is not null then raise exception 'Validação deve ocorrer antes da reconciliação';end if;
 if jsonb_typeof(issues) is distinct from 'array' or jsonb_array_length(issues)>10000 then raise exception 'Relatório inválido';end if;
 update public.registration_issues set resolved_at=now(),updated_at=now() where organization_id=run.organization_id and source='sheet' and resolved_at is null;
 for item in select value from jsonb_array_elements(issues) loop
  insert into public.registration_issues(organization_id,source,issue_key,row_number,contact_name,field,value,message,queued)
  values(run.organization_id,'sheet',coalesce(item->>'row_number','0')||':'||coalesce(item->>'field','Cadastro'),(item->>'row_number')::integer,item->>'contact_name',coalesce(item->>'field','Cadastro'),item->>'value',item->>'message',true)
  on conflict(organization_id,source,issue_key) do update set row_number=excluded.row_number,contact_name=excluded.contact_name,field=excluded.field,value=excluded.value,message=excluded.message,queued=true,resolved_at=null,updated_at=now();
 end loop;
 if jsonb_array_length(issues)>0 then update public.sheet_sync_runs set status='expired',expires_at=now() where id=run.id;end if;
 return jsonb_build_object('run_id',run.id,'valid',jsonb_array_length(issues)=0,'issues',jsonb_array_length(issues));
end; $$;
create function public.queue_registration_issue(issue uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 update public.registration_issues set queued=true,updated_at=now() where id=issue and resolved_at is null and public.is_member(organization_id);
 if not found then raise exception 'Pendência não encontrada ou acesso negado';end if;
end; $$;
-- Manual classification keeps uncertain provider outcomes intact.
create function public.report_campaign_registration_issue(recipient uuid) returns void language plpgsql security definer set search_path='' as $$
declare r public.campaign_recipients;
begin
 select * into r from public.campaign_recipients where id=recipient for update;
 if not found or not public.is_member(r.organization_id) then raise exception 'Acesso negado';end if;
 if nullif(r.error,'') is null then raise exception 'Este destinatário não tem erro registrado';end if;
 insert into public.registration_issues(organization_id,source,issue_key,customer_id,recipient_id,contact_name,field,value,message,queued)
 values(r.organization_id,'campaign',r.id::text||':Cadastro',r.customer_id,r.id,r.snapshot->>'name','Cadastro',r.snapshot->>'phone',r.error,true)
 on conflict(organization_id,source,issue_key) do update set message=excluded.message,queued=true,resolved_at=null,updated_at=now();
end; $$;
create function public.resolve_registration_issue(issue uuid) returns void language plpgsql security definer set search_path='' as $$
declare item public.registration_issues; c public.customers; errors jsonb;
begin
 select * into item from public.registration_issues where id=issue for update;
 if not found or not public.is_member(item.organization_id) then raise exception 'Acesso negado';end if;
 if item.source='sheet' then raise exception 'Corrija na planilha e execute a sincronização para validar a correção.';end if;
 select * into c from public.customers where id=item.customer_id and organization_id=item.organization_id;
 if not found then raise exception 'Contato não encontrado';end if;
 errors=public.contact_registration_errors(to_jsonb(c));
 if jsonb_array_length(errors)>0 then raise exception '%',errors->0->>'message';end if;
 update public.registration_issues set resolved_at=now(),updated_at=now() where id=item.id;
 -- Preserve the original campaign snapshot and dispatch history. No automatic resend.
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
 where r.campaign_id=campaign.id and not exists(select 1 from public.registration_issues ri where ri.recipient_id=r.id and ri.source='campaign') and c.archived_at is null and c.can_receive_campaigns is distinct from false and exists(select 1 from public.campaign_messages m where m.campaign_id=campaign.id and not exists(select 1 from public.whatsapp_dispatches d where d.recipient_id=r.id and d.message_id=m.id and d.status<>'skipped')) order by r.id limit 1;
 if not found then update public.campaigns set status='completed' where id=campaign.id;return jsonb_build_object('available',false);end if;
 select m.* into msg from public.campaign_messages m where m.campaign_id=campaign.id and not exists(select 1 from public.whatsapp_dispatches d where d.recipient_id=recipient.id and d.message_id=m.id and d.status<>'skipped') order by m.position limit 1;
 select greatest(coalesce(next_dispatch_at,clock_timestamp()),clock_timestamp()) into ready from public.whatsapp_instances where id=campaign.instance_id;
 insert into public.whatsapp_dispatches(organization_id,recipient_id,message_id,instance_id,ready_at) values(campaign.organization_id,recipient.id,msg.id,campaign.instance_id,ready) returning * into dispatch;
 return jsonb_build_object('available',true,'dispatch_id',dispatch.id,'ready_at',ready,'wait_seconds',greatest(0,ceil(extract(epoch from ready-clock_timestamp()))),'instance_id',campaign.instance_id,'organization_id',campaign.organization_id,'number',regexp_replace(recipient.snapshot->>'phone','[^0-9]','','g'),'kind',msg.kind,'storage_path',msg.storage_path,'text',replace(coalesce(msg.body,''),'{{nome}}',split_part(recipient.snapshot->>'name',' ',1)));
end; $$;
create or replace function public.authorize_whatsapp_dispatch(dispatch_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.whatsapp_dispatches; allowed boolean; r public.campaign_recipients; c public.customers; errors jsonb; item jsonb;
begin
 select * into d from public.whatsapp_dispatches where id=dispatch_id for update;
 if not found then raise exception 'Envio desconhecido'; end if;
 if d.status='skipped' then return jsonb_build_object('allowed',false);end if;
 if d.status<>'reserved' then raise exception 'Envio já autorizado; não repetir';end if;
 if d.ready_at>clock_timestamp() then raise exception 'Aguardar intervalo antes de enviar';end if;
 select ca.status='processing' and ca.archived_at is null and i.enabled and cc.archived_at is null and cc.can_receive_campaigns is distinct from false into allowed
 from public.campaign_recipients rr join public.campaigns ca on ca.id=rr.campaign_id join public.customers cc on cc.id=rr.customer_id join public.whatsapp_instances i on i.id=ca.instance_id where rr.id=d.recipient_id;
 if allowed then
  select * into r from public.campaign_recipients where id=d.recipient_id;
  select * into c from public.customers where id=r.customer_id and organization_id=r.organization_id;
  errors=public.contact_registration_errors(to_jsonb(c))||public.contact_registration_errors(r.snapshot);
  if jsonb_array_length(errors)>0 then
   for item in select value from jsonb_array_elements(errors) loop
    insert into public.registration_issues(organization_id,source,issue_key,customer_id,recipient_id,contact_name,field,value,message)
    values(r.organization_id,'campaign',r.id::text||':'||(item->>'field'),r.customer_id,r.id,c.name,item->>'field',item->>'value',item->>'message')
    on conflict(organization_id,source,issue_key) do update set value=excluded.value,message=excluded.message,resolved_at=null,updated_at=now();
   end loop;
   update public.campaign_recipients set error='Erro de cadastro: '||(errors->0->>'message') where id=r.id;
   update public.whatsapp_dispatches set status='skipped' where recipient_id=r.id and status='reserved';
   return jsonb_build_object('allowed',false,'reason','registration_issue');
  end if;
 end if;
 update public.whatsapp_dispatches set status=case when allowed then 'sending' else 'skipped' end where id=d.id;
 return jsonb_build_object('allowed',coalesce(allowed,false));
end; $$;

revoke all on function public.sheet_sync_report_validation(uuid,jsonb) from public,anon,authenticated;
grant execute on function public.sheet_sync_report_validation(uuid,jsonb) to service_role;
revoke all on function public.report_campaign_registration_issue(uuid),public.queue_registration_issue(uuid),public.resolve_registration_issue(uuid) from public,anon;
grant execute on function public.report_campaign_registration_issue(uuid),public.queue_registration_issue(uuid),public.resolve_registration_issue(uuid) to authenticated;
revoke all on function public.contact_registration_errors(jsonb) from public,anon;
grant execute on function public.contact_registration_errors(jsonb) to authenticated,service_role;
notify pgrst,'reload schema';
commit;

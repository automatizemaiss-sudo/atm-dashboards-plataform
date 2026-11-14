begin;
-- Preserve the report with the lease so partial plans remain inspectable.
alter table public.sheet_sync_runs add column validation_issues jsonb;
alter table public.registration_issues add column sheet_customer_id text;
alter table public.registration_issues add column sheet_phone text;
create index registration_issues_sheet_identity on public.registration_issues(organization_id,sheet_phone) where source='sheet' and resolved_at is null;

create function public.sheet_customer_has_issue(org uuid, customer uuid, phone text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.registration_issues ri where ri.organization_id=org and ri.source='sheet' and ri.resolved_at is null
 and (ri.customer_id=customer or lower(ri.sheet_customer_id)=customer::text or ri.sheet_phone=phone));
$$;
create function public.sheet_sync_record_issue(org uuid, item jsonb) returns void language plpgsql security definer set search_path='' as $$
declare target uuid;
begin
 select c.id into target from public.customers c where c.organization_id=org and (c.id=(case when item->>'customer_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then (item->>'customer_id')::uuid end) or c.phone=item->>'phone') order by c.id limit 1;
 insert into public.registration_issues(organization_id,source,issue_key,customer_id,sheet_customer_id,sheet_phone,row_number,contact_name,field,value,message,queued)
 values(org,'sheet',coalesce(item->>'row_number','0')||':'||coalesce(item->>'field','Cadastro'),target,item->>'customer_id',item->>'phone',(item->>'row_number')::integer,item->>'contact_name',coalesce(item->>'field','Cadastro'),item->>'value',item->>'message',true)
 on conflict(organization_id,source,issue_key) do update set customer_id=excluded.customer_id,sheet_customer_id=excluded.sheet_customer_id,sheet_phone=excluded.sheet_phone,row_number=excluded.row_number,contact_name=excluded.contact_name,field=excluded.field,value=excluded.value,message=excluded.message,queued=true,resolved_at=null,updated_at=now();
end; $$;
create or replace function public.sheet_sync_report_validation(run_id uuid, issues jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare run public.sheet_sync_runs; item jsonb; fatal boolean;
begin
 select * into run from public.sheet_sync_runs where id=run_id and status='running' and expires_at>now() for update;
 if not found then raise exception 'Execução inválida ou expirada';end if;
 if run.plan is not null then raise exception 'Validação deve ocorrer antes da reconciliação';end if;
 if jsonb_typeof(issues) is distinct from 'array' or jsonb_array_length(issues)>10000 then raise exception 'Relatório inválido';end if;
 select exists(select 1 from jsonb_array_elements(issues) i where i->>'field'='Estrutura da planilha') into fatal;
 -- A failed structural read cannot prove that previous row errors were corrected.
 if not fatal then
  update public.registration_issues set resolved_at=now(),updated_at=now() where organization_id=run.organization_id and source='sheet' and resolved_at is null;
 end if;
 for item in select value from jsonb_array_elements(issues) loop
  perform public.sheet_sync_record_issue(run.organization_id,item);
 end loop;
 update public.sheet_sync_runs set validation_issues=issues,status=case when fatal then 'expired' else status end,expires_at=case when fatal then now() else expires_at end where id=run.id;
 return jsonb_build_object('run_id',run.id,'valid',jsonb_array_length(issues)=0,'can_sync',not fatal,'issues',jsonb_array_length(issues));
end; $$;
create or replace function public.sheet_sync_plan(run_id uuid, rows jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare run public.sheet_sync_runs; r jsonb; c public.customers; base jsonb; current_value jsonb; incoming jsonb; merged jsonb;
 field_name text; bad boolean; seen uuid[]='{}'; writes jsonb='[]'; conflicts jsonb='[]'; team_name text; team_id uuid; skipped integer=0; row_error text; preflight record;
begin
 select * into run from public.sheet_sync_runs where id=run_id and status='running' and expires_at>now() for update;
 if not found then raise exception 'Execução inválida ou expirada'; end if;
 if run.plan is not null then return run.plan; end if;
 skipped=coalesce(jsonb_array_length(run.validation_issues),0);
 if jsonb_typeof(rows)<>'array' or jsonb_array_length(rows)>9999 then raise exception 'Leitura inválida ou acima do limite'; end if;
 -- Resolve/group identities once, before changes; avoid scanning the grid per row.
 for preflight in
  with resolved as (
   select x.r,case when coalesce(x.r->>'customer_id','')<>'' then by_id.id else by_phone.id end as matched_id
   from jsonb_array_elements(rows) x(r)
   left join public.customers by_id on by_id.organization_id=run.organization_id and by_id.id=(case when x.r->>'customer_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then (x.r->>'customer_id')::uuid end)
   left join public.customers by_phone on by_phone.organization_id=run.organization_id and by_phone.phone=x.r->'value'->>'phone'
  ), counted as (
   select rs.r,rs.matched_id,count(*) over(partition by rs.matched_id) id_count,count(*) over(partition by rs.r->'value'->>'phone') phone_count from resolved rs
  ) select ct.r,ct.matched_id,(coalesce(ct.r->>'customer_id','')<>'' and ct.matched_id is null) as unknown_id
   from counted ct where (coalesce(ct.r->>'customer_id','')<>'' and ct.matched_id is null) or (ct.matched_id is not null and ct.id_count>1) or ct.phone_count>1
 loop
  r=preflight.r;
  perform public.sheet_sync_record_issue(run.organization_id,jsonb_build_object('row_number',r->'row_number','customer_id',coalesce(preflight.matched_id::text,r->>'customer_id'),'phone',r->'value'->>'phone','contact_name',r->'value'->>'name','field',case when preflight.unknown_id then 'ID Cliente' else 'Cadastro' end,'value',r->>'customer_id','message',case when preflight.unknown_id then 'ID Cliente desconhecido nesta organização.' else 'Duas linhas correspondem ao mesmo cliente ou telefone.' end));
 end loop;
 perform set_config('futpb.sync_from_sheet','true',true);
 for r in select value from jsonb_array_elements(rows) loop
 -- Invalid sheet identities are present, not removed; never export them back as new rows.
 if exists(select 1 from public.registration_issues ri where ri.organization_id=run.organization_id and ri.source='sheet' and ri.resolved_at is null and
  (lower(ri.sheet_customer_id)=lower(r->>'customer_id') or ri.sheet_phone=r->'value'->>'phone')) then skipped=skipped+1;continue;end if;
 begin
 incoming=r->'value';
 incoming=jsonb_set(incoming,'{teams}',coalesce((select jsonb_agg(v order by v collate "C") from (select distinct jsonb_array_elements_text(incoming->'teams') v) names),'[]'::jsonb));
 if jsonb_typeof(incoming)<>'object' or incoming->>'phone' is null then raise exception 'Registro inválido'; end if;
 c=null;
 if coalesce(r->>'customer_id','')<>'' then
 select * into c from public.customers where id=(r->>'customer_id')::uuid and organization_id=run.organization_id for update;
 if not found then raise exception 'UUID desconhecido: %',r->>'customer_id'; end if;
 else
 select * into c from public.customers where organization_id=run.organization_id and phone=incoming->>'phone' for update;
 end if;
 if public.sheet_customer_has_issue(run.organization_id,c.id,incoming->>'phone') then skipped=skipped+1;continue;end if;
 if c.id is null then
 insert into public.customers(organization_id,name,phone,last_update_source)
 values(run.organization_id,incoming->>'name',incoming->>'phone','google_sheets') returning * into c;
 end if;
 if c.id=any(seen) then raise exception 'Duas linhas correspondem ao mesmo cliente'; end if;
 seen=array_append(seen,c.id);
 select s.base into base from public.sheet_sync_state s where s.organization_id=run.organization_id and s.customer_id=c.id;
 current_value=public.sync_customer_value(c.id); merged=current_value; bad=false;
 for field_name in select jsonb_object_keys(incoming) loop
 if not current_value ? field_name then raise exception 'Campo não permitido: %',field_name; end if;
 if base is null then
 -- New imports start with minimal values. Existing unlinked rows require review if populated values differ.
 if current_value->field_name is distinct from incoming->field_name and current_value->field_name<>'null'::jsonb and current_value->field_name<>'[]'::jsonb then bad=true; end if;
 merged=jsonb_set(merged,array[field_name],incoming->field_name);
 elsif incoming->field_name is distinct from base->field_name then
 if current_value->field_name is distinct from base->field_name and current_value->field_name is distinct from incoming->field_name then bad=true;
 else merged=jsonb_set(merged,array[field_name],incoming->field_name); end if;
 end if;
 end loop;
 if bad then
 insert into public.sheet_sync_conflicts(organization_id,customer_id,reason,sheet_value,database_value) values(run.organization_id,c.id,'field_conflict',incoming,current_value)
 on conflict(organization_id,customer_id,reason) do update set sheet_value=excluded.sheet_value,database_value=excluded.database_value,created_at=now();
 conflicts=conflicts||jsonb_build_array(jsonb_build_object('customer_id',c.id,'reason','Alterações incompatíveis no mesmo campo', 'sheet',incoming,'database',current_value));
 continue;
 end if;
 if merged is distinct from current_value then
 update public.customers set shirt_types=array(select jsonb_array_elements_text(merged->'shirt_types')),name=merged->>'name',phone=merged->>'phone',desired_shirt=merged->>'desired_shirt',size=merged->>'size',birthday=(merged->>'birthday')::date,
 has_purchased=(merged->>'has_purchased')::boolean,can_receive_campaigns=(merged->>'can_receive_campaigns')::boolean,has_referrals=(merged->>'has_referrals')::boolean,
 total_spent=(merged->>'total_spent')::numeric,order_count=(merged->>'order_count')::integer,last_purchase_at=(merged->>'last_purchase_at')::date,archived_at=case when (merged->>'archived')::boolean then coalesce(archived_at,now()) else null end,last_update_source='google_sheets'
 where id=c.id;
 if merged->'teams' is distinct from current_value->'teams' then
 delete from public.customer_teams where customer_id=c.id;
 for team_name in select jsonb_array_elements_text(merged->'teams') loop
 insert into public.teams(organization_id,name) values(run.organization_id,team_name) on conflict(organization_id,name) do update set name=excluded.name returning id into team_id;
 insert into public.customer_teams(organization_id,customer_id,team_id) values(run.organization_id,c.id,team_id) on conflict do nothing;
 end loop;
 end if;
 end if;
 delete from public.sheet_sync_conflicts where organization_id=run.organization_id and customer_id=c.id;
 writes=writes||jsonb_build_array(jsonb_build_object('customer_id',c.id,'expected',incoming,'original_id',r->>'customer_id','value',merged,'version',(select version from public.customers where id=c.id)));
 exception when data_exception or integrity_constraint_violation or raise_exception then
  get stacked diagnostics row_error=message_text;
  perform public.sheet_sync_record_issue(run.organization_id,jsonb_build_object('row_number',r->'row_number','customer_id',r->>'customer_id','phone',r->'value'->>'phone','contact_name',r->'value'->>'name','field','Cadastro','message','Cadastro não sincronizado: '||row_error));
  skipped=skipped+1;
 end;
 end loop;
 for c in select * from public.customers where organization_id=run.organization_id and not(id=any(seen)) order by id for update loop
 if public.sheet_customer_has_issue(run.organization_id,c.id,c.phone) then continue;end if;
 if exists(select 1 from public.sheet_sync_state where customer_id=c.id) then
 insert into public.sheet_sync_conflicts(organization_id,customer_id,reason,database_value) values(run.organization_id,c.id,'missing_sheet_row',public.sync_customer_value(c.id)) on conflict do nothing;
 conflicts=conflicts||jsonb_build_array(jsonb_build_object('customer_id',c.id,'reason','Linha sincronizada removida da planilha; revisão necessária'));
 else
 -- With no usable identity, an invalid row may be the same unlinked contact.
 -- Defer only new exports until it can be identified; valid imports still proceed.
 if exists(select 1 from public.registration_issues ri where ri.organization_id=run.organization_id and ri.source='sheet' and ri.resolved_at is null and ri.customer_id is null and ri.sheet_phone is null and coalesce(ri.sheet_customer_id,'') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then continue;end if;
 writes=writes||jsonb_build_array(jsonb_build_object('customer_id',c.id,'expected',null,'original_id',null,'value',public.sync_customer_value(c.id),'version',c.version));
 end if;
 end loop;
 select coalesce(jsonb_agg(w),'[]'::jsonb) into writes from jsonb_array_elements(writes) w where not public.sheet_customer_has_issue(run.organization_id,(w->>'customer_id')::uuid,w->'value'->>'phone');
 update public.sheet_sync_runs set plan=jsonb_build_object('run_id',run_id,'writes',writes,'conflicts',conflicts,'skipped',skipped) where id=run_id;
 return jsonb_build_object('run_id',run_id,'writes',writes,'conflicts',conflicts,'skipped',skipped);
end; $$;
create or replace function public.sheet_sync_ack(run_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare run public.sheet_sync_runs; item jsonb;
begin
 select * into run from public.sheet_sync_runs where id=run_id for update;
 if not found then raise exception 'Execução desconhecida'; end if;
 if run.status='done' then return jsonb_build_object('status','done'); end if;
 if run.status<>'running' or run.expires_at<=now() or run.plan is null then raise exception 'Execução expirada ou não planejada'; end if;
 for item in select value from jsonb_array_elements(run.plan->'writes') loop
 insert into public.sheet_sync_state(organization_id,customer_id,base) values(run.organization_id,(item->>'customer_id')::uuid,item->'value')
 on conflict(organization_id,customer_id) do update set base=excluded.base,synced_at=now();
 update public.integration_jobs set status='done' where organization_id=run.organization_id and kind='customer.sync_to_sheet' and payload->'customer'->>'id'=item->>'customer_id' and (payload->'customer'->>'version')::bigint<=(item->>'version')::bigint;
 end loop;
 update public.sheet_sync_runs set status='done' where id=run_id;
 return jsonb_build_object('status','done','synced',jsonb_array_length(run.plan->'writes'),'conflicts',run.plan->'conflicts','skipped',coalesce((run.plan->>'skipped')::integer,0));
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
  if public.sheet_customer_has_issue(r.organization_id,c.id,c.phone) or public.sheet_customer_has_issue(r.organization_id,c.id,r.snapshot->>'phone') then
   errors=errors||jsonb_build_array(jsonb_build_object('field','Planilha','value',c.phone,'message','Este contato tem cadastro inválido em Pendências da planilha. Corrija antes de enviar.'));
  end if;
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

revoke all on function public.sheet_customer_has_issue(uuid,uuid,text),public.sheet_sync_record_issue(uuid,jsonb) from public,anon,authenticated;
-- Helpers are invoked only inside the private security-definer RPCs.
notify pgrst,'reload schema';
commit;

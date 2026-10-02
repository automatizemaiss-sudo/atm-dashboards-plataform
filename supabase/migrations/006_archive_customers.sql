begin;
alter table public.customers add column archived_at timestamptz;
create function public.set_customer_archived(customer uuid, archived boolean, expected_version bigint) returns void language plpgsql security invoker set search_path='' as $$
declare c public.customers;
begin
 select * into c from public.customers where id=customer for update;
 if not found or not public.is_member(c.organization_id) then raise exception 'Acesso negado'; end if;
 if c.version is distinct from expected_version then raise exception 'Cliente alterado. Atualize antes de excluir/restaurar.'; end if;
 update public.customers set archived_at=case when archived then now() else null end where id=c.id;
end; $$;
revoke all on function public.set_customer_archived(uuid,boolean,bigint) from public,anon;
grant execute on function public.set_customer_archived(uuid,boolean,bigint) to authenticated;
update public.sheet_sync_state set base=base||'{"archived":false}'::jsonb;
create or replace function public.list_customers(org uuid, query text default '', page_number integer default 0, page_size integer default 20, size_filter text default '', bought_filter text default '', marketing_filter text default '', sort_field text default 'created_at', ascending boolean default false) returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare rows jsonb; total bigint;
begin
 if not public.is_member(org) then raise exception 'Acesso negado'; end if;
 if page_number<0 or page_size<1 or page_size>100 then raise exception 'Paginação inválida'; end if;
 if sort_field not in ('name','created_at','last_purchase_at') then raise exception 'Ordenação inválida'; end if;
 with matches as (
 select c.* from public.customers c where c.organization_id=org and c.archived_at is null
 and (query='' or c.name ilike '%'||query||'%' or c.phone like '%'||nullif(regexp_replace(query,'[^0-9]','','g'),'')||'%')
 and(size_filter='' or c.size=size_filter)
 and(bought_filter='' or (bought_filter='true' and c.has_purchased=true) or (bought_filter='false' and c.has_purchased=false) or(bought_filter='unknown' and c.has_purchased is null))
 and(marketing_filter='' or(marketing_filter='true' and c.can_receive_campaigns is distinct from false) or(marketing_filter='false' and c.can_receive_campaigns=false))
 ), paged as (
 select * from matches order by
 case when ascending and sort_field='name' then name end asc,
 case when not ascending and sort_field='name' then name end desc,
 case when ascending and sort_field='created_at' then created_at end asc,
 case when not ascending and sort_field='created_at' then created_at end desc,
 case when ascending and sort_field='last_purchase_at' then last_purchase_at end asc nulls last,
 case when not ascending and sort_field='last_purchase_at' then last_purchase_at end desc nulls last,id
 limit page_size offset page_number*page_size
 ) select (select count(*) from matches),coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('customer_teams',coalesce((select jsonb_agg(jsonb_build_object('teams',jsonb_build_object('name',t.name))) from public.customer_teams ct join public.teams t on t.id=ct.team_id where ct.customer_id=p.id),'[]'::jsonb))) from paged p),'[]'::jsonb) into total,rows;
 return jsonb_build_object('total',total,'rows',rows);
end; $$;
create or replace function public.customer_summary(org uuid) returns jsonb language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('total',count(*),'buyers',count(*) filter(where has_purchased=true),'allowed',count(*) filter(where can_receive_campaigns is distinct from false),'unknown_purchase',count(*) filter(where has_purchased is null),
 'teams',coalesce((select jsonb_object_agg(name,n) from (select t.name,count(*) n from public.customer_teams ct join public.teams t on t.id=ct.team_id where ct.organization_id=org and exists(select 1 from public.customers c where c.id=ct.customer_id and c.archived_at is null) group by t.name) ranked),'{}'::jsonb),
 'sizes',coalesce((select jsonb_object_agg(size,n) from (select size,count(*) n from public.customers where organization_id=org and archived_at is null and size is not null group by size) ranked),'{}'::jsonb))
 from public.customers where organization_id=org and archived_at is null and public.is_member(org);
$$;
create function public.list_archived_customers(org uuid, page_number integer default 0) returns jsonb language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('total',(select count(*) from public.customers where organization_id=org and archived_at is not null),
 'rows',coalesce((select jsonb_agg(to_jsonb(c)) from (select * from public.customers where organization_id=org and archived_at is not null order by archived_at desc limit 20 offset greatest(page_number,0)*20)c),'[]'::jsonb)) where public.is_member(org);
$$;
revoke all on function public.list_archived_customers(uuid,integer) from public,anon;
grant execute on function public.list_archived_customers(uuid,integer) to authenticated;
create or replace function public.sync_customer_value(customer uuid) returns jsonb language sql stable set search_path='' as $$
 select jsonb_build_object('archived',c.archived_at is not null,'name',c.name,'phone',c.phone,'desired_shirt',c.desired_shirt,'size',c.size,'birthday',c.birthday,
 'has_purchased',c.has_purchased,'can_receive_campaigns',c.can_receive_campaigns,'has_referrals',c.has_referrals,
 'total_spent',c.total_spent,'order_count',c.order_count,'last_purchase_at',c.last_purchase_at,
 'teams',coalesce((select jsonb_agg(t.name order by t.name collate "C") from public.customer_teams ct join public.teams t on t.id=ct.team_id where ct.customer_id=c.id),'[]'::jsonb))
 from public.customers c where c.id=customer;
$$;
create or replace function public.sheet_sync_plan(run_id uuid, rows jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare run public.sheet_sync_runs; r jsonb; c public.customers; base jsonb; current_value jsonb; incoming jsonb; merged jsonb;
 field_name text; bad boolean; seen uuid[]='{}'; writes jsonb='[]'; conflicts jsonb='[]'; team_name text; team_id uuid;
begin
 select * into run from public.sheet_sync_runs where id=run_id and status='running' and expires_at>now() for update;
 if not found then raise exception 'Execução inválida ou expirada'; end if;
 if run.plan is not null then return run.plan; end if;
 if jsonb_typeof(rows)<>'array' or jsonb_array_length(rows)>9999 then raise exception 'Leitura inválida ou acima do limite'; end if;
 if exists(select 1 from jsonb_array_elements(rows) x group by x->'value'->>'phone' having count(*)>1) then raise exception 'Telefones duplicados na planilha'; end if;
 if exists(select 1 from jsonb_array_elements(rows) x where coalesce(x->>'customer_id','')<>'' group by x->>'customer_id' having count(*)>1) then raise exception 'UUIDs duplicados na planilha'; end if;
 perform set_config('futpb.sync_from_sheet','true',true);
 for r in select value from jsonb_array_elements(rows) loop
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
 update public.customers set name=merged->>'name',phone=merged->>'phone',desired_shirt=merged->>'desired_shirt',size=merged->>'size',birthday=(merged->>'birthday')::date,
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
 end loop;
 for c in select * from public.customers where organization_id=run.organization_id and not(id=any(seen)) order by id for update loop
 if exists(select 1 from public.sheet_sync_state where customer_id=c.id) then
 insert into public.sheet_sync_conflicts(organization_id,customer_id,reason,database_value) values(run.organization_id,c.id,'missing_sheet_row',public.sync_customer_value(c.id)) on conflict do nothing;
 conflicts=conflicts||jsonb_build_array(jsonb_build_object('customer_id',c.id,'reason','Linha sincronizada removida da planilha; revisão necessária'));
 else
 writes=writes||jsonb_build_array(jsonb_build_object('customer_id',c.id,'expected',null,'original_id',null,'value',public.sync_customer_value(c.id),'version',c.version));
 end if;
 end loop;
 update public.sheet_sync_runs set plan=jsonb_build_object('run_id',run_id,'writes',writes,'conflicts',conflicts) where id=run_id;
 return jsonb_build_object('run_id',run_id,'writes',writes,'conflicts',conflicts);
end; $$;
create or replace function public.create_campaign(org uuid, title text, segment uuid, instance uuid, content jsonb, schedule timestamptz default null) returns uuid language plpgsql security definer set search_path='' as $$
declare campaign uuid; rules jsonb; item jsonb; pos integer=0;
begin
 if not public.is_member(org) then raise exception 'Acesso negado'; end if;
 if length(trim(title))=0 then raise exception 'Nome obrigatório'; end if;
 select s.rules into rules from public.segments s where s.id=segment and s.organization_id=org;
 if rules is null then raise exception 'Segmento inválido'; end if;
 if not exists(select 1 from public.whatsapp_instances where id=instance and organization_id=org and enabled) then raise exception 'Instância ainda não habilitada'; end if;
 if content is null or jsonb_typeof(content)<>'array' or jsonb_array_length(content)=0 then raise exception 'Conteúdo obrigatório'; end if;
 if schedule is not null and schedule<=now() then raise exception 'Agendamento deve ser futuro'; end if;
 insert into public.campaigns(organization_id,name,segment_id,instance_id,status,scheduled_at,snapshot_at) values(org,title,segment,instance,case when schedule is null then 'processing' else 'scheduled' end,schedule,now()) returning id into campaign;
 for item in select value from jsonb_array_elements(content) loop
 if item->>'kind'<>'text' and (item->>'storage_path' is null or split_part(item->>'storage_path','/',1)<>org::text) then raise exception 'Mídia inválida'; end if;
 insert into public.campaign_messages(organization_id,campaign_id,position,kind,body,storage_path) values(org,campaign,pos,item->>'kind',item->>'body',item->>'storage_path'); pos=pos+1;
 end loop;
 insert into public.campaign_recipients(organization_id,campaign_id,customer_id,snapshot)
 select org,campaign,c.id,jsonb_build_object('name',c.name,'phone',c.phone) from public.customers c where c.organization_id=org and c.archived_at is null and c.can_receive_campaigns is distinct from false and public.matches_rules(c,rules);
 if not found then raise exception 'Nenhum destinatário elegível'; end if;
 insert into public.integration_jobs(organization_id,kind,payload) values(org,'campaign.start',jsonb_build_object('campaign_id',campaign,'scheduled_at',schedule));
 return campaign;
end; $$;
create or replace function public.claim_whatsapp_dispatch() returns jsonb language plpgsql security definer set search_path='' as $$
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
 where r.campaign_id=campaign.id and c.archived_at is null and c.can_receive_campaigns is distinct from false and exists(select 1 from public.campaign_messages m where m.campaign_id=campaign.id and not exists(select 1 from public.whatsapp_dispatches d where d.recipient_id=r.id and d.message_id=m.id)) order by r.id limit 1;
 if not found then update public.campaigns set status='completed' where id=campaign.id;return jsonb_build_object('available',false); end if;
 select m.* into msg from public.campaign_messages m where m.campaign_id=campaign.id and not exists(select 1 from public.whatsapp_dispatches d where d.recipient_id=recipient.id and d.message_id=m.id) order by m.position limit 1;
 insert into public.whatsapp_dispatches(organization_id,recipient_id,message_id,instance_id) values(campaign.organization_id,recipient.id,msg.id,campaign.instance_id) returning * into dispatch;
 return jsonb_build_object('available',true,'dispatch_id',dispatch.id,'instance_id',campaign.instance_id,'organization_id',campaign.organization_id,'number',regexp_replace(recipient.snapshot->>'phone','[^0-9]','','g'),'kind',msg.kind,'storage_path',msg.storage_path,'text',replace(coalesce(msg.body,''),'{{nome}}',split_part(recipient.snapshot->>'name',' ',1)));
end; $$;
create or replace function public.authorize_whatsapp_dispatch(dispatch_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.whatsapp_dispatches; allowed boolean;
begin
 select * into d from public.whatsapp_dispatches where id=dispatch_id for update;
 if not found or d.status<>'reserved' then raise exception 'Envio já autorizado ou desconhecido; não repetir'; end if;
 select ca.status='processing' and i.enabled and c.archived_at is null and c.can_receive_campaigns is distinct from false into allowed
 from public.campaign_recipients r join public.campaigns ca on ca.id=r.campaign_id join public.customers c on c.id=r.customer_id join public.whatsapp_instances i on i.id=ca.instance_id where r.id=d.recipient_id;
 update public.whatsapp_dispatches set status=case when allowed then 'sending' else 'skipped' end where id=d.id;
 return jsonb_build_object('allowed',coalesce(allowed,false));
end; $$;
create or replace function public.segment_count(segment uuid) returns bigint language sql stable security invoker set search_path='' as $$ select count(*) from public.customers c join public.segments s on s.organization_id=c.organization_id where s.id=segment and c.archived_at is null and public.matches_rules(c,s.rules); $$;
notify pgrst, 'reload schema';
commit;

begin;
create function public.matches_rules(c public.customers, r jsonb) returns boolean language plpgsql stable set search_path='' as $$
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
 if field_name='team' then
 if op<>'eq' then raise exception 'Operador de time inválido'; end if;
 return exists(select 1 from public.customer_teams ct join public.teams t on t.id=ct.team_id where ct.customer_id=c.id and t.name=r->>'value');
 end if;
 if field_name not in ('desired_shirt','size','birthday','birthday_month','has_purchased','has_referrals','can_receive_campaigns','total_spent','order_count','last_purchase_at','created_at') then raise exception 'Campo de segmento inválido'; end if;
 actual=case when field_name='birthday_month' then to_jsonb(extract(month from c.birthday)::integer) else to_jsonb(c)->field_name end;
 if field_name='can_receive_campaigns' and actual='null'::jsonb then actual='true'::jsonb; end if;
 if actual is null or actual='null'::jsonb then return false; end if;
 case op
 when 'eq' then return actual=r->'value';
 when 'gte' then return actual>=r->'value';
 when 'lte' then return actual<=r->'value';
 when 'contains' then return strpos(lower(actual #>> '{}'),lower(r->>'value'))>0;
 else raise exception 'Operador inválido'; end case;
end; $$;
create function public.segment_count(segment uuid) returns bigint language sql stable security invoker set search_path='' as $$ select count(*) from public.customers c join public.segments s on s.organization_id=c.organization_id where s.id=segment and public.matches_rules(c,s.rules); $$;
create function public.create_campaign(org uuid, title text, segment uuid, instance uuid, content jsonb, schedule timestamptz default null) returns uuid language plpgsql security definer set search_path='' as $$
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
 select org,campaign,c.id,jsonb_build_object('name',c.name,'phone',c.phone) from public.customers c where c.organization_id=org and c.can_receive_campaigns is distinct from false and public.matches_rules(c,rules);
 if not found then raise exception 'Nenhum destinatário elegível'; end if;
 insert into public.integration_jobs(organization_id,kind,payload) values(org,'campaign.start',jsonb_build_object('campaign_id',campaign,'scheduled_at',schedule));
 return campaign;
end; $$;
create function public.control_campaign(campaign uuid, command text) returns void language plpgsql security definer set search_path='' as $$ declare c public.campaigns; next_status text; begin
 select * into c from public.campaigns where id=campaign for update;
 if not found or not public.is_member(c.organization_id) then raise exception 'Acesso negado'; end if;
 if command='pause' and c.status in ('processing','scheduled') then next_status='paused';
 elsif command='resume' and c.status='paused' then next_status=case when c.scheduled_at>now() then 'scheduled' else 'processing' end;
 elsif command='cancel' and c.status in ('scheduled','processing','paused','error') then next_status='cancelled';
 else raise exception 'Transição inválida'; end if;
 update public.campaigns set status=next_status where id=campaign;
 insert into public.integration_jobs(organization_id,kind,payload) values(c.organization_id,'campaign.'||command,jsonb_build_object('campaign_id',campaign));
end; $$;
revoke all on function public.create_campaign(uuid,text,uuid,uuid,jsonb,timestamptz) from public,anon;
revoke all on function public.control_campaign(uuid,text) from public,anon;
grant execute on function public.create_campaign(uuid,text,uuid,uuid,jsonb,timestamptz) to authenticated;
grant execute on function public.control_campaign(uuid,text) to authenticated;
commit;

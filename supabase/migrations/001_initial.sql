begin;
create extension if not exists pgcrypto;
create table public.organizations (
 id uuid primary key default gen_random_uuid(), slug text not null unique, display_name text not null,
 logo_url text, favicon_url text, primary_color text not null default '#12432b', secondary_color text not null default '#000000', accent_color text not null default '#12432b', created_at timestamptz not null default now()
);
create table public.organization_users (organization_id uuid references public.organizations on delete cascade, user_id uuid references auth.users on delete cascade, primary key(organization_id,user_id));
create function public.is_member(org uuid) returns boolean language sql stable security definer set search_path='' as $$ select exists(select 1 from public.organization_users where organization_id=org and user_id=auth.uid()); $$;
create table public.customers (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations,
 name text not null check(length(trim(name))>0), phone text not null check(phone ~ '^\+55[0-9]{10,11}$'),
 desired_shirt text, size text, birthday date, has_purchased boolean, has_referrals boolean, can_receive_campaigns boolean,
 total_spent numeric(14,2) check(total_spent>=0), order_count integer check(order_count>=0), last_purchase_at date,
 sheet_row_id text, last_update_source text not null default 'dashboard' check(last_update_source in ('dashboard','google_sheets','whatsapp','system')),
 version bigint not null default 1, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 unique(organization_id,id), unique(organization_id,phone), unique(organization_id,sheet_row_id)
);
create table public.teams (id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations, name text not null, unique(organization_id,id), unique(organization_id,name));
create table public.customer_teams (organization_id uuid not null references public.organizations, customer_id uuid not null, team_id uuid not null, primary key(customer_id,team_id), foreign key(organization_id,customer_id) references public.customers(organization_id,id) on delete cascade, foreign key(organization_id,team_id) references public.teams(organization_id,id) on delete cascade);
create table public.segments (id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations, name text not null, rules jsonb not null default '{"operator":"and","conditions":[]}', created_at timestamptz not null default now(), unique(organization_id,id));
create table public.whatsapp_instances (id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations, name text not null, provider text not null default 'uazapi', enabled boolean not null default false, unique(organization_id,id));
create table public.campaigns (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations, name text not null,
 segment_id uuid, instance_id uuid, status text not null default 'draft' check(status in ('draft','scheduled','processing','completed','paused','cancelled','error')),
 scheduled_at timestamptz, snapshot_at timestamptz, created_at timestamptz not null default now(), unique(organization_id,id),
 foreign key(organization_id,segment_id) references public.segments(organization_id,id), foreign key(organization_id,instance_id) references public.whatsapp_instances(organization_id,id)
);
create table public.campaign_messages (id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations, campaign_id uuid not null, position integer not null default 0, kind text not null check(kind in ('text','image','video','audio')), body text, storage_path text, unique(campaign_id,position), unique(organization_id,id), foreign key(organization_id,campaign_id) references public.campaigns(organization_id,id) on delete cascade, check((kind='text' and length(trim(body))>0) or (kind<>'text' and storage_path is not null)));
create table public.campaign_recipients (id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations, campaign_id uuid not null, customer_id uuid not null, snapshot jsonb not null, sent_at timestamptz, delivered_at timestamptz, read_at timestamptz, replied_at timestamptz, error text, unique(campaign_id,customer_id), unique(organization_id,id), foreign key(organization_id,campaign_id) references public.campaigns(organization_id,id), foreign key(organization_id,customer_id) references public.customers(organization_id,id));
create table public.sales (id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations, customer_id uuid not null, campaign_id uuid, amount numeric(14,2) check(amount>=0), purchased_at timestamptz, external_id text, created_at timestamptz not null default now(), unique(organization_id,external_id), foreign key(organization_id,customer_id) references public.customers(organization_id,id), foreign key(organization_id,campaign_id) references public.campaigns(organization_id,id));
create table public.customer_events (id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations, customer_id uuid not null, event_type text not null, old_value jsonb, new_value jsonb, source text not null, user_id uuid, created_at timestamptz not null default now(), foreign key(organization_id,customer_id) references public.customers(organization_id,id));
create table public.integration_jobs (id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations, kind text not null, payload jsonb not null, status text not null default 'pending' check(status in ('pending','processing','done','error')), attempts integer not null default 0, created_at timestamptz not null default now());
create table public.integration_events (id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations, provider text not null, external_id text not null, payload jsonb not null, created_at timestamptz not null default now(), unique(organization_id,provider,external_id));
create function public.customer_version() returns trigger language plpgsql set search_path='' as $$ begin new.updated_at=now(); new.version=old.version+1; if auth.uid() is not null then new.last_update_source='dashboard'; end if; return new; end; $$;
-- The AFTER trigger records the persisted version, without changing it.
create function public.audit_customer() returns trigger language plpgsql security definer set search_path='' as $$ begin
 insert into public.customer_events(organization_id,customer_id,event_type,old_value,new_value,source,user_id) values(new.organization_id,new.id,lower(TG_OP),case when TG_OP='UPDATE' then to_jsonb(old) end,to_jsonb(new),case when auth.uid() is not null then 'dashboard' else new.last_update_source end,auth.uid());
 if auth.uid() is not null or new.last_update_source='dashboard' then insert into public.integration_jobs(organization_id,kind,payload) values(new.organization_id,'customer.sync_to_sheet',jsonb_build_object('customer',to_jsonb(new))); end if; return new;
end; $$;
create trigger customer_version before update on public.customers for each row execute function public.customer_version();
create trigger customer_audit after insert or update on public.customers for each row execute function public.audit_customer();
alter table public.organizations enable row level security;
create policy member_read on public.organizations for select to authenticated using(public.is_member(id));
alter table public.organization_users enable row level security;
create policy self_read on public.organization_users for select to authenticated using(user_id=auth.uid());
do $$ declare t text; begin
 foreach t in array array['customers','teams','customer_teams','segments','campaigns','campaign_messages','campaign_recipients','sales','customer_events','whatsapp_instances','integration_jobs','integration_events'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('create policy member_read on public.%I for select to authenticated using(public.is_member(organization_id))',t);
 if t in ('customers','teams','customer_teams','segments','sales') then
 execute format('create policy member_insert on public.%I for insert to authenticated with check(public.is_member(organization_id))',t);
 execute format('create policy member_update on public.%I for update to authenticated using(public.is_member(organization_id)) with check(public.is_member(organization_id))',t);
 end if;
 if t in ('customer_teams','segments') then execute format('create policy member_delete on public.%I for delete to authenticated using(public.is_member(organization_id))',t); end if;
 end loop;
end $$;
-- Campaigns and their delivery records are only written through trusted functions/workers.
create index customers_org_created on public.customers(organization_id,created_at desc);
create index customer_events_customer on public.customer_events(customer_id,created_at desc);
create index campaigns_org on public.campaigns(organization_id,created_at desc);
create index jobs_pending on public.integration_jobs(status,created_at);
insert into public.organizations(slug,display_name,logo_url,favicon_url) values('futpb','FUTPB','/futpb-logo.png','/futpb-logo.png');
insert into public.whatsapp_instances(organization_id,name) select id,'WhatsApp FUTPB' from public.organizations where slug='futpb';
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('campaign-media','campaign-media',false,26214400,array['image/jpeg','image/png','image/webp','video/mp4','audio/mpeg','audio/ogg','audio/mp4']);
create policy media_read on storage.objects for select to authenticated using(bucket_id='campaign-media' and public.is_member(case when (storage.foldername(name))[1] ~ '^[0-9a-f-]{36}$' then ((storage.foldername(name))[1])::uuid else null end));
create policy media_insert on storage.objects for insert to authenticated with check(bucket_id='campaign-media' and public.is_member(case when (storage.foldername(name))[1] ~ '^[0-9a-f-]{36}$' then ((storage.foldername(name))[1])::uuid else null end));
commit;

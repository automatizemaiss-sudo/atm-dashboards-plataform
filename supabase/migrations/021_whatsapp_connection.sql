begin;
create table public.whatsapp_connection_status (
 instance_id uuid primary key references public.whatsapp_instances(id) on delete cascade,
 status text not null check(status in ('connected','disconnected','connecting','hibernated')),
 checked_at timestamptz not null default now()
);
alter table public.whatsapp_connection_status enable row level security;
create policy connection_read on public.whatsapp_connection_status for select to authenticated using (
 exists(select 1 from public.whatsapp_instances wi where wi.id=instance_id and public.is_member(wi.organization_id))
);
grant select on public.whatsapp_connection_status to authenticated;
create function public.record_whatsapp_connection(instance uuid, connection_status text) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 insert into public.whatsapp_connection_status(instance_id,status) values(instance,connection_status)
 on conflict(instance_id) do update set status=excluded.status,checked_at=now();
 return jsonb_build_object('recorded',true);
end; $$;
revoke all on function public.record_whatsapp_connection(uuid,text) from public,anon,authenticated;
grant execute on function public.record_whatsapp_connection(uuid,text) to service_role;
commit;

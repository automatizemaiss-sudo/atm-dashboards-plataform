begin;

alter table public.campaign_messages add column revision integer not null default 1;

create table public.campaign_message_versions (
  message_id uuid not null references public.campaign_messages(id) on delete cascade,
  revision integer not null,
  body text,
  created_at timestamptz not null default now(),
  created_by uuid,
  primary key (message_id, revision)
);

alter table public.campaign_message_versions enable row level security;
revoke all on public.campaign_message_versions from public, anon, authenticated;
grant select on public.campaign_message_versions to authenticated;
create policy member_read on public.campaign_message_versions for select to authenticated
  using (exists (
    select 1 from public.campaign_messages m
    where m.id = message_id and public.is_member(m.organization_id)
  ));

insert into public.campaign_message_versions (message_id, revision, body, created_at)
select m.id, m.revision, m.body, c.created_at
from public.campaign_messages m join public.campaigns c on c.id = m.campaign_id;

create function public.record_campaign_message_version() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.campaign_message_versions (message_id, revision, body, created_by)
  values (new.id, new.revision, new.body, auth.uid());
  return new;
end;
$$;

create trigger record_campaign_message_version
after insert or update of revision on public.campaign_messages
for each row execute function public.record_campaign_message_version();

alter table public.whatsapp_dispatches add column message_revision integer not null default 1;
alter table public.whatsapp_dispatches add constraint dispatch_message_version
  foreign key (message_id, message_revision)
  references public.campaign_message_versions (message_id, revision);
alter table public.whatsapp_dispatches alter column message_revision drop default;
create index dispatch_message_history on public.whatsapp_dispatches (message_id, message_revision, created_at desc, id desc)
  where status in ('sending', 'accepted', 'unknown');

-- The worker holds the campaign lock when it reads the message and reserves the dispatch.
-- Capture the version in that transaction, before the worker waits for its send slot.
create function public.pin_dispatch_message_version() returns trigger
language plpgsql set search_path = '' as $$
begin
  select m.revision into new.message_revision
  from public.campaign_messages m where m.id = new.message_id;
  return new;
end;
$$;

create trigger pin_dispatch_message_version before insert on public.whatsapp_dispatches
for each row execute function public.pin_dispatch_message_version();

create function public.edit_campaign_message(message uuid, expected_revision integer, new_body text)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  campaign public.campaigns;
  current_message public.campaign_messages;
begin
  select c.* into campaign
  from public.campaigns c join public.campaign_messages m on m.campaign_id = c.id
  where m.id = message for update of c;

  if not found or not public.is_member(campaign.organization_id) then
    raise exception 'Acesso negado';
  end if;
  if campaign.archived_at is not null or campaign.status <> 'paused' then
    raise exception 'Pause a campanha para editar a mensagem.';
  end if;

  select * into current_message from public.campaign_messages where id = message;
  if current_message.revision is distinct from expected_revision then
    raise exception 'A mensagem foi alterada. Reabra o histórico para carregar a versão atual.';
  end if;
  if current_message.kind = 'text' and (new_body is null or new_body !~ '[^[:space:]]') then
    raise exception 'Preencha o texto da mensagem.';
  end if;
  if coalesce(current_message.body, '') = coalesce(new_body, '') then
    return current_message.revision;
  end if;

  update public.campaign_messages
  set body = new_body, revision = current_message.revision + 1
  where id = message;
  return current_message.revision + 1;
end;
$$;

create function public.campaign_message_history(campaign uuid)
returns table (
  message_id uuid, message_position integer, kind text, revision integer, is_current boolean,
  body text, created_at timestamptz, sent bigint, delivered bigint, read bigint, attempts bigint
)
language sql stable set search_path = '' as $$
  select m.id, m.position, m.kind, v.revision, v.revision = m.revision, v.body, v.created_at,
    totals.sent, totals.delivered, totals.read, totals.attempts
  from public.campaign_messages m
  join public.campaign_message_versions v on v.message_id = m.id
  cross join lateral (
    select count(d.sent_at) as sent, count(d.delivered_at) as delivered,
      count(d.read_at) as read, count(*) as attempts
    from public.whatsapp_dispatches d
    where d.message_id = m.id and d.message_revision = v.revision
      and d.status in ('sending', 'accepted', 'unknown')
  ) totals
  where m.campaign_id = campaign
  order by m.position, v.revision desc;
$$;

create function public.campaign_message_recipients(message uuid, version_number integer, page_number integer)
returns table (dispatch_id uuid, contact_name text, phone text, status text, sent_at timestamptz, delivered_at timestamptz, read_at timestamptz)
language sql stable set search_path = '' as $$
  select d.id, r.snapshot->>'name', r.snapshot->>'phone', d.status, d.sent_at, d.delivered_at, d.read_at
  from public.whatsapp_dispatches d
  join public.campaign_recipients r on r.id = d.recipient_id
  where d.message_id = message and d.message_revision = version_number
    and d.status in ('sending', 'accepted', 'unknown')
  order by d.created_at desc, d.id desc
  limit 21 offset (greatest(page_number, 0)::bigint * 20);
$$;

revoke all on function public.edit_campaign_message(uuid, integer, text),
  public.campaign_message_history(uuid), public.campaign_message_recipients(uuid, integer, integer)
  from public, anon;
grant execute on function public.edit_campaign_message(uuid, integer, text),
  public.campaign_message_history(uuid), public.campaign_message_recipients(uuid, integer, integer)
  to authenticated;

notify pgrst, 'reload schema';
commit;

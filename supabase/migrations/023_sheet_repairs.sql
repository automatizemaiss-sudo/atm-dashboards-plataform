begin;

alter table public.registration_issues add column sheet_cells jsonb;

create table public.sheet_repairs (
 issue_id uuid primary key references public.registration_issues(id),
 organization_id uuid not null references public.organizations(id),
 row_number integer not null check(row_number between 2 and 10000),
 expected jsonb not null,
 changes jsonb not null,
 discard boolean not null default false,
 status text not null default 'pending' check(status in ('pending','applied','rejected')),
 message text,
 requested_by uuid not null,
 requested_at timestamptz not null default now()
);
create unique index sheet_repairs_pending_row on public.sheet_repairs(organization_id,row_number) where status='pending';
alter table public.sheet_repairs enable row level security;
revoke all on public.sheet_repairs from anon,authenticated;
grant select on public.sheet_repairs to authenticated;
create policy member_read on public.sheet_repairs for select to authenticated using(public.is_member(organization_id));

create function public.request_sheet_repair(issue uuid, expected jsonb, changes jsonb, discard boolean default false)
returns void language plpgsql security definer set search_path='' as $$
declare item public.registration_issues; cell record;
begin
 select * into item from public.registration_issues where id=issue for update;
 if not found or not public.is_member(item.organization_id) then raise exception 'Acesso negado'; end if;
 if item.source<>'sheet' or item.resolved_at is not null or item.sheet_cells is null or item.sheet_cells is distinct from expected then
  raise exception 'A linha mudou ou ainda está sendo sincronizada. Atualize as pendências e tente novamente.';
 end if;
 if jsonb_typeof(changes) is distinct from 'object' then raise exception 'Alterações inválidas.'; end if;
 if discard then
  if changes<>'{}'::jsonb or item.message !~* 'duplicad|^Duas linhas correspondem' then raise exception 'Só é possível descartar uma linha identificada como duplicada.'; end if;
 elsif changes='{}'::jsonb then
  raise exception 'Altere pelo menos um campo.';
 end if;
 for cell in select * from jsonb_each(changes) loop
  if cell.key !~ '^(0|1|2|3|4|5|6|7|8|10|11|12|13|15)$' or jsonb_typeof(cell.value)<>'string'
     or length(cell.value #>> '{}')>5000 or (cell.key='8' and cell.value<>'""'::jsonb) then
   raise exception 'Campo ou valor inválido.';
  end if;
 end loop;
 insert into public.sheet_repairs as repair(issue_id,organization_id,row_number,expected,changes,discard,requested_by)
 values(item.id,item.organization_id,item.row_number,expected,changes,discard,auth.uid())
 on conflict(issue_id) do update set row_number=excluded.row_number,expected=excluded.expected,changes=excluded.changes,
 discard=excluded.discard,status='pending',message=null,requested_by=excluded.requested_by,requested_at=now()
 where repair.status<>'pending';
 if not found then raise exception 'Já existe uma correção aguardando sincronização.'; end if;
 exception when unique_violation then raise exception 'Já existe uma correção aguardando sincronização para esta linha.';
end; $$;

-- Capture the exact cells seen by the same read that produced each issue.
alter function public.sheet_sync_plan(uuid,jsonb) rename to sheet_sync_plan_without_repair_snapshots;
revoke all on function public.sheet_sync_plan_without_repair_snapshots(uuid,jsonb) from public,anon,authenticated,service_role;
create function public.sheet_sync_plan(run_id uuid, rows jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; run public.sheet_sync_runs;
begin
 result=public.sheet_sync_plan_without_repair_snapshots(run_id,rows);
 select * into run from public.sheet_sync_runs where id=run_id;
 with snapshots as (
  select (entry->>'row_number')::integer as row_number,entry->'cells' as cells
  from jsonb_array_elements(rows || coalesce(run.validation_issues,'[]'::jsonb)) entry
 )
 update public.registration_issues ri set sheet_cells=s.cells
 from snapshots s where ri.organization_id=run.organization_id and ri.source='sheet'
 and ri.resolved_at is null and ri.row_number=s.row_number
 and ri.sheet_cells is distinct from s.cells;
 return result;
end; $$;

create function public.sheet_sync_validate_repair(run_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.sheet_sync_runs where id=run_id and status='running'
  and expires_at>now()+interval '1 minute' and plan is null) then
  raise exception 'Reserva expirada ou já reconciliada.';
 end if;
 return jsonb_build_object('run_id',run_id);
end; $$;

create function public.sheet_sync_pending_repairs(run_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare run public.sheet_sync_runs;
begin
 select * into run from public.sheet_sync_runs where id=run_id and status='running' and expires_at>now() and plan is null;
 if not found then raise exception 'Reserva de sincronização inválida.'; end if;
 return jsonb_build_object('repairs',coalesce((select jsonb_agg(to_jsonb(p) order by p.requested_at) from (
  select p.issue_id,p.row_number,p.expected,p.changes,p.discard,p.requested_at,c.id as matched_id,c.phone as matched_phone
  from public.sheet_repairs p
  join public.registration_issues ri on ri.id=p.issue_id
  left join public.customers c on c.id=ri.customer_id and c.organization_id=p.organization_id
  where p.organization_id=run.organization_id and p.status='pending' order by p.requested_at limit 10
 ) p),'[]'::jsonb));
end; $$;

create function public.sheet_sync_finish_repairs(run_id uuid, results jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare run public.sheet_sync_runs;
begin
 select * into run from public.sheet_sync_runs where id=run_id and status='running' and expires_at>now() and plan is null for update;
 if not found then raise exception 'Reserva de sincronização inválida.'; end if;
 update public.sheet_repairs p set status=r.status,message=r.message
 from jsonb_to_recordset(results) r(issue_id uuid,status text,message text)
 where p.issue_id=r.issue_id and p.organization_id=run.organization_id and p.status='pending' and r.status in ('applied','rejected');
 return jsonb_build_object('run_id',run.id);
end; $$;

revoke all on function public.request_sheet_repair(uuid,jsonb,jsonb,boolean), public.sheet_sync_plan(uuid,jsonb),
 public.sheet_sync_validate_repair(uuid), public.sheet_sync_pending_repairs(uuid), public.sheet_sync_finish_repairs(uuid,jsonb) from public,anon,authenticated;
grant execute on function public.request_sheet_repair(uuid,jsonb,jsonb,boolean) to authenticated;
grant execute on function public.sheet_sync_plan(uuid,jsonb), public.sheet_sync_validate_repair(uuid), public.sheet_sync_pending_repairs(uuid),
 public.sheet_sync_finish_repairs(uuid,jsonb) to service_role;
notify pgrst,'reload schema';
commit;

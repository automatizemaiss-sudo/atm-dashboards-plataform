begin;
create table public.registration_submissions(
 id uuid primary key,organization_id uuid not null references public.organizations,
 customer_id uuid references public.customers,profile jsonb not null,
 status text not null check(status in('created','review')),
 fingerprint text not null,created_at timestamptz not null default now()
);
create index registration_rate_ip on public.registration_submissions(fingerprint,created_at);
create index registration_rate_phone on public.registration_submissions((profile->>'phone'),created_at);
alter table public.registration_submissions enable row level security;
create policy owner_read on public.registration_submissions for select to authenticated using(public.is_member(organization_id));
create function public.submit_registration(data jsonb,fingerprint text) returns jsonb language plpgsql security definer set search_path='' as $$
declare org uuid;cid uuid;sid uuid=(data->>'submission_id')::uuid;team text;tid uuid;state text='review';
begin
 select id into org from public.organizations where slug='futpb';if org is null then raise exception 'Organização indisponível';end if;
 perform pg_advisory_xact_lock(hashtextextended('form-ip-'||fingerprint,0));
 perform pg_advisory_xact_lock(hashtextextended('form-phone-'||(data->>'phone'),0));
 if exists(select 1 from public.registration_submissions where id=sid) then return jsonb_build_object('accepted',true);end if;
 if (select count(*) from public.registration_submissions s where s.fingerprint=submit_registration.fingerprint and s.created_at>now()-interval '15 minutes')>=5 or (select count(*) from public.registration_submissions where profile->>'phone'=data->>'phone' and created_at>now()-interval '1 day')>=3 then raise exception 'FORM_RATE_LIMIT';end if;
 select id into cid from public.customers where organization_id=org and phone=data->>'phone' for update;
 if cid is null then
 insert into public.customers(organization_id,name,phone,desired_shirt,size,birthday,has_purchased,has_referrals,can_receive_campaigns,last_update_source)
 values(org,data->>'name',data->>'phone',data->>'desired_shirt',data->>'size',(data->>'birthday')::date,(data->>'has_purchased')::boolean,(data->>'has_referrals')::boolean,(data->>'can_receive_campaigns')::boolean,'system')
 on conflict(organization_id,phone) do nothing returning id into cid;
 if cid is not null then
 state='created';
 for team in select jsonb_array_elements_text(data->'teams') loop
 insert into public.teams(organization_id,name) values(org,team) on conflict(organization_id,name) do update set name=excluded.name returning id into tid;
 insert into public.customer_teams(organization_id,customer_id,team_id) values(org,cid,tid) on conflict do nothing;
 end loop;
 else select id into cid from public.customers where organization_id=org and phone=data->>'phone';end if;
 end if;
 insert into public.registration_submissions(id,organization_id,customer_id,profile,status,fingerprint) values(sid,org,cid,data-'submission_id',state,fingerprint);
 return jsonb_build_object('accepted',true);
end; $$;
revoke all on function public.submit_registration(jsonb,text) from public,anon,authenticated;
grant execute on function public.submit_registration(jsonb,text) to service_role;
notify pgrst,'reload schema';
commit;

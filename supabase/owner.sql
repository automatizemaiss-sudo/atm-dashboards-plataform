-- Execute DEPOIS de criar o usuário em Authentication > Users > Add user.
-- Substitua somente o e-mail abaixo pelo e-mail real do dono.
insert into public.organization_users(organization_id,user_id)
select o.id,u.id from public.organizations o cross join auth.users u
where o.slug='futpb' and lower(u.email)=lower('nicolas.vitor.dos.santos.maia@academico.ufpb.br')
on conflict do nothing;
-- Deve retornar exatamente uma associação para o dono:
select u.email,o.display_name from public.organization_users m
join auth.users u on u.id=m.user_id join public.organizations o on o.id=m.organization_id;

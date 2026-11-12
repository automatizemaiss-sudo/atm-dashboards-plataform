begin;
alter table public.customers drop constraint valid_shirt_types;
alter table public.customers add constraint valid_shirt_types
 check (shirt_types <@ array['Jogador','Torcedor','Retrô','Feminina','NBA','Infantil']::text[]);
notify pgrst,'reload schema';
commit;

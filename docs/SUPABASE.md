# Configuração FUTPB

Projeto: https://wlhugaduwhevmoymyhad.supabase.co

1. No SQL Editor, execute uma vez `supabase/migrations/001_initial.sql` e depois `002_campaign_functions.sql`. São migrations para um projeto novo; não são scripts para repetir.
2. Em Authentication > Users, crie o usuário do dono com e-mail e senha. Desative cadastro público nas configurações de Auth. O dashboard não oferece cadastro.
3. Edite o e-mail em `supabase/owner.sql` e execute esse arquivo. Confirme a associação retornada.
4. Em Settings/API Keys, obtenha a chave pública publishable (ou anon legada). Copie `.env.example` para `.env.local` e preencha `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`. A URL já está configurada no exemplo. Nunca coloque service_role no frontend.
5. Rode `npm install` e `npm run dev`. Faça login com o usuário criado.
6. No n8n, configure a credencial privada Supabase apenas no servidor. O dashboard não precisa dessa chave.
7. Habilite a instância em `whatsapp_instances` somente após integrar e testar o worker do n8n. Até lá, o banco bloqueia iniciar campanhas.

Não é necessário importar a pasta dist nem o protótipo para o Supabase. A migration cria o bucket privado campaign-media. O limite de 25 MiB é uma escolha inicial da aplicação, não um limite confirmado da Uazapi. Objetos usam `organization_id/uuid.ext`.

A primeira versão exige atualização manual das listas, sem Realtime. Dados reais e regras de acesso dependem da execução dos scripts e da chave pública. As migrations passaram em PostgreSQL local em memória (com auth/storage simulados), mas precisam ser validadas no projeto antes do uso operacional.

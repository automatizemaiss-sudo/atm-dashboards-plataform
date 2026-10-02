# Dashboard FUTPB

Aplicação inicial em Next.js + TypeScript, com Supabase como única interface de dados do frontend. A referência visual é o protótipo FUTPB, sem copiar suas credenciais, contatos de teste ou integração direta com Uazapi/Sheets.

## Preparar

Siga `docs/SUPABASE.md`. Execute as duas migrations em ordem e associe o dono com `supabase/owner.sql`. Configure `.env.local` a partir de `.env.example`.

```sh
npm install
npm run dev
npm run typecheck
npm test
npm run build
```

Não há cadastro público nem modo demonstrativo gravando clientes fictícios. Sem a chave pública, a tela explica a configuração pendente. A instância WhatsApp é criada desabilitada.

## Publicação

Conectar este repositório ao projeto Vercel, preset Next.js, e cadastrar NEXT_PUBLIC_SUPABASE_URL e NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY. Configurar as URLs de Auth no Supabase quando houver domínio. Não publicar service_role ou credenciais do n8n/Uazapi.

## Estado

Entrega inicial: login, organização, leitura de indicadores, clientes editáveis, segmentos de uma condição com cálculo SQL, duplicação/exclusão, campanhas em três etapas, mídia privada e comandos na fila. A evolução e os limites estão em `docs/INTEGRACOES.md`. Não representa o MVP completo e ainda exige validação no Supabase real.

## Atualização de Clientes, Segmentos e campanhas

Siga docs/ATUALIZACAO.md para migrations 004–006 e a coluna O Excluído?. Fluxos Uazapi ficam desativados até a configuração real; consulte docs/CAMPANHAS-UAZAPI.md.

# Atualização de contatos e segmentações

1. Pause o fluxo de sincronização do n8n e aguarde a execução atual terminar.
2. No SQL Editor do Supabase, execute `supabase/migrations/007_contact_interests.sql` uma vez. As migrações anteriores devem estar instaladas.
3. Na Página1, adicione **P1: Tipos de camisa**, mantendo A:O como estão. Valores: `Jogador; Torcedor; Retrô`; pode deixar vazio ou escolher vários separados por ponto e vírgula.
4. Importe novamente `integrations/n8n/02-sincronizacao-bidirecional.json`, selecione as mesmas credenciais e teste manualmente antes de ativar. Desative o fluxo antigo para evitar duas sincronizações.
5. Publique o código atualizado na Vercel.

Contatos e Segmentações compartilham filtros e seleção. Os filtros salvos criam públicos dinâmicos; “Criar campanha” com contatos marcados salva uma seleção manual por ID, que mantém esses contatos mesmo se seus interesses mudarem. Arquivados e recusas continuam excluídos dos envios. A seleção permanece entre páginas e é limpa ao alterar filtros. O botão “Ver público” carrega os critérios do cartão na lista.

Tipos de camisa podem ser editados no dashboard ou na planilha. A sincronização usa a mesma comparação de alterações e detecção de conflitos dos outros campos. Os filtros incluem time (nome exato), tipo de camisa, tamanho, compra, permissão, mês de aniversário, indicações e período da última compra; o editor de segmento também oferece regras combinadas por valor gasto, pedidos e data de cadastro.

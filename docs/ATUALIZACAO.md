# Atualização após a sincronização inicial

1. Pause o workflow de sincronização no n8n e aguarde terminar qualquer execução.
2. No Supabase SQL Editor, execute uma vez `supabase/atualizacao-clientes-campanhas.sql` (inclui 004–006 numa transação). Alternativamente, execute os arquivos separados nesta ordem, sem depois repetir o combinado:
   - supabase/migrations/004_customer_tools.sql
   - supabase/migrations/005_campaign_worker.sql
   - supabase/migrations/006_archive_customers.sql
3. Na planilha Página1, mantenha A:N e adicione **O1 = Excluído?**. Deixe as células O2:O vazias inicialmente. ID Cliente e Versão Sync continuam intocáveis.
4. Importe novamente integrations/n8n/02-sincronizacao-bidirecional.json e selecione as credenciais. Esta versão lê A:O e sincroniza a exclusão. Desative o workflow anterior, não mantenha dois workflows ativos.
5. Execute manualmente uma vez. Confira Confirmar sincronização. Só então reative o automático.
6. Atualize o dashboard. Em Clientes, use Excluir na coluna Ações. Ver clientes excluídos mostra os arquivados e permite Restaurar.
7. Após a sincronização, O deve ficar Sim para clientes excluídos. Trocar O para Não na planilha restaura pelo fluxo. Não remova a linha para excluir: isso ainda é tratado como conflito de linha ausente, preservando o banco.

Não há exclusão física nesta operação. Campanhas, compras, auditoria, UUID e telefone são preservados. Um cliente excluído fica fora da lista ativa, KPIs da base e novos snapshots/autorização de envios. Uma mensagem já aceita pelo provedor não pode ser recolhida pela exclusão. A restauração reutiliza o mesmo registro.

Novas telas: filtros por tamanho/compras/aceite, ordenação e paginação no banco, edição de múltiplos times, histórico recente, segmentos com grupos AND/OR e edição/duplicação/exclusão. Ainda há evolução necessária para filtros adicionais, detalhes completos e vendas atribuídas.

Preparação de campanhas desativadas: docs/CAMPANHAS-UAZAPI.md.

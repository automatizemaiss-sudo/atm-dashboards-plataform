# Retornos de clientes

Aplique `supabase/migrations/014_customer_returns.sql` no SQL Editor do Supabase após as migrações anteriores, depois aplique `supabase/migrations/015_customer_return_time.sql` e publique o frontend atualizado. A migração mantém os retornos existentes vazios; nenhum envio é criado para contatos sem agendamento.

Em Contatos → Novo contato / Editar contato, escolha a data de retorno. Para envio automático, marque a opção, defina o horário obrigatório em Brasília, selecione uma instância habilitada e informe a mensagem (`{{nome}}` é substituído pelo primeiro nome). O envio fica disponível a partir da data e do horário definidos em America/Sao_Paulo; o horário efetivo depende da fila e do n8n.

A Visão Geral mostra contagens e listas paginadas de retornos manuais e automáticos vencendo hoje, incluindo pendências anteriores. Os indicadores consultam toda a base ativa, independentemente dos filtros de Contatos, e atualizam a cada minuto. Envios aceitos pelo provedor saem da lista de pendências automáticas. Pausas e erros aparecem na situação do retorno.

Após chamar manualmente, abra Editar retorno, use Remover / concluir retorno e salve, ou escolha a próxima data. Alterar ou remover o agendamento cancela a campanha anterior e as reservas ainda não autorizadas. Um envio em andamento ou com resultado incerto precisa ser conferido antes de reagendar, evitando duplicidade.

O automático usa as campanhas e o workflow existente `integrations/n8n/03-processar-campanhas.json`, que precisa estar configurado e ativo. Não exige novo workflow nem credenciais no frontend. Contatos arquivados ou com campanhas bloqueadas não são enviados. O histórico fica nas campanhas e nos eventos do contato. Os campos de retorno são geridos pelo dashboard; não foram adicionadas colunas à sincronização da planilha.

A migração 015 preserva o horário de agendamentos automáticos anteriores (00:00 quando não havia campanha vinculada). Novos retornos automáticos exigem horário explícito. Alterar o horário cancela a campanha anterior e cria uma nova com o instante atualizado.

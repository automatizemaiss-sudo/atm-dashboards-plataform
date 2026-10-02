# Contrato inicial do n8n

O frontend lê e grava somente no Supabase com a sessão do dono e RLS. O n8n usa credenciais privadas e valida a organização em todas as operações.

## Planilha ↔ Supabase

- Persistir o UUID do cliente numa coluna estável da planilha. `sheet_row_id` é uma chave estável, não o número da posição da linha, que muda ao ordenar.
- Normalizar telefone para +55DDDNUMERO antes de escrever; deduplicar dentro da organização.
- Planilha → banco: marcar `last_update_source=google_sheets`. O trigger audita e não gera tarefa de retorno à planilha.
- Dashboard → banco: o trigger cria `customer.sync_to_sheet` em integration_jobs. O worker aplica apenas a versão mais recente e registra confirmação para que sua própria gravação não retorne como nova alteração.
- Atualizar usando a versão esperada; se houve alteração concorrente, comparar por campo e encaminhar conflito para revisão. Não sobrescrever silenciosamente.
- As relações customer_teams também precisam de sincronização. A primeira migration ainda não gera jobs para alterações de times.
- Não apagar clientes quando uma linha sumir: confirmar o processo de exclusão com o dono.

## Campanhas

- `create_campaign` cria campanha, conteúdos, snapshot dos clientes elegíveis e job `campaign.start` em uma transação.
- Instância inicia desabilitada. Somente habilitar após validar o worker.
- Consumir jobs com reserva atômica/lock e identificador idempotente. O worker e sua função de claim ainda precisam ser implementados; não usar somente uma leitura seguida de update sem proteção contra concorrência.
- Respeitar scheduled_at e o status atual antes de cada envio. Reconsultar `can_receive_campaigns`; false bloqueia mesmo se o cliente estava no snapshot.
- Consultar campaign_messages por position; resolver {{nome}} a partir do snapshot. Baixar mídia privada com URL assinada de curta duração.
- Guardar o identificador de mensagem do provedor e correlacionar com destinatário/conteúdo. A tabela detalhada de mensagens do provedor será definida junto ao webhook real.
- Retornos devem ser autenticados, deduplicados em integration_events por provider/external_id e aplicados de forma monotônica. Guardar sent_at, delivered_at, read_at, replied_at por destinatário. Não apagar datas anteriores quando eventos chegarem fora de ordem.
- campaign.pause/resume/cancel são comandos de integração. Alterar o status no banco não garante que uma fila já iniciada na Uazapi parou: o worker precisa aplicar e confirmar o comando no provedor.
- Vendas: sales permite campanha opcional, valor opcional e data opcional; confirmar atribuição e cadastro com o dono. Não inferir conversão só porque has_purchased=true.

## Segredos externos

No n8n: URL/chave privada Supabase, URL/token Uazapi, credencial Google Sheets e segredo de validação dos webhooks. Nenhum desses valores pertence às variáveis NEXT_PUBLIC.

## Limites desta entrega inicial

Sem worker n8n, envio real, Realtime, garantia completa de idempotência do provedor ou sincronização real. A lista de clientes usa o limite padrão do PostgREST e paginação visual de 20 itens; implementar consultas e paginação no servidor antes de importar uma base grande. Faltam editor visual AND/OR, edição de segmentos, gerenciamento de times no formulário, detalhe/auditoria do cliente e campanha, preview real da mídia e processo de vendas.

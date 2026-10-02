# Preparação de campanhas — Uazapi

Contrato consultado: https://docs.uazapi.com/ (API 2.4.3, 02/10/2026). Arquivos de workflow vêm inativos; guard enabled=false bloqueia até mesmo reservar uma mensagem.

## Banco

Execute 004_customer_tools.sql, 005_campaign_worker.sql e 006_archive_customers.sql em ordem. Não repetir migrations anteriores. Depois, configure a sincronização conforme docs/ATUALIZACAO.md.

## Amanhã, com a instância

1. Obter Server URL HTTPS real e token da instância. Não usar admintoken para envio.
2. Criar no n8n uma credencial **Header Auth**, Name `token`, Value token da instância; selecionar no nó Enviar Uazapi. Não colar o token no JSON.
3. Importar 03-processar-campanhas.json. Selecionar Supabase API nos nós Reservar mensagem, Revalidar permissão e campanha, Registrar retorno da API e Assinar mídia privada.
4. No nó Configuração, preencher apiUrl com Server URL real. Manter enabled=false até revisão e teste restrito ao dono.
5. Importar 04-retornos-uazapi.json e selecionar Supabase API no nó Validar e registrar evento.
6. Registrar no banco o hash SHA-256 do token real da instância em whatsapp_webhook_keys. Exemplo abaixo usa placeholder, nunca executar sem substituir corretamente. A tabela é privada, sem leitura pelo dono ou frontend.

```sql
insert into public.whatsapp_webhook_keys(instance_id,token_hash)
select id, encode(sha256(convert_to('SUBSTITUA_PELO_TOKEN_REAL','UTF8')),'hex')
from public.whatsapp_instances
where organization_id=(select id from public.organizations where slug='futpb')
on conflict(instance_id) do update set token_hash=excluded.token_hash;
```

7. Testar o webhook e então ativar apenas o receptor. Configurar `/webhook` da Uazapi com a URL Production exibida pelo n8n, `events=["messages","messages_update"]`, `excludeMessages=[]`, `addUrlEvents=false`, `addUrlTypesMessages=false`. Não inventar URL; usar a exibida pelo n8n. Não excluir eventos de mensagens enviadas pela API, pois são necessários para rastreamento. Preservar destinos já existentes.
8. Habilitar a instância em whatsapp_instances somente após testar autenticação, URL, permissões e retornos. Criar segmento contendo somente o dono, revisar uma campanha de texto, habilitar o guard para esse teste e executar manualmente. Conferir recebimento e estados, não apenas HTTP 200. Mídias precisam de testes próprios com limites da instância.
9. Validar pausa/retomada/cancelamento antes de ativar o trigger a cada 30 segundos. O worker processa uma mensagem por ciclo, sem atraso no navegador.

## Comportamento

- Reserva transacional com lock da campanha e unicidade por destinatário/conteúdo.
- Antes de cada chamada, reconsulta campanha, instância, opt-out e arquivamento. Reservado não é enviado.
- Texto usa POST /send/text; imagem/vídeo/áudio usa POST /send/media, com URL assinada privada por cinco minutos.
- Usa track_id para correlação, **não como garantia de idempotência do provedor**: a documentação permite valores duplicados.
- Resultado sem messageid, erro HTTP ou timeout fica incerto e não é reenviado automaticamente. Se um nó falhar após reservar/autorizar, o registro pode ficar reserved/sending e bloquear a campanha: conferir a instância antes de qualquer liberação manual. Reconciliador operacional ainda precisa ser validado/implementado com dados reais.
- Pausa/cancelamento interrompem futuras autorizações; não recolhem mensagens que a Uazapi já aceitou. Há uma janela entre autorização e chamada externa, sem transação distribuída.
- Agendamento usa scheduled_at, nunca envia antes. Retomada segue pelo status da campanha.
- O HTTP response é aceitação, não necessariamente entrega. sent_at só é marcado quando a API informa Sent/Delivered/Read; entregues/lidos vêm dos eventos.
- O webhook valida o token contra hash privado, remove token/BaseUrl antes de persistir e deduplica eventos. Workflow desabilita armazenamento de execuções de sucesso/erro para evitar reter tokens. Evite dados pinados e logs do payload em testes. O webhook responde 200 antes do processamento, conforme guia Uazapi; monitorar falhas, pois a entrega não tem retry automático garantido.
- Respostas recebidas são atribuídas à campanha mais recente já enviada ao mesmo telefone. É uma heurística; ainda deve ser validada com o dono. Não implica chat de atendimento nem atribuição automática de vendas.
- Eventos recebidos antes da gravação do messageid podem ficar sem correlação: permanecem em integration_events, mas replay/reconciliação ainda precisam ser implementados. Não apresentar esses KPIs como completos antes de testar esse caso.

## Vendas

A identificação é manual. Os totais de compra do cliente continuam editáveis no dashboard e na planilha. O vínculo de uma venda com campanha é um registro em sales; a tela de cadastro de vendas e uma aba/fluxo dedicado para vendas na planilha ainda precisam ser concluídos. Não deduzir uma venda de campanha a partir de has_purchased ou total_spent.

## Estado da entrega

SQL e lógica verificados localmente. Os JSONs precisam ser importados e testados no n8n real. Não foi configurado webhook externo nem realizada chamada de envio.

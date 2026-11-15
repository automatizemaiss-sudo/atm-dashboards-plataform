# Alertas de erros e conexão

Arquivos prontos para importar, ainda não instalados no servidor. Nenhum token está incluído nos arquivos.

## Credenciais

Crie/selecione uma credencial **Header Auth** separada, chamada **Uazapi — Alertas (final 69fb)**, com Name `token` e Value igual ao token da instância de alertas indicada pelo dono (identificador terminado em `69fb`). Não use a credencial FUTPB nos nós de envio de alertas. Se o UUID informado for somente o ID da instância, obtenha o token correspondente no painel: ID e token não são intercambiáveis.

Nos nós **Enviar alerta ao grupo**, escolha essa credencial. O destino já é `120363432266870295@g.us`, no servidor `https://automatizemais.uazapi.com`. A instância remetente precisa estar conectada e participar do grupo.

## Erros

1. Importe `06-alertas-erros.json` e salve.
2. Em cada workflow monitorado, abra Settings → Error workflow, selecione **ATM — Alertas de erros no grupo** e salve/publique conforme a versão do n8n.
3. O Error Trigger não precisa de agendamento. Não configure o próprio fluxo de alertas como seu error workflow.
4. Teste com um workflow separado, publicado, Webhook → Stop And Error. Vincule o error workflow e invoque a URL de produção. Execuções manuais não acionam o Error Trigger automaticamente.
5. Confira o recebimento no grupo. O alerta informa fluxo, nó, resumo do erro, horário de Brasília e link da execução quando disponível. Não envia o payload original.

Erros tratados com Continue On Fail ou HTTP configurado para nunca falhar podem não gerar execução com falha. No fluxo 03, a resposta HTTP usa `neverError` e resultados incertos são registrados no banco; esses casos precisam de uma condição explícita e Stop And Error depois do registro para acionar o error workflow. Erros de conexão não tratados normalmente fazem a execução falhar. Este pacote não altera o fluxo de disparos nem reenvia mensagens.

## Conexão

1. Importe `07-monitorar-conexao.json`.
2. Em **Consultar instância monitorada**, escolha uma Header Auth com o token do número dos disparos que deve ser monitorado. Use a credencial FUTPB aqui se ela corresponder ao número de disparos que deve ser monitorado; o envio dos alertas usa a credencial separada acima.
3. Em **Enviar alerta ao grupo**, use a credencial da instância de alertas.
4. Vincule o workflow 06 como Error workflow do monitor, salve e publique/ative o cron.

Consulta GET /instance/status a cada minuto. Avisa se o estado for disconnected, connecting ou hibernated. Repete a cada 15 minutos enquanto persistir; ao observar connected, libera um novo alerta de queda. A limitação usa static data do n8n, persistida em execuções automáticas bem-sucedidas; testes manuais não validam essa persistência. Evite execuções concorrentes do monitor. Se a API falhar ou responder em formato desconhecido, a execução falha e aciona o workflow 06, quando vinculado. A aceitação pela API não comprova entrega no grupo.

Se a própria Uazapi, a instância de alertas ou o n8n estiverem fora do ar, esse canal não consegue avisar. Para cobrir essas falhas é necessário monitor externo e canal independente.

## Webhook de conexão

A Uazapi permite adicionar `connection` aos eventos de um webhook. Preserve URL, eventos e filtros existentes; não substitua o webhook de mensagens sem revisar o consumidor atual. O evento usa `EventType: connection`, `instance.status`, `instance.lastDisconnectReason` e `instance.lastDisconnect`. O receptor deve autenticar, registrar e responder rapidamente; não publicar um receptor sem autenticação.

O pacote usa polling para não alterar o webhook de produção existente. Webhook pode acelerar a detecção, com polling como reconciliação: a Uazapi documenta que nem toda queda transitória produz evento e que entregas HTTP malsucedidas não são repetidas automaticamente.

## Reconexão

POST /instance/connect inicia o pareamento: sem phone, QR Code; com phone, código de pareamento. O usuário ainda precisa autorizar no WhatsApp. Um logout com 401 não deve ser tratado como uma simples falha temporária de rede. Não automatizar tentativas de envio ou reconexões em loop.

Fontes: https://docs.n8n.io/flow-logic/error-handling/ · https://docs.uazapi.com/docs/getting-started · https://docs.uazapi.com/webhook/connection

## Aviso no dashboard

Aplique `supabase/migrations/021_whatsapp_connection.sql` e atualize o workflow 07 a partir do JSON deste repositório. No nó **Salvar conexão no dashboard**, selecione a credencial privada Supabase já usada pelos outros workflows. Configure a variável n8n `ATM_WHATSAPP_INSTANCE_ID` com o UUID da linha em `public.whatsapp_instances` correspondente exatamente à credencial usada em **Consultar instância monitorada** (não o ID da Uazapi). Marque essa instância como habilitada no cadastro se ela estiver em uso.

O monitor grava cada consulta, inclusive `connected`, independentemente do intervalo do alerta no grupo. O dashboard consulta a cada 15 segundos e mostra um aviso no topo de todas as abas para instâncias habilitadas desconectadas, conectando ou hibernadas. O aviso some após uma confirmação recente de conexão. Sem consulta há mais de três minutos, ou sem registro, mostra conexão sem verificação recente. Falhas de leitura também são exibidas. Nenhum token da Uazapi é enviado ao navegador; somente a credencial de serviço pode registrar o status. Confira uma desconexão e uma reconexão após publicar o fluxo.

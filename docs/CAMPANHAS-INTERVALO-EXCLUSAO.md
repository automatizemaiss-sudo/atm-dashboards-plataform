# Intervalo por campanha e exclusão

## Ativação

1. Desative o fluxo 03 antigo e aguarde execuções em andamento terminarem. Se houver envios incertos, confira a instância antes de liberar a fila; não reenvie automaticamente.
2. Execute `supabase/migrations/011_campaign_pacing_archive.sql` uma vez, depois das migrações anteriores.
3. Reimporte `integrations/n8n/03-processar-campanhas.json`. Escolha novamente as credenciais Supabase e Header Auth da instância, preencha a Server URL no nó Configuração e mantenha o agendamento desativado até testar. O fluxo 04 de retornos não precisa ser substituído.
4. Publique o código na Vercel.
5. Crie uma campanha com dois números controlados pelo dono, intervalo 15–30 segundos. Configure enabled=true para o teste manual e execute o fluxo. A execução manual trata uma mensagem; o segundo envio precisa de outra execução. Para testar a sequência automática, ative somente o novo workflow com a campanha restrita a esses números. Confira timestamps e recepção antes de liberar outras campanhas.
6. Teste pausar enquanto a segunda mensagem aguarda, retomar, cancelar e excluir. Uma chamada já autorizada/aceita pela API não pode ser recolhida por essas ações.

## Funcionamento

O cron de cinco segundos descobre trabalho; não determina o intervalo de envio. Cada execução reserva no máximo uma mensagem. Uma reserva ativa, envio em andamento ou resultado incerto bloqueia novas reservas na mesma instância, inclusive de outras campanhas.

Após a API aceitar uma mensagem, o Supabase sorteia um inteiro entre o mínimo e o máximo da campanha, inclusive, e persiste a hora mínima do próximo envio da instância. O n8n reserva a próxima mensagem e passa pelo nó Wait até essa hora. A autorização no Supabase impede chamadas antes do prazo e revalida campanha, opt-out e arquivamento. O intervalo sorteado é a espera mínima a partir da confirmação HTTP; cron, assinatura de mídia, rede e execução podem aumentar o tempo real. Não há promessa de segundos exatos entre a chegada das mensagens no celular.

O dashboard permite definir mínimos/máximos em segundos ou minutos na criação e alterar o intervalo no cartão de uma campanha existente. Alterar o intervalo não resorteia uma espera já definida; aplica-se às esperas calculadas após os próximos envios. Padrão 15–30 segundos; máximo de uma hora. Campanhas existentes recebem o padrão na migração.

Se o n8n for interrompido após reservar, a reserva poderá bloquear a instância até revisão. Não há liberação automática que possa duplicar um envio incerto. Uma reserva descartada antes da autorização fica skipped e pode ser substituída por uma nova tentativa ao retomar, preservando o registro anterior.

## Status

- Agendada: aguarda a data programada.
- Processando: tem destinatários pendentes; inclui períodos de espera e não significa disparo simultâneo.
- Pausada: interrompe futuras autorizações; pode retomar os destinatários restantes.
- Cancelada: interrompe o restante e não permite retomar; não apaga mensagens enviadas.
- Concluída: todos os conteúdos elegíveis foram aceitos pela API ou não há mais destinatários elegíveis; não significa que todos receberam ou leram.

Excluir retira da lista ativa e cancela envios pendentes. O dashboard oferece Ver campanhas excluídas e Restaurar. Restaurar não retoma uma campanha cancelada. Destinatários, mensagens, retornos e vendas vinculadas são preservados.

Enviado pode vir da resposta inicial da API ou do evento Sent/Delivered/Read. Entregue e lido vêm dos webhooks. Respondido associa uma mensagem recebida à última campanha já enviada para aquele telefone, sem uma janela temporal; uma conversa posterior não relacionada também pode ser contada. Não é uma prova de causalidade. Vendas continuam atribuídas manualmente.

Mensagens enviadas fora do dashboard não têm um dispatch vinculado e não entram nos indicadores de enviado/entregue/lido das campanhas. Eventos autenticados ficam em integration_events; isso não cria um chat no dashboard nem um contato automaticamente. A regra acima de respostas pode relacionar mensagens recebidas de contatos com campanha anterior.

Os dados do dashboard são recarregados pelo botão Atualizar; ainda não há atualização em tempo real automática.

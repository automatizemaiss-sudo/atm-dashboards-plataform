# Alertas de bloqueio de envio

## Situação deste atendimento

A tentativa `dd640eb8-3c27-4838-82d0-90986748dfe5` foi confirmada manualmente como enviada, a pedido do responsável. Foi marcada `accepted`, sem reenviar, e a confirmação foi registrada em `integration_events`. O horário da confirmação manual não foi apresentado como horário comprovado de entrega.

No workflow de produção **FUTPB — Campanhas Uazapi** (`JU9GXNJLKUuIVvX0`), foi acrescentado e publicado o nó **Explicar fila sem envio**, conectado à saída falsa de **Há mensagem?**. O caminho de envio e o tratamento existente de número alternativo foram preservados.

A migration **020_delivery_alerts.sql** foi aplicada no Supabase de produção em 14/11/2026, após aprovação explícita do responsável. A instalação e as permissões foram verificadas: alertas e confirmação manual disponíveis, reserva permitida ao service role do n8n, acesso anônimo e acesso direto ao núcleo bloqueados. A proteção contra envio duplicado continua ativa. O banner visual depende da publicação do dashboard atualizado; o canal externo de notificações depende do Error workflow configurado no n8n.

## Ativação

1. **A 020 já está aplicada no ambiente de produção deste projeto.** Para outro ambiente, execute `supabase/migrations/020_delivery_alerts.sql` depois das migrations anteriores. Não reexecute a 020: ela renomeia a implementação instalada da reserva para uma função interna, preservando seu código, e expõe um invólucro que acrescenta o diagnóstico. A implementação interna não é executável pelas credenciais de cliente ou pelo service role diretamente.
2. Publique o dashboard atualizado. Há um aviso no topo de todas as abas quando existe bloqueio, com consulta a cada 15 segundos. Na aba Campanhas, aparecem campanha, contato, horário da reserva, motivo e tentativa. O aviso permanece até a situação ser resolvida.
3. O workflow de produção já recebeu o nó adicional. Para outro workflow com personalizações, use `integrations/n8n/08-diagnostico-fila.json` para adicionar **somente** esse nó e conecte a saída falsa de **Há mensagem?** à entrada dele. Evite substituir um workflow personalizado pelo 03 completo.
4. Para notificações externas, vincule o workflow de erros já configurado em **Settings → Error workflow**, seguindo `integrations/n8n/ALERTAS.md`. O diagnóstico gera uma falha explícita, com motivo e ID da tentativa. Vincular e testar o canal de alerta é necessário para receber fora do n8n. Nenhuma nova mensagem de teste foi enviada ao grupo neste atendimento.

## O que aparece

- `uncertain_delivery`: envio sem confirmação. A fila da instância está bloqueada para evitar duplicatas.
- `stalled_dispatch`: reserva/envio continua pendente mais de dois minutos após o horário previsto.
- `instance_busy`: outra execução está enviando ou aguardando o intervalo normal; não é erro.
- `no_eligible_campaign`: não há campanha habilitada para enviar agora; não é erro.

A reserva continua retornando `available: false` quando nada pode ser enviado, mas agora acrescenta `blocked`, `reason`, `message`, `dispatch_id` e `notify` quando aplicável.

O aviso no dashboard não expira por tempo. Para o mesmo bloqueio, o n8n gera uma falha de alerta na primeira detecção e, se persistir, no máximo uma a cada 15 minutos. O registro da janela fica no banco para sobreviver a reinícios. Uma nova tentativa bloqueada tem sua própria janela.

## Conferência manual

O botão **Conferi: a mensagem foi enviada** exige confirmação explícita do operador. A RPC confere a organização, marca a tentativa como aceita, registra a auditoria e respeita o intervalo mínimo da campanha antes do próximo envio. Não inventa ID da Uazapi, entrega ou leitura. O horário de confirmação é usado quando não há horário de envio já registrado.

Reservas em atraso exigem investigação da execução; o botão de confirmação não é oferecido para elas. Um envio em andamento há mais de dois minutos pode ser confirmado somente após conferência externa. Não há reenvio automático de resultados incertos.

## Verificação

Testes cobrem distinção entre intervalo normal e bloqueio, aviso persistente, limitação de frequência, isolamento por organização, confirmação idempotente e continuação com outro contato sem reenviar a tentativa confirmada. Build e TypeScript também precisam passar antes da publicação.

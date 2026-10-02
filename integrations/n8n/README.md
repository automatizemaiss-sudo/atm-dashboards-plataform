# Primeiro teste no n8n

1. Crie um workflow no n8n e use Import from File para importar `01-validar-planilha.json`.
2. No node Ler Página1, selecione/crie uma credencial Google Sheets com acesso à planilha. O conector desta conversa não fornece credenciais ao n8n.
3. Confira: Get Row(s), documento `1ugjC_pxX2MqC5_5e_gBOTagv_kN-3ZuN2tffQ8Mb3CI`, aba Página1. A primeira linha contém cabeçalhos.
4. Execute manualmente e abra o output de Validar sem gravar. Cada linha deve resultar em valid=true. Corrija casos valid=false antes da importação.
5. Se não houver linhas de clientes, o node não terá itens para validar. Isso não indica falha.

Este fluxo é somente leitura. Não conecta/grava no Supabase, não envia WhatsApp e não implementa sincronização. Foi verificado como JSON e o código de validação foi testado localmente; a importação e o acesso Google precisam ser testados na sua instância n8n.

## Mapeamento confirmado

Nome Completo → customers.name
Telefone → customers.phone (texto normalizado +55)
Tamanho → customers.size
Já comprou? → customers.has_purchased (Sim/Não/vazio)
Aceita Mensagens? → customers.can_receive_campaigns (Não bloqueia; Sim/vazio permitem)
Time(s) → teams + customer_teams, não coluna de texto no cliente. O teste aceita separadores ponto e vírgula, vírgula ou quebra de linha.

Data → customers.birthday (aniversário, confirmado). Aceita DD/MM/AAAA ou AAAA-MM-DD; vazio mantém null. Datas sem ano são reportadas para correção, sem inventar ano.
Camisa Preferida → customers.desired_shirt (camiseta desejada no sorteio, confirmado).

## Depois da validação

Preparar uma RPC transacional de importação para cliente e times, resolução da organização FUTPB e chave de sincronização estável na planilha. A etapa de escrita ainda não está neste fluxo. A planilha atual não possui UUID de cliente ou versão de sincronização; não usar número de linha como identidade permanente.

No n8n, a integração de escrita exigirá uma credencial privada Supabase, guardada no credential store do n8n. Não usar a chave publishable do dashboard para uma importação administrativa e não desativar RLS. Primeiro executar a importação manual e validar um registro nos dois sistemas; somente depois habilitar sincronização contínua nos dois sentidos, com controle de conflitos e proteção contra loops.

## Sincronização completa

O fluxo 02-sincronizacao-bidirecional.json e a migration 003_sheet_sync.sql substituem a etapa de escrita pendente acima. Siga docs/SINCRONIZACAO.md; não execute antes de configurar cabeçalhos e credenciais.

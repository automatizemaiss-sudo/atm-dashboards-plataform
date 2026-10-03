# Vendas e formulário FUTPB

## Ativar

1. Execute as migrações pendentes em ordem: 008 (Feminina e busca), 009_manual_sales.sql e 010_public_registration.sql. Não repita migrações já instaladas.
2. A aba Vendas já foi criada na planilha_dashboard, sem alterar Página1.
3. Importe `integrations/n8n/05-sincronizacao-vendas.json`. Selecione as credenciais Supabase API e Google Sheets OAuth2 nos respectivos nós. Execute manualmente; confira ida e volta antes de ativar o agendamento de um minuto. O fluxo de contatos continua independente.
4. Para o formulário, configure no servidor/Vercel a variável `SUPABASE_SERVICE_ROLE_KEY`, com a credencial privada do Supabase. Não use prefixo NEXT_PUBLIC e não comite a chave. As variáveis públicas de URL/publishable já existentes continuam necessárias.
5. Faça deploy na Vercel. O formulário está em `/sorteio`, sem exigir login; o cadastro de vendas está dentro de Campanhas. Sem a chave privada o formulário exibe inscrições indisponíveis ao enviar, sem gravar dados.

## Venda manual

Escolha o contato por nome/telefone e selecione a campanha (ou deixe sem vínculo). A referência da venda deve ser única: número do pedido ou identificador gerado. Valor, data e observações são opcionais. É possível editar e cancelar a venda; o cancelamento preserva histórico e exclui a venda do indicador da campanha.

A atribuição é decisão do dono e não tem prazo automático: uma compra pode ser vinculada mesmo depois do envio. O sistema não infere a campanha a partir de respostas ou totais de compra. Registrar uma venda não recalcula os totais do contato, que podem conter compras antigas fora desta lista. Cada linha ativa de sales conta como uma venda da campanha escolhida.

## Aba Vendas

| Coluna | Cabeçalho | Uso |
|---|---|---|
| A | ID Venda | Automático; não apagar nem reutilizar. |
| B | Referência | Obrigatória e única. Ex.: pedido-123. |
| C | ID Contato | UUID de ID Cliente na Página1; obrigatório. |
| D | Contato | Preenchido pelo fluxo, para consulta. |
| E | Telefone | Preenchido pelo fluxo, para consulta. |
| F | ID Campanha | UUID da campanha; opcional. Use o dashboard para escolher pelo nome. |
| G | Campanha | Nome preenchido pelo fluxo; mudar apenas o nome não muda o vínculo. |
| H | Valor | Número >=0, no máximo duas casas, sem R$ nem separador de milhar. Vazio se desconhecido. |
| I | Data da Venda | DD/MM/AAAA ou AAAA-MM-DD, entre 1900 e hoje; vazio permitido. |
| J | Observações | Texto opcional. |
| K | Cancelada? | Sim ou Não; vazio = Não. |
| L | Versão Sync | Automática; não editar. |

Para adicionar na planilha: preencha B/C e os campos desejados, deixando A/L vazios. D/E/G são rótulos de consulta. Não apague linhas para cancelar: use K=Sim. O fluxo identifica a venda por ID ou pela referência; retentativas não criam outra venda com a mesma referência. Alterações concorrentes no mesmo campo viram conflitos no resultado do fluxo, sem sobrescrita. Após uma falha, a reserva expira em dez minutos. Como no fluxo de contatos, existe uma janela entre a releitura e a escrita do Google Sheets; evite editar enquanto uma execução grava.

## Formulário

Usa as perguntas enviadas pelo usuário, com indicações opcional. Acrescenta autorização opcional e desmarcada para receber campanhas; para novos contatos, não marcar grava can_receive_campaigns=false. O formulário não envia WhatsApp.

Contatos novos entram no Supabase e o fluxo de contatos os exporta para Página1. Um telefone existente não é duplicado nem tem seus dados sobrescritos: o envio fica em registration_submissions com status review para revisão do dono no Supabase. O formulário não altera compras, vendas, consentimento ou arquivamento dos contatos existentes. Não reativa um contato arquivado.

A API valida campos no servidor, limita solicitações persistidas por hash de IP e telefone, usa campo invisível antirrobô e ID de envio para retentativa idempotente. Retorna confirmação genérica, sem informar se o telefone já existia. Não é uma garantia contra bots; CAPTCHA pode ser acrescentado se necessário. IP bruto não é persistido.

Antes de divulgar, testar inscrição nova, reenvio, recusa de campanhas e sincronização com a planilha. O conteúdo do formulário é cadastro para o sorteio; regras, data do sorteio e premiação dependem da loja e não foram inventadas.

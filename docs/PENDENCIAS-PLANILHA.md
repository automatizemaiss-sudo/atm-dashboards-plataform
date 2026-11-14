# Pendências da planilha e erros de cadastro

## Instalação

1. No Supabase SQL Editor, execute **somente** `supabase/migrations/017_registration_issues.sql`, após as migrations 001–016 já aplicadas. A migration preserva os dados existentes e adiciona validação aos próximos cadastros/edições. Não reexecute migrations anteriores.
2. Atualize o dashboard com o código deste projeto.
3. Atualize o workflow de sincronização com `integrations/n8n/02-sincronizacao-bidirecional.json`. Preserve as credenciais e configurações da sua instância. O arquivo é entregue inativo. Desative o workflow anterior para evitar sincronizações paralelas.
4. Selecione a credencial privada Supabase também no novo nó **Registrar validação**. Esse nó chama `sheet_sync_report_validation`; a chave privada continua somente no credential store do n8n.
5. Execute pelo trigger **Teste manual**. Com erros, o workflow registra as linhas inválidas, libera a reserva e encerra em **Exibir pendências**. Não importa parcialmente os contatos. A nova aba mostra as pendências após **Atualizar**.
6. Corrija os valores na planilha. Execute novamente: a nova validação encerra as pendências corrigidas e a sincronização prossegue. Teste com um contato antes de ativar o agendamento.

## Comportamento

- O formulário de contato limita aniversário e última compra até hoje, no horário de Brasília, e exige ano completo. A validação no banco também bloqueia nome vazio, telefone inválido e datas anteriores a 1900 ou futuras, incluindo escritas externas. Telefone e valores de compra continuam sujeitos às constraints existentes.
- A sincronização aceita ano abreviado de última compra em 2000–2099, sem aceitar data futura. Não altera datas ambíguas automaticamente. Registra o primeiro erro encontrado em cada linha, com nome, campo, valor e motivo. Uma nova execução pode revelar outro campo inválido da mesma linha.
- Antes de autorizar um envio, o worker confere nome, telefone, aniversário e última compra do contato e do snapshot. Se encontrar erro de cadastro, não envia para esse destinatário, registra o motivo na campanha e permite que a fila siga para os outros destinatários. A campanha mostra **Enviar para Pendências da planilha**.
- Erros já registrados pelo provedor ficam visíveis na campanha. A pessoa responsável pode classificá-los como erro de cadastro e encaminhá-los. Isso não modifica um envio em andamento ou com resultado incerto: o estado de envio é preservado para evitar duplicatas.
- Nas pendências de campanha, **Editar cadastro** abre o contato. **Validar correção e resolver** confere os dados salvos e encerra a pendência. O snapshot original e o histórico são preservados; o contato não é reenviado automaticamente na campanha original. Se o erro estava somente no snapshot antigo, o cadastro atual pode já estar correto.
- Erros da planilha são resolvidos por uma nova leitura, não por um botão que ignora a validação. Nenhum registro é apagado ao resolver; a fila mostra somente os abertos.

## Validação local

Os testes cobrem bloqueio de datas, coleta de várias linhas inválidas, liberação da reserva, resolução após nova leitura, permissões por organização, encaminhamento de erro de campanha e preservação de resultados incertos. A configuração das credenciais no n8n e a implantação no ambiente real continuam necessárias.

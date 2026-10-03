# Planilha e próximos passos

Mantenha a aba Página1 e os cabeçalhos A1:P1 sem mudar a ordem. Não insira colunas no meio. As regras abaixo devem começar na linha 2 para não validar os cabeçalhos.

| Coluna | Campo | Formato e regra |
|---|---|---|
| A | Nome Completo | Texto obrigatório para linhas preenchidas. |
| B | Telefone | Texto simples, com DDD; recomendado +5542999883017. Não repetir telefone. |
| C | Camisa Desejado Sorteio | Texto livre; pode ficar vazio. O cabeçalho anterior Camisa Preferida também é aceito. |
| D | Time(s) | Nomes separados por ponto e vírgula: Barcelona; Palmeiras. Não usar ponto e vírgula dentro do nome de um time. |
| E | Tamanho | Lista P, M, G, GG, XG; vazio se desconhecido. Esses são os tamanhos exibidos atualmente nos filtros. |
| F | Data de aniversário | Data completa, DD/MM/AAAA ou AAAA-MM-DD; entre 1900 e hoje; vazio permitido. O cabeçalho anterior Data também é aceito. |
| G | Já comprou? | Lista Sim, Não; vazio se desconhecido. |
| H | Aceita Mensagens? | Lista Sim, Não. Atenção: vazio permite campanhas; Não bloqueia. |
| I | ID Cliente | Automático; não digitar, apagar ou copiar de outra pessoa. |
| J | Versão Sync | Automático; não editar manualmente. |
| K | Possui Indicações? | Lista Sim, Não; vazio se desconhecido. |
| L | Total Comprado | Número >=0, sem R$, sem separador de milhar; exemplos 100 ou 100,50. Vazio difere de zero. |
| M | Número de Pedidos | Inteiro >=0; vazio se desconhecido. |
| N | Última Compra | Data completa DD/MM/AAAA ou AAAA-MM-DD; sem data futura; vazio permitido. |
| O | Excluído? | Lista Sim, Não; vazio equivale a Não. Use Sim para excluir da base ativa, preservando histórico. |
| P | Tipos de camisa | Jogador, Torcedor, Retrô, Feminina; múltiplos separados por ponto e vírgula (também aceita vírgula). |

## Configuração manual no Google Sheets

1. Selecione B2:B, use Formatar → Número → Texto simples. Essa configuração deve ser aplicada antes de digitar telefones para preservar o sinal + e os dígitos.
2. Para E2:E e cada coluna de Sim/Não, use Dados → Validação de dados → Adicionar regra → Lista suspensa, informe as opções e configure rejeição de dados inválidos. Deixe as células opcionais vazias quando não houver informação.
3. Para F2:F e N2:N, use validação de data entre 01/01/1900 e a data atual e um formato personalizado dd/mm/aaaa ou yyyy-mm-dd. A sincronização também escreve datas como texto ISO; verifique a validação após um ciclo de ida e volta, antes de liberar aos operadores.
4. Para L2:L e M2:M, crie regras numéricas >=0; em M, use fórmula personalizada para exigir inteiro se necessário. Não use símbolo monetário nas células lidas pela integração.
5. Para impedir valores errados em P2:P com máxima previsibilidade, use uma lista suspensa simples com as 15 combinações abaixo. Ela aceita a escrita com ponto e vírgula que o fluxo faz no retorno, sem depender de conversões de chips. Uma seleção pode conter vários interesses. A alternativa é a lista com múltipla seleção; nesse caso teste o retorno do n8n, pois ele escreve texto RAW e pode mudar a apresentação dos chips.
6. Proteja a linha 1 e I:J contra edição dos operadores. Mantenha a conta Google usada no n8n autorizada a editar essas áreas; proteção que bloqueie essa conta impede sincronização.
7. Faça um teste: altere um nome e os tipos de camisa na planilha, sincronize, confira no dashboard; depois altere no dashboard, sincronize e confira na planilha. Teste também Sim/Não e datas antes de liberar a operação.

Opções para P:

```text
Feminina
Jogador
Retrô
Torcedor
Feminina; Jogador
Feminina; Retrô
Feminina; Torcedor
Jogador; Retrô
Jogador; Torcedor
Retrô; Torcedor
Feminina; Jogador; Retrô
Feminina; Jogador; Torcedor
Feminina; Retrô; Torcedor
Jogador; Retrô; Torcedor
Feminina; Jogador; Retrô; Torcedor
```

Para times, pode criar uma lista de nomes oficiais e combinações usadas pela loja, mas o fluxo também aceita texto livre com múltiplos times. A busca ignora caixa e acentos, aceita trechos e normaliza Barça/barca para Barcelona; não corrige qualquer apelido nem erro de digitação. Preserve grafia padronizada para evitar entradas separadas nos indicadores.

Não apague uma linha para excluir um contato: use Excluído? = Sim. Não reutilize ID Cliente. Novos contatos podem ser adicionados na planilha com I/J vazios ou no dashboard.

## O que falta

- Formulário próprio FUTPB implementado em /sorteio; configuração em VENDAS-FORMULARIO.md. A alternativa Google Forms permanece opcional. Definir perguntas, tamanhos, lista de times, consentimento e destino. Sugestão: Google Forms → aba de respostas separada → fluxo n8n que normaliza e identifica por telefone antes de gravar no Supabase. Não apontar respostas diretamente para Página1, pois o formulário acrescenta timestamp e usa sua própria ordem de colunas. Reenvio do formulário não deve apagar dados de compra, ID ou versão existentes.
- WhatsApp: obter URL real e token da instância Uazapi, importar/configurar os dois fluxos preparados, conectar a instância e configurar o webhook. Testar envio, entrega, leitura, resposta, mídias, pausa/cancelamento e recusas com o número do dono antes de liberar campanhas. As instruções completas estão em CAMPANHAS-UAZAPI.md. Fluxos continuam desativados até configurar e validar.
- Vendas por campanha: tela e aba Vendas implementadas, com fluxo próprio; ativação em VENDAS-FORMULARIO.md. Total Comprado/Já comprou não identificam sozinhos a campanha que gerou a venda.
- Operação real: validar recuperação de falhas de envio e de eventos sem correlação, além dos conflitos de sincronização. A sincronização já foi confirmada pelo usuário; configuração externa das novas alterações ainda depende de executar as migrações e atualizar o fluxo.

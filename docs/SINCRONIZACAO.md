# Ativar Sheets ↔ Supabase no n8n

## 1. Supabase

Execute **somente a nova migration** `supabase/migrations/003_sheet_sync.sql` no SQL Editor. Não repita 001 ou 002.

Ela adiciona baselines, reserva por organização, registro de conflitos e quatro RPCs privadas. O usuário do dashboard pode ler os registros da própria organização; apenas a credencial privada do n8n pode executar as RPCs de sincronização.

## 2. Cabeçalhos da planilha

Preserve A:H. Em **I1:O1**, adicione nesta ordem:

```text
ID Cliente	Versão Sync	Possui Indicações?	Total Comprado	Número de Pedidos	Última Compra	Excluído?
```

Estrutura completa:

| Coluna | Cabeçalho | Uso |
|---|---|---|
| A | Nome Completo | Nome |
| B | Telefone | Texto com DDD; sai normalizado +55 |
| C | Camisa Desejado Sorteio | Camiseta desejada no sorteio |
| D | Time(s) | Separar por ponto e vírgula |
| E | Tamanho | Tamanho |
| F | Data de aniversário | Aniversário DD/MM/AAAA ou AAAA-MM-DD |
| G | Já comprou? | Sim, Não ou vazio |
| H | Aceita Mensagens? | Não bloqueia; Sim/vazio permitem |
| I | ID Cliente | UUID preenchido pela integração; não editar |
| J | Versão Sync | Controle preenchido pela integração; não editar |
| K | Possui Indicações? | Sim, Não ou vazio |
| L | Total Comprado | Número opcional, sem símbolo R$ |
| M | Número de Pedidos | Inteiro opcional |
| N | Última Compra | Data opcional DD/MM/AAAA ou AAAA-MM-DD |
| O | Excluído? | Sim arquiva; Não/vazio deixa ativo |

Datas vazias e compras não informadas permanecem null. Valores monetários aceitam 1234.56 ou 1.234,56. A importação não inventa vendas atribuídas a campanhas. Os cabeçalhos devem corresponder à tabela. As versões anteriores Camisa Preferida e Data também são aceitas nas colunas C e F. Não use fórmulas nas colunas A:O: o fluxo trabalha com valores e escreve RAW, preservando telefone como texto e sem executar fórmulas vindas dos nomes.

## 3. Credenciais no n8n

- **Google Sheets OAuth2 API**: conta com acesso de edição à planilha.
- **Supabase API**: Host `https://wlhugaduwhevmoymyhad.supabase.co` e a Secret Key do projeto (ou a service_role legada, conforme a versão do n8n). Guardar somente no credential store do n8n, nunca no frontend, JSON do fluxo, Git ou conversa.

O fluxo usa HTTP Request com credenciais predefinidas para chamar as APIs. Em n8n antigo que não aceita secret keys sb_secret, usar service_role legada no credential store. Não usar a publishable key para as funções privadas.

## 4. Importar e executar

Importe `integrations/n8n/02-sincronizacao-bidirecional.json` em um workflow **novo**. Escolha a credencial Supabase nos quatro nós de RPC e a credencial Google nos três nós de planilha. Não copie os valores de credenciais para parâmetros.

Execute o workflow completo pelo trigger **Teste manual**. Não execute isoladamente o nó de escrita com dados antigos. O arquivo vem inativo; não publicar/ativar antes do teste. Desative qualquer outra sincronização antiga para esta planilha.

O nó Confirmar sincronização deve retornar status=done, synced e conflicts. Um erro anterior pode manter a reserva até dez minutos; aguarde expirar antes de nova execução. Não habilitamos retries automáticos da escrita Google: uma resposta incerta é reconciliada numa nova leitura, em vez de repetir append.

## 5. Testes de aceitação antes de ativar

1. Execute com o cliente de teste. Ele deve aparecer no dashboard e receber ID Cliente/Versão Sync na planilha.
2. Execute de novo: deve permanecer um cliente no Supabase e uma linha na planilha.
3. Edite tamanho na planilha; execute; confira no dashboard após Atualizar.
4. Edite nome no dashboard; execute; confira na planilha.
5. Altere o telefone mantendo o ID Cliente; execute; confira que o UUID permanece.
6. Mude nome no dashboard e tamanho na planilha antes de executar: ambos devem ser preservados.
7. Mude tamanho para dois valores diferentes nos dois lados: deve haver conflito e nenhuma sobrescrita desse cliente.
8. Resolva o conflito colocando o mesmo valor nos dois lados e execute novamente.
9. Cadastre um cliente no dashboard: a execução seguinte cria uma linha com seu UUID.

Depois desses testes, publique/ative apenas este workflow. O trigger automático executa a cada minuto. Cadastros e edições podem levar até um ciclo para aparecer no outro lado; o dashboard continua conectado apenas ao Supabase.

## Como evita duplicatas e loops

A primeira associação usa telefone normalizado e a constraint unique do banco. Depois usa UUID. UUIDs/telefones repetidos na planilha interrompem a execução antes da importação. Trocar telefone de um cliente para o de outro provoca erro de unicidade e rollback, sem mesclar pessoas automaticamente.

A reconciliação compara planilha, banco e baseline por campo. Edições distintas são combinadas; edições incompatíveis no mesmo campo ficam em sheet_sync_conflicts. A primeira ligação de um cliente já existente com dados divergentes também pede revisão, em vez de escolher um lado silenciosamente.

A reserva bloqueia dois workers simultâneos por organização. O plano é reaproveitável dentro da execução. O baseline só é confirmado após sucesso da escrita; alterações posteriores no Supabase ficam para o próximo ciclo. Uma leitura sem alterações não atualiza clientes nem dispara um loop. As relações de times são reconciliadas junto com os campos do cliente.

## Limites reais

Não existe transação distribuída entre PostgreSQL e Google Sheets. Há releitura imediatamente antes da gravação e validação do lease, mas não há compare-and-swap para células no Sheets. Uma pessoa editando/ordenando linhas no intervalo entre essa releitura e a escrita pode ter a alteração sobrescrita ou a posição mudada. Evite ordenar/editar enquanto o workflow executa. Para eliminar essa janela, seria necessário controlar também todas as edições de planilha, o que não é possível com edição livre.

Excluir linha de cliente já sincronizado produz conflito; não apaga o cliente nem recria a linha automaticamente. A resolução de exclusões, mesclagens e conflitos é manual nesta entrega. O fluxo processa até 9.999 linhas, lê A:O, exige colunas na ordem acima e não gera uma cópia de backup da planilha. Colunas fora de A:O não são alteradas.

Migration e lógica passaram em PostgreSQL local com Auth/Storage simulados e testes de guarda. O workflow JSON ainda precisa ser importado e executado na sua instância n8n com as credenciais reais. Nenhum dado de produção foi alterado nesta entrega.

Para projetos já configurados, aplicar 004, 005 e 006 conforme docs/ATUALIZACAO.md antes de usar o novo fluxo.

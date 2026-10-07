# Tamanhos, NBA e gravação de contatos

1. Execute `supabase/migrations/013_contact_options_save.sql` no SQL Editor do Supabase.
2. Publique o código atualizado na Vercel.
3. Atualize o fluxo 02 com `integrations/n8n/02-sincronizacao-bidirecional.json`, preservando as credenciais e o nome real da aba de contatos utilizado no seu fluxo. O arquivo gerado usa Página1. Desative a versão anterior antes de ativar a nova.

Na validação de dados da coluna Tamanho da planilha, mantenha estas opções:
P, M, G, GG, XG, 3XL, 4XL, Infantil 2, Infantil 4, Infantil 6, Infantil 8, Infantil 10, Infantil 12, Infantil 14, Infantil 16.

Na coluna Tipos de camisa, acrescente NBA às opções Jogador, Torcedor, Retrô e Feminina. Para vários interesses, use ponto e vírgula: `NBA; Feminina`.

O formulário público exige Sim ou Não na intenção de compra, sem Prefiro não informar. Cadastros antigos com resposta vazia são preservados.

A função save_customer continua verificando a associação do usuário à organização antes de gravar. O contato editado e os times são procurados dentro dessa organização; as chaves estrangeiras impedem vincular registros de organizações distintas. A função executa a transação com permissão do banco, e as tabelas mantêm RLS para acessos diretos.

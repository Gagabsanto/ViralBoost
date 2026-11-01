VIRALBOOST — REDESIGN

ARQUIVOS
- index.html: substituir o arquivo index.html na raiz do repositório GitHub Gagabsanto/ViralBoost.
- stats_patch.sql: executar uma vez no Supabase > SQL Editor > New query > Run. Cria uma função somente de leitura para exibir totais globais do mural, sem depender do filtro ou dos 100 vídeos carregados.
- supabase_setup.sql: script original de configuração inicial. NÃO execute novamente se o banco já está funcionando.

CONTAGEM DE APOIOS
O botão de coração registra um apoio dentro do ViralBoost. A função support_video grava a reação, aumenta posts.likes_count e credita +2 ViralCoins ao usuário, tudo no banco. Não lê nem altera curtidas reais do TikTok.

PUBLICAÇÃO
Substitua apenas index.html no diretório raiz do repositório. Não envie a pasta inteira nem o ZIP para o GitHub Pages.

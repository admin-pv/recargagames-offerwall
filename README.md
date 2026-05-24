# Recarga Games — Offerwall

MVP do offerwall: landing pública com ofertas de afiliados, login Supabase, log
de impressões/cliques e tabelas prontas pra reward delivery (Brief 2).

## Stack

HTML estático + vanilla JS + Supabase (mesma instância da loja:
`ashmirzgyuhspymldpfv`) + Netlify (build sem build step). Edge Function Deno
pra registrar cliques server-side e redirecionar 302 pra rede.

Sem framework, sem package manager, sem suite de testes. Mesma filosofia de
`recargagames-frontend` e `recargagames-admin`.

## Como rodar localmente

```bash
python3 -m http.server 8000
# abre http://localhost:8000
```

A Edge Function `/click` **não roda** com o `python -m http.server`. Pra testar
o fluxo de clique localmente, use o Netlify CLI:

```bash
npm i -g netlify-cli
netlify dev   # serve estáticos + edge functions em http://localhost:8888
```

## Setup inicial (one-time)

### 1. Aplicar migration no Supabase
Copia o conteúdo de `migrations/0001_init.sql` no SQL Editor do Supabase
Dashboard e roda. Cria 5 tabelas, aplica RLS e popula 4 offers de teste.

### 2. Habilitar email/password no Supabase Auth
Dashboard → Authentication → Providers → Email. Garanta que está ativo.

Pra MVP rápido, considere desligar "Confirm email" em Authentication → Email
Templates / Settings — senão cada signup precisa de verificação por email
(e ainda não temos provider de email transacional configurado).

### 3. Configurar env vars do Netlify
No painel do site Netlify → Site configuration → Environment variables:

| Variável | Valor |
|---|---|
| `SUPABASE_URL` | `https://ashmirzgyuhspymldpfv.supabase.co` |
| `SUPABASE_SECRET_KEY` | `sb_secret_...` (pegar em Project Settings → API no Supabase) |

A publishable key (`sb_publishable_...`) já está hardcoded no `index.html` —
é pública por design e a mesma usada pelo `recargagames-frontend`.

### 4. Deploy
Push pra `main` → Netlify auto-deploya.

## Como funciona

### Landing (`index.html`)
- `GET /` carrega as offers ativas (`SELECT * FROM offerwall_offers WHERE status='active'`)
- Renderiza cards e dispara 1 impressão por offer em `offerwall_impressions`
- Botão "Entre para resgatar" quando deslogado
- Botão "Resgatar oferta" quando logado → submete form POST pra `/click`

### Edge Function (`/click`)
- Recebe `offer_id` + `access_token` (do Supabase Auth) via form POST
- Valida o token contra `/auth/v1/user`
- Carrega a offer ativa
- Insere em `offerwall_clicks` com user_id validado, IP/geo do Netlify, UA
- Substitui `{click_id}` no `tracking_link_template` (ou cai pra `preview_url`)
- Retorna 302 → browser segue pro link da rede

### O que NÃO está aqui (Brief 2)
- Endpoint S2S de postback (`/postback`)
- Insert em `offerwall_conversions`
- Crédito automático em `offerwall_wallet_transactions`
- UI de carteira/saldo pro usuário

## Convenções

- Tabelas: prefixo `offerwall_` em **todas**. Não toca em tabelas da loja.
- Cores brand: `--orange: #FF6A00`, `--purple: #8B5CF6`, dark theme.
- Sessão e auth: mesmo `auth.uid()` da loja (instância Supabase compartilhada).
- Edge function env vars: nunca commitar; sempre via painel Netlify.

## Smoke test pós-deploy

1. Abre a URL do site Netlify → vejo 4 cards com imagens placeholder
2. Deslogado, clica em um card → abre o modal "Entrar"
3. Cria conta com email novo, loga → botões viram "Resgatar oferta"
4. Clica em "Resgatar oferta" → redireciona pra `example.com/preview/...`
5. Confirma no Supabase:
   ```sql
   SELECT count(*) FROM offerwall_impressions;  -- > 0
   SELECT count(*) FROM offerwall_clicks;       -- > 0
   SELECT user_id FROM offerwall_clicks ORDER BY created_at DESC LIMIT 1;
   ```
6. RLS test (rodar como anon no SQL Editor com Role = anon):
   ```sql
   SELECT * FROM offerwall_wallet_transactions;  -- 0 rows (RLS bloqueia)
   INSERT INTO offerwall_wallet_transactions(user_id, type, amount) VALUES (gen_random_uuid(), 'credit', 1); -- bloqueado
   ```

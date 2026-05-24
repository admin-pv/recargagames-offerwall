-- ============================================================================
-- Offerwall MVP — Brief 1: Fundação
-- ----------------------------------------------------------------------------
-- 5 tabelas novas no Supabase ashmirzgyuhspymldpfv, prefixo `offerwall_`.
-- Não altera nenhuma tabela existente da loja/admin.
--
-- Como aplicar:
--   1. Supabase Dashboard → SQL Editor → New query
--   2. Cola este arquivo inteiro e roda
--   3. Verifica que apareceram as 5 tabelas em Database → Tables
--
-- Idempotente: rodar 2x não quebra, mas o seed só insere offers que ainda
-- não existem (chaves UUID fixas).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. offerwall_offers — catálogo de offers de afiliados
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.offerwall_offers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  description text,
  advertiser_name text,
  network_name text,
  preview_url text,
  tracking_link_template text,
  payout_amount numeric,
  payout_currency text DEFAULT 'USD',
  reward_amount numeric NOT NULL,
  reward_currency text DEFAULT 'BRL',
  target_countries text[] DEFAULT '{BR}',
  target_devices text[] DEFAULT '{mobile,desktop,tablet}',
  creative_image_url text,
  status text DEFAULT 'draft',
  priority int DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 2. offerwall_impressions — log de cada offer exibida na landing
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.offerwall_impressions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  offer_id uuid REFERENCES public.offerwall_offers(id) ON DELETE CASCADE,
  user_id uuid,
  session_id text,
  is_guest boolean DEFAULT true,
  ip_address text,
  country text,
  user_agent text,
  device_type text,
  placement text DEFAULT 'landing',
  created_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS offerwall_impressions_offer_id_idx
  ON public.offerwall_impressions(offer_id);

-- ---------------------------------------------------------------------------
-- 3. offerwall_clicks — log de cliques redirecionados pra rede
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.offerwall_clicks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  click_id uuid UNIQUE NOT NULL,
  offer_id uuid REFERENCES public.offerwall_offers(id) ON DELETE CASCADE,
  user_id uuid NOT NULL,
  session_id text,
  is_guest boolean DEFAULT false,
  ip_address text,
  country text,
  user_agent text,
  device_type text,
  redirected_to text,
  created_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS offerwall_clicks_user_id_idx
  ON public.offerwall_clicks(user_id);
CREATE INDEX IF NOT EXISTS offerwall_clicks_offer_id_idx
  ON public.offerwall_clicks(offer_id);

-- ---------------------------------------------------------------------------
-- 4. offerwall_conversions — ESTRUTURAL. Nenhum código escreve aqui no Brief 1.
--    O postback S2S do Brief 2 que vai popular.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.offerwall_conversions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  click_id uuid,
  offer_id uuid,
  user_id uuid,
  is_guest boolean DEFAULT false,
  network_transaction_id text UNIQUE,
  status text DEFAULT 'pending',
  payout_received numeric,
  payout_currency text,
  reward_delivered numeric,
  reward_currency text,
  reward_delivery_status text DEFAULT 'pending',
  raw_postback_payload jsonb,
  created_at timestamptz DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 5. offerwall_wallet_transactions — DADO FINANCEIRO. RLS obrigatória.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.offerwall_wallet_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  conversion_id uuid REFERENCES public.offerwall_conversions(id) ON DELETE SET NULL,
  type text NOT NULL,
  amount numeric NOT NULL,
  currency text DEFAULT 'BRL',
  balance_after numeric,
  description text,
  created_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS offerwall_wallet_user_id_idx
  ON public.offerwall_wallet_transactions(user_id);

-- ============================================================================
-- RLS — aplicada já neste brief (carteira nasce com RLS; demais tabelas
-- também recebem policies mínimas pra que o pattern fique consistente).
-- ============================================================================

-- offerwall_offers: leitura pública apenas de offers ativas
ALTER TABLE public.offerwall_offers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "offers_select_active" ON public.offerwall_offers;
CREATE POLICY "offers_select_active" ON public.offerwall_offers
  FOR SELECT
  USING (status = 'active');

-- offerwall_impressions: INSERT público (landing precisa registrar). SELECT fechado.
ALTER TABLE public.offerwall_impressions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "impressions_insert" ON public.offerwall_impressions;
CREATE POLICY "impressions_insert" ON public.offerwall_impressions
  FOR INSERT
  WITH CHECK (true);

-- offerwall_clicks: INSERT público (plano B do brief — fallback client-side
-- usa esta policy). SELECT fechado.
ALTER TABLE public.offerwall_clicks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "clicks_insert" ON public.offerwall_clicks;
CREATE POLICY "clicks_insert" ON public.offerwall_clicks
  FOR INSERT
  WITH CHECK (true);

-- offerwall_conversions: nenhuma policy de cliente. Só server-side (secret key).
ALTER TABLE public.offerwall_conversions ENABLE ROW LEVEL SECURITY;

-- offerwall_wallet_transactions: usuário só vê o próprio saldo. SEM policy de
-- escrita — qualquer crédito vem do Brief 2 via Edge Function com Secret key.
ALTER TABLE public.offerwall_wallet_transactions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "wallet_select_own" ON public.offerwall_wallet_transactions;
CREATE POLICY "wallet_select_own" ON public.offerwall_wallet_transactions
  FOR SELECT
  USING (auth.uid() = user_id);

-- ============================================================================
-- Seed — 4 offers fictícias com status='active' pra teste visual.
-- UUIDs fixos pra idempotência (rodar 2x não duplica).
-- ============================================================================

INSERT INTO public.offerwall_offers
  (id, name, description, advertiser_name, network_name, preview_url,
   tracking_link_template, payout_amount, payout_currency,
   reward_amount, reward_currency, creative_image_url, status, priority)
VALUES
  (
    '11111111-1111-1111-1111-111111111111',
    'Instale o Free Fire e ganhe',
    'Baixe o app, complete o tutorial e ganhe seu crédito.',
    'Garena',
    'placeholder-network',
    'https://example.com/preview/freefire',
    NULL,
    1.20, 'USD',
    5.00, 'BRL',
    'https://picsum.photos/seed/freefire/600/300',
    'active', 100
  ),
  (
    '22222222-2222-2222-2222-222222222222',
    'Cadastre-se no app de fintech',
    'Crie sua conta, faça o primeiro depósito e ganhe.',
    'Banco XYZ',
    'placeholder-network',
    'https://example.com/preview/fintech',
    NULL,
    2.50, 'USD',
    10.00, 'BRL',
    'https://picsum.photos/seed/fintech/600/300',
    'active', 90
  ),
  (
    '33333333-3333-3333-3333-333333333333',
    'Jogue Genshin Impact por 7 dias',
    'Atinja o nível 10 da aventura nos primeiros 7 dias.',
    'HoYoverse',
    'placeholder-network',
    'https://example.com/preview/genshin',
    NULL,
    3.00, 'USD',
    12.00, 'BRL',
    'https://picsum.photos/seed/genshin/600/300',
    'active', 80
  ),
  (
    '44444444-4444-4444-4444-444444444444',
    'Assista 5 vídeos no app parceiro',
    'Curto e simples — 5 vídeos, crédito na carteira.',
    'StreamCo',
    'placeholder-network',
    'https://example.com/preview/streamco',
    NULL,
    0.40, 'USD',
    1.50, 'BRL',
    'https://picsum.photos/seed/streamco/600/300',
    'active', 70
  )
ON CONFLICT (id) DO NOTHING;

-- ============================================================================
-- Verificação rápida (opcional — descomenta pra rodar manualmente)
-- ============================================================================
-- SELECT count(*) AS offers FROM public.offerwall_offers WHERE status = 'active';
-- SELECT count(*) AS impressions FROM public.offerwall_impressions;
-- SELECT count(*) AS clicks FROM public.offerwall_clicks;
-- SELECT count(*) AS conversions FROM public.offerwall_conversions;
-- SELECT count(*) AS wallet_tx FROM public.offerwall_wallet_transactions;

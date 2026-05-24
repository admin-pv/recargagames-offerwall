// Edge Function do Netlify — Click tracker do Offerwall
// Roda na borda do CDN antes de redirecionar pra rede de afiliados.
//
// Fluxo (POST /click):
//   1. Lê offer_id + access_token do body (form-urlencoded)
//   2. Valida o access_token via Supabase Auth → obtém user_id
//   3. Carrega a offer (status='active') via Supabase REST
//   4. Gera click_id UUID
//   5. INSERT em offerwall_clicks (com Secret key, RLS bypass)
//   6. Constrói URL de destino (substitui {click_id} no template; fallback pra preview_url)
//   7. Retorna 302 pro browser seguir
//
// Env vars (configurar no painel Netlify do site recargagames-offerwall):
//   SUPABASE_URL          — https://ashmirzgyuhspymldpfv.supabase.co
//   SUPABASE_SECRET_KEY   — sb_secret_... (NÃO commitar)

import type { Context, Config } from "https://edge.netlify.com/";

const REQUIRED_ENV = ["SUPABASE_URL", "SUPABASE_SECRET_KEY"] as const;

// Publishable key (sb_publishable_...) — pública por design, mesma usada no
// index.html. Necessária como `apikey` nas rotas /auth/v1/* do Supabase:
// o GoTrue exige a publishable key pra identificar o projeto nessas rotas;
// a secret key não é aceita como apikey de auth (resulta em 401).
// O Bearer continua sendo o access_token do usuário.
const SUPABASE_PUBLISHABLE_KEY = "sb_publishable_rGZqf4_vv2XzF4N3wZUwEg_rVoZUV_j";

function deviceTypeFromUA(ua: string | null): string | null {
  if (!ua) return null;
  if (/iPad|Tablet/i.test(ua)) return "tablet";
  if (/Mobi|Android|iPhone/i.test(ua)) return "mobile";
  return "desktop";
}

async function readParams(req: Request): Promise<{ offer_id: string; access_token: string }> {
  const ct = req.headers.get("content-type") || "";
  if (ct.includes("application/x-www-form-urlencoded") || ct.includes("multipart/form-data")) {
    const fd = await req.formData();
    return {
      offer_id: String(fd.get("offer_id") || ""),
      access_token: String(fd.get("access_token") || ""),
    };
  }
  // Fallback JSON (útil pra testes via curl)
  const body = await req.json().catch(() => ({} as Record<string, string>));
  return {
    offer_id: String(body.offer_id || ""),
    access_token: String(body.access_token || ""),
  };
}

export default async (req: Request, ctx: Context): Promise<Response> => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  for (const k of REQUIRED_ENV) {
    if (!Deno.env.get(k)) {
      console.error(`Missing env var: ${k}`);
      return new Response("Server misconfigured", { status: 500 });
    }
  }
  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!.trim().replace(/\/+$/, "");
  const SUPABASE_SECRET_KEY = Deno.env.get("SUPABASE_SECRET_KEY")!.trim();

  const { offer_id, access_token } = await readParams(req);
  if (!offer_id || !access_token) {
    return new Response("Missing offer_id or access_token", { status: 400 });
  }

  // 1. Valida JWT → user_id
  // apikey = publishable key (rota de auth do GoTrue exige), Bearer = JWT do usuário
  const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: {
      Authorization: `Bearer ${access_token}`,
      apikey: SUPABASE_PUBLISHABLE_KEY,
    },
  });
  if (!userRes.ok) {
    const body = await userRes.text().catch(() => "");
    console.error("auth/v1/user failed:", userRes.status, body);
    return new Response("Unauthorized", { status: 401 });
  }
  const user = await userRes.json();
  const user_id = user?.id;
  if (!user_id) {
    console.error("auth/v1/user returned no id:", JSON.stringify(user));
    return new Response("Unauthorized", { status: 401 });
  }

  // 2. Carrega a offer (precisa secret pra ler offers não-ativas? não — só active mesmo)
  const offerRes = await fetch(
    `${SUPABASE_URL}/rest/v1/offerwall_offers?id=eq.${encodeURIComponent(offer_id)}&select=id,preview_url,tracking_link_template,status`,
    {
      headers: {
        apikey: SUPABASE_SECRET_KEY,
        Authorization: `Bearer ${SUPABASE_SECRET_KEY}`,
      },
    }
  );
  if (!offerRes.ok) {
    console.error("Offer fetch failed:", offerRes.status, await offerRes.text());
    return new Response("Offer fetch failed", { status: 500 });
  }
  const offers = (await offerRes.json()) as Array<{
    id: string; preview_url: string | null; tracking_link_template: string | null; status: string;
  }>;
  const offer = offers[0];
  if (!offer) {
    return new Response("Offer not found", { status: 404 });
  }
  if (offer.status !== "active") {
    return new Response("Offer not available", { status: 410 });
  }

  // 3. Gera click_id e monta URL final
  const click_id = crypto.randomUUID();
  const template = (offer.tracking_link_template || "").trim();
  const redirected_to = template
    ? template.replace(/\{click_id\}/g, click_id)
    : offer.preview_url || "";

  if (!redirected_to) {
    console.error("Offer has neither tracking_link_template nor preview_url:", offer_id);
    return new Response("Offer has no destination configured", { status: 500 });
  }

  // 4. Contexto da request (IP/geo do Netlify, UA do header)
  const ua = req.headers.get("user-agent");
  const ip = ctx.ip || req.headers.get("x-nf-client-connection-ip") || null;
  const country = ctx.geo?.country?.code || null;

  // 5. INSERT em offerwall_clicks (com Secret, RLS bypass — user_id já validado acima)
  const insertRes = await fetch(`${SUPABASE_URL}/rest/v1/offerwall_clicks`, {
    method: "POST",
    headers: {
      apikey: SUPABASE_SECRET_KEY,
      Authorization: `Bearer ${SUPABASE_SECRET_KEY}`,
      "Content-Type": "application/json",
      Prefer: "return=minimal",
    },
    body: JSON.stringify({
      click_id,
      offer_id,
      user_id,
      is_guest: false,
      ip_address: ip,
      country,
      user_agent: ua,
      device_type: deviceTypeFromUA(ua),
      redirected_to,
    }),
  });
  if (!insertRes.ok) {
    console.error("Click insert failed:", insertRes.status, await insertRes.text());
    return new Response("Click log failed", { status: 500 });
  }

  // 6. Redireciona
  return new Response(null, {
    status: 302,
    headers: {
      Location: redirected_to,
      "Cache-Control": "no-store",
    },
  });
};

export const config: Config = {
  path: "/click",
};

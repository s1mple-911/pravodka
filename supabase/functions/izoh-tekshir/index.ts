// =====================================================================
//  Provodka — izoh-tekshir (Supabase Edge Function)
//  Repo: pravodka · project: kxzerccdpcltmzrxutlo
// ---------------------------------------------------------------------
//  Vazifasi: CHIQIM yozuvining IZOHI tanlangan XARAJAT MODDASIGA mantiqan
//  mos-nomosligini Claude bilan aniqlash ("benzin" izohi "Oziq-ovqat"
//  moddasiga tushib qolmadimi). Jurnal (admin) uchun — natija entry
//  jadvalida saqlanadi (izoh_mos/izoh_sabab/izoh_tekshir_at), har yozuv
//  BIR MARTA tekshiriladi. TEZ va ARZON: Haiku, thinking YO'Q,
//  tool_choice bilan javob MAJBURIY strukturali, ≤20 yozuv BITTA so'rovda.
//
//  🔴 `ai-chat`/`rasm-detect` bilan BIR XIL xavfsizlik qatlamlari (CLAUDE.md):
//     CORS allowlist, `{data,error}` HAR DOIM tekshiriladi,
//     `temperature/top_p/top_k/budget_tokens` ISHLATILMAYDI,
//     ruxsat FAIL-CLOSED (har qanday RPC xatosi = rad).
//  🔴 FAQAT ADMIN (`my_perms().is_admin === true`) — AI xulosasi ustuni
//     jurnalda faqat adminga ko'rinadi, tekshiruv ham faqat unga.
//  🔴 SERVICE_ROLE UMUMAN ISHLATILMAYDI: yozish `izoh_tekshir_yoz` RPC
//     orqali FOYDALANUVCHI JWT si bilan — RPC ichida ham admin tekshiruvi
//     bor (PROVODKA_IZOH_TEKSHIR.sql), ikki qavat.
//  🔴 Claude'ga FAQAT mijoz yuborgan {izoh, modda} juftliklari ketadi —
//     EF hech qanday Provodka jadvalini O'QIMAYDI (`.from(` yo'q).
// =====================================================================

import Anthropic from "npm:@anthropic-ai/sdk@^0.110.0";
import { createClient } from "npm:@supabase/supabase-js@2.110.6";

// ---------------------------------------------------------------------
//  Sozlamalar
// ---------------------------------------------------------------------

// Arzon model — bu ha/yo'q tasnifi, Sonnet shart emas. Env bilan almashadi.
const MODEL = (Deno.env.get("AI_MODEL_IZOH") || "").trim() || "claude-haiku-4-5-20251001";

// 20 ta yozuv × qisqa verdict — 1500 token yetarli (erkin matn yozilmaydi).
const MAX_TOKENS = 1500;

const ITEMS_MAX = 20;      // bitta so'rovda nechta yozuv
const IZOH_MAX = 400;      // belgida
const MODDA_MAX = 160;
const SABab_MAX = 200;     // AI sababi qirqiladi (DB shishmasin)

const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

// Tezlik chegarasi — foydalanuvchi bo'yicha, isolate XOTIRASIDA
// (`ai-chat` bilan bir xil naqsh — qat'iy kafolat emas, narx nazorati).
const RL_WINDOW_MS = 60_000;
const RL_MAX_HITS = 6;     // 6 × 20 yozuv/daqiqa — jurnal sahifalashiga yetarli
const RL_MAP_MAX = 500;
const rlHits = new Map<string, number[]>();

function rateLimited(userId: string): boolean {
  const now = Date.now();
  if (rlHits.size > RL_MAP_MAX) rlHits.clear();
  const arr = (rlHits.get(userId) || []).filter((t) => now - t < RL_WINDOW_MS);
  if (arr.length >= RL_MAX_HITS) { rlHits.set(userId, arr); return true; }
  arr.push(now);
  rlHits.set(userId, arr);
  return false;
}

// CORS — allowlist, `*` ATAYLAB YO'Q (endpoint pul turadi). `ai-chat` bilan bir xil.
const DEFAULT_ORIGINS = [
  "https://s1mple-911.github.io",
  "https://pravodka.com",
  "https://www.pravodka.com",
];
const ENV_ORIGINS = (Deno.env.get("AI_ALLOWED_ORIGINS") || "")
  .split(",").map((s) => s.trim()).filter(Boolean);
const ALLOW_ORIGINS = [...DEFAULT_ORIGINS, ...ENV_ORIGINS];
const LOCAL_RE = /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/;

function originOk(origin: string | null): boolean {
  if (!origin) return true;
  if (LOCAL_RE.test(origin)) return true;
  return ALLOW_ORIGINS.includes(origin);
}
function corsHeaders(origin: string | null): Record<string, string> {
  if (!origin || !originOk(origin)) return {};
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin",
  };
}
function json(body: unknown, status: number, origin: string | null): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders(origin) },
  });
}
function fail(status: number, code: string, message: string, origin: string | null): Response {
  return json({ error: message, code }, status, origin);
}

// ---------------------------------------------------------------------
//  Claude asbobi — javob MAJBURIY strukturali
// ---------------------------------------------------------------------

const IZOH_TOOL = {
  name: "izoh_verdikt",
  description: "Har bir yozuv uchun izoh xarajat moddasiga mos yoki nomosligi.",
  input_schema: {
    type: "object",
    properties: {
      natija: {
        type: "array",
        items: {
          type: "object",
          properties: {
            id: { type: "string", description: "Yozuv id'si — so'rovdagi bilan AYNAN bir xil." },
            mos: { type: ["boolean", "null"], description: "true=mos, false=ANIQ zid, null=aniqlab bo'lmaydi." },
            sabab: { type: ["string", "null"], description: "mos=false bo'lsa qisqa o'zbekcha sabab (≤120 belgi), aks holda null." },
          },
          required: ["id", "mos", "sabab"],
        },
      },
    },
    required: ["natija"],
  },
} as const;

const SYSTEM =
  "Sen ichki buxgalteriya nazoratchisisan. Har bir yozuvda hodim yozgan IZOH " +
  "tanlangan XARAJAT MODDASIGA mantiqan mos kelishini tekshirasan.\n" +
  "Qoidalar:\n" +
  "1. mos=false FAQAT ANIQ ziddiyatda: izoh boshqa turdagi xarajatni ochiq aytsa " +
  "(masalan izoh 'benzin quydik', modda 'Oziq-ovqat'). Shubha yetarli EMAS.\n" +
  "2. Umumiy/neytral izoh ('to'lov', 'ofis uchun', ism-familiya, sana) — mos=null " +
  "(aniqlab bo'lmaydi). null ni ko'p ishlatishdan qo'rqma — yolg'on qizil belgi " +
  "yolg'on tinchlikdan yomonroq.\n" +
  "3. Izoh moddani tasdiqlasa yoki unga tabiiy tegishli bo'lsa — mos=true.\n" +
  "4. sabab — faqat mos=false bo'lganda, qisqa o'zbekcha (lotin), ≤120 belgi.\n" +
  "5. Har so'ralgan id uchun ROPPA-ROSA bitta natija qaytar, id'ni o'zgartirma.";

// ---------------------------------------------------------------------
//  Kiritma validatsiyasi
// ---------------------------------------------------------------------

type Item = { id: string; izoh: string; modda: string };

function parseItems(body: unknown): Item[] | { err: string } {
  const items = (body as { items?: unknown })?.items;
  if (!Array.isArray(items) || !items.length) return { err: "items massivi kerak." };
  if (items.length > ITEMS_MAX) return { err: `Ko'pi bilan ${ITEMS_MAX} ta yozuv.` };
  const out: Item[] = [];
  const seen = new Set<string>();
  for (const raw of items) {
    const it = raw as Record<string, unknown>;
    const id = typeof it.id === "string" ? it.id : "";
    const izoh = typeof it.izoh === "string" ? it.izoh.trim() : "";
    const modda = typeof it.modda === "string" ? it.modda.trim() : "";
    if (!UUID_RE.test(id)) return { err: "id UUID emas." };
    if (seen.has(id)) continue;                       // dublikat jim tashlanadi
    if (!izoh || izoh.length > IZOH_MAX) return { err: "izoh bo'sh yoki juda uzun." };
    if (!modda || modda.length > MODDA_MAX) return { err: "modda bo'sh yoki juda uzun." };
    seen.add(id);
    out.push({ id, izoh, modda });
  }
  return out.length ? out : { err: "items bo'sh." };
}

// ---------------------------------------------------------------------
//  Kirish nuqtasi
// ---------------------------------------------------------------------

Deno.serve(async (req) => {
  const origin = req.headers.get("Origin");

  if (req.method === "OPTIONS") {
    return new Response(null, { status: originOk(origin) ? 204 : 403, headers: corsHeaders(origin) });
  }
  if (req.method !== "POST") return fail(405, "method", "Faqat POST.", origin);
  if (origin && !originOk(origin)) return fail(403, "origin", "Ruxsatsiz manba.", origin);

  const apiKey = (Deno.env.get("ANTHROPIC_API_KEY") || "").trim();
  if (!apiKey) {
    console.error("izoh-tekshir: ANTHROPIC_API_KEY yo'q");
    return fail(500, "config", "AI xizmati sozlanmagan.", origin);
  }

  // --- Auth: anon key + foydalanuvchi Authorization headeri (service_role EMAS) ---
  const authHeader = req.headers.get("Authorization") || "";
  const token = authHeader.replace(/^Bearer\s+/i, "").trim();
  if (!token) return fail(401, "no_auth", "Avtorizatsiya kerak. Qaytadan kiring.", origin);

  const supaUrl = Deno.env.get("SUPABASE_URL") || "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") || "";
  const sb = createClient(supaUrl, anonKey, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });

  const { data: userData, error: userErr } = await sb.auth.getUser(token);
  const userId = userData?.user?.id || "";
  if (userErr || !userId) {
    console.error("izoh-tekshir: getUser xato:", userErr?.message || "user yo'q");
    return fail(401, "auth", "Sessiya yaroqsiz. Qaytadan kiring.", origin);
  }

  // --- Ruxsat: FAQAT admin, FAIL-CLOSED (har qanday xato = rad) ---
  const permRes = await sb.rpc("my_perms");
  if (permRes.error) {
    console.error("izoh-tekshir: my_perms xato:", permRes.error.message);
    return fail(403, "perm", "Ruxsat tekshirilmadi.", origin);
  }
  const perms = permRes.data as { is_admin?: unknown } | null;
  if (!perms || perms.is_admin !== true) {
    return fail(403, "perm", "Bu amal faqat admin uchun.", origin);
  }

  if (rateLimited(userId)) return fail(429, "rate", "Juda tez. Bir daqiqadan so'ng urinib ko'ring.", origin);

  // --- Kiritma ---
  let body: unknown;
  try { body = await req.json(); } catch { return fail(400, "bad_json", "JSON o'qilmadi.", origin); }
  const parsed = parseItems(body);
  if ("err" in parsed) return fail(400, "bad_input", parsed.err, origin);
  const items = parsed;

  // --- Claude — bitta so'rov, tool_choice bilan struktura MAJBURIY ---
  const anthropic = new Anthropic({ apiKey, timeout: 20_000, maxRetries: 0 });
  const userText =
    "Quyidagi yozuvlarni tekshir (JSON):\n" +
    JSON.stringify(items.map((it) => ({ id: it.id, izoh: it.izoh, modda: it.modda }))) +
    "\nAsbob bilan strukturali javob ber.";

  let natijaRaw: unknown = null;
  const t0 = Date.now();
  try {
    const resp = await anthropic.messages.create({
      model: MODEL,
      max_tokens: MAX_TOKENS,
      system: SYSTEM,
      // 🔴 `thinking` maydoni UMUMAN BERILMAYDI; `temperature`/`top_p`/`top_k` ham.
      tools: [IZOH_TOOL as unknown as Record<string, unknown>],
      tool_choice: { type: "tool", name: IZOH_TOOL.name },
      messages: [{ role: "user", content: userText }],
    } as never);
    console.log("izoh-tekshir: Claude javob", items.length, "ta ·", Date.now() - t0, "ms");
    const blocks = (resp as { content?: Array<Record<string, unknown>> }).content || [];
    const tu = blocks.find((b) => b.type === "tool_use" && b.name === IZOH_TOOL.name);
    natijaRaw = (tu?.input as { natija?: unknown })?.natija;
  } catch (e) {
    console.error("izoh-tekshir: Anthropic xato:", (e as { message?: string })?.message || String(e), "·", Date.now() - t0, "ms");
    return fail(502, "upstream", "AI javob bermadi. Keyinroq urinib ko'ring.", origin);
  }
  if (!Array.isArray(natijaRaw)) {
    console.error("izoh-tekshir: tool_use natija massiv emas");
    return fail(502, "upstream", "AI strukturali javob bermadi.", origin);
  }

  // --- Natijani tozalash: faqat SO'RALGAN id'lar, shakl qat'iy ---
  const askedIds = new Set(items.map((it) => it.id));
  const natija: Array<{ id: string; mos: boolean | null; sabab: string | null }> = [];
  for (const raw of natijaRaw) {
    const r = raw as Record<string, unknown>;
    const id = typeof r.id === "string" ? r.id : "";
    if (!askedIds.has(id)) continue;                  // model o'ylab topgan id tashlanadi
    askedIds.delete(id);                              // bitta id = bitta verdict
    const mos = r.mos === true ? true : r.mos === false ? false : null;
    let sabab = typeof r.sabab === "string" ? r.sabab.trim().slice(0, SABab_MAX) : null;
    if (mos !== false) sabab = null;                  // sabab faqat nomoslikda saqlanadi
    natija.push({ id, mos, sabab });
  }
  // Model javob bermagan id'lar ham "urinildi" deb yoziladi (mos=null) —
  // aks holda ular har jurnal ochilishida qayta-qayta EF'ga kelaverardi.
  for (const id of askedIds) natija.push({ id, mos: null, sabab: null });

  // --- DB'ga yozish: foydalanuvchi JWT si bilan RPC (ichida ham admin tekshiruvi) ---
  let yozildi = 0;
  for (const n of natija) {
    const { error } = await sb.rpc("izoh_tekshir_yoz", { p_entry: n.id, p_mos: n.mos, p_sabab: n.sabab });
    if (error) {
      // SQL hali RUN qilinmagan (42883) yoki boshqa xato — natija baribir qaytadi,
      // klient ko'rsatadi; keyingi yuklashda qayta uriniladi. Xom xato mijozga BERILMAYDI.
      console.error("izoh-tekshir: izoh_tekshir_yoz xato:", n.id.slice(0, 8), error.code || "-", error.message);
    } else yozildi++;
  }

  return json({ ok: true, natija, yozildi }, 200, origin);
});

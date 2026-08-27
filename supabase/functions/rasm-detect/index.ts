// =====================================================================
//  Provodka — rasm-detect (Supabase Edge Function)
//  Repo: pravodka · project: kxzerccdpcltmzrxutlo
// ---------------------------------------------------------------------
//  Vazifasi: chek yoki spidometr rasmidan Claude Vision bilan STRUKTURALI
//  natija olish ({summa,sana,...} yoki {km,...}) — hodim formani qo'lda
//  to'ldirish o'rniga rasm yuklaydi. TEZ va ARZON bo'lishi shart:
//  thinking YO'Q, `max_tokens:500`, `tool_choice` bilan javob MAJBURIY
//  strukturali (model erkin matn yozib o'tirmaydi).
//
//  🔴 Bu EF `ai-chat` bilan BIR XIL xavfsizlik qatlamlariga amal qiladi
//     (CLAUDE.md): CORS allowlist, `{data,error}` HAR DOIM tekshiriladi,
//     `temperature/top_p/top_k/budget_tokens` ISHLATILMAYDI,
//     ruxsat FAIL-CLOSED (xato = rad javob, "shubhada o'tkazish" yo'q).
//
//  🔴 IKKI XIL SUPABASE KLIENT, ATAYLAB:
//     (a) `sb`     — ANON key + foydalanuvchi Authorization headeri.
//                    Auth (`getUser`) va ruxsat (`my_perms`) FAQAT shu bilan —
//                    aks holda `auth.uid()` null bo'lib fail-closed mantiq
//                    ma'nosini yo'qotadi (`ai-chat` dagi bir xil ogohlantirish).
//     (b) `admin`  — SERVICE_ROLE. FAQAT audit yozuvi (`rasm_tahlil` insert),
//                    kunlik hisoblagich COUNT va Storage yuklash uchun — bu
//                    RLS'ni ATAYLAB chetlab o'tadigan ikkita operatsiya
//                    (hodim o'z audit yozuvini o'zgartira olmasligi kerak).
//                    Claude ga yuboriladigan HECH QANDAY Provodka jadvali
//                    bu klient bilan o'QILMAYDI.
// =====================================================================

import Anthropic from "npm:@anthropic-ai/sdk@^0.110.0";
import { createClient } from "npm:@supabase/supabase-js@2.110.6";

// ---------------------------------------------------------------------
//  Sozlamalar
// ---------------------------------------------------------------------

// `ai-chat` bilan bir xil sukut — model kodni o'zgartirmasdan almashadi.
const MODEL = (Deno.env.get("AI_MODEL") || "").trim() || "claude-sonnet-5";

// Tez/arzon javob — thinking YO'Q, tool_choice bilan struktura MAJBURIY,
// shuning uchun 500 token yetarli (erkin matn yozilmaydi).
const MAX_TOKENS = 500;

// Bitta rasm, ≤2 MB BASE64 (klient 1024px JPEG 0.75 bilan kichraytiradi).
const IMG_MEDIA = ["image/jpeg", "image/png", "image/webp"];
const IMG_B64_MAX = 2 * 1024 * 1024;
const B64_RE = /^[A-Za-z0-9+/]+={0,2}$/;

// Kontekst matn maydonlari (modda_nomi/mashina_nomi) — erkin, lekin qisqa.
const CTX_TEXT_MAX = 200;

const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

// Tezlik chegarasi — foydalanuvchi bo'yicha, isolate XOTIRASIDA (`ai-chat`
// bilan bir xil naqsh, qat'iy kafolat emas — bu narxni ushlab turish).
const RL_WINDOW_MS = 60_000;
const RL_MAX_HITS = 20;
const RL_MAP_MAX = 500;
const rlHits = new Map<string, number[]>();

/* 🔴 KUNLIK CHEGARA — BUTUN KOMPANIYA bo'yicha (foydalanuvchi bo'yicha EMAS).
   Sabab: bu narx qorovuli — Claude Vision so'rovlari yig'indisi, bitta
   foydalanuvchining bir kunlik cheki emas (u allaqachon RL_MAX_HITS bilan
   cheklangan). `rasm_tahlil` dan BUGUNGI (Toshkent kuni) qatorlar soni,
   service_role bilan (RLS'siz — hamma foydalanuvchi qatori sanaladi). */
const RASM_KUN_MAX = (() => {
  const raw = parseInt((Deno.env.get("RASM_KUN_MAX") || "").trim(), 10);
  return Number.isFinite(raw) && raw > 0 ? raw : 300;   // kompaniya bo'yicha kunlik chegara (~$1.5/kun, ~$20/oy 4000 rasm)
})();

// CORS — `ai-chat` bilan BIR XIL allowlist manbasi (bitta secret ikkalasiga
// ham tegishli: `AI_ALLOWED_ORIGINS`).
const DEFAULT_ORIGINS = [
  "https://s1mple-911.github.io",
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
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type",
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

// Xato javobi — xom Anthropic/Postgres matni HECH QACHON bu yerga tushmaydi
// (faqat `console.error`).
function fail(status: number, code: string, message: string, origin: string | null): Response {
  return json({ ok: false, error: message, code }, status, origin);
}

// ---------------------------------------------------------------------
//  Tool sxemalari — javob MAJBURIY shu shaklda (`tool_choice`)
// ---------------------------------------------------------------------

const CHEK_MUAMMO = ["xira", "kesilgan", "chek_emas", "bir_nechta", "qolda_yozilgan"];
const SPIDO_MUAMMO = ["xira", "trip_korsatilgan", "yoritish", "qisman"];

const CHEK_TOOL = {
  name: "chek_natija",
  description: "O'zbekiston savdo chekidan o'qilgan struktura natijasi.",
  input_schema: {
    type: "object",
    properties: {
      summa: { type: ["integer", "null"], description: "Xaridor to'lagan YAKUNIY summa, butun son." },
      valyuta: { type: ["string", "null"], enum: ["UZS", "USD", null] },
      sana: { type: ["string", "null"], description: "Chekdagi sana, YYYY-MM-DD. Ko'rinmasa null." },
      vaqt: { type: ["string", "null"] },
      savdo_nuqtasi: { type: ["string", "null"] },
      chek_raqami: { type: ["string", "null"] },
      tolov_turi: { type: "string", enum: ["naqd", "karta", "nomalum"] },
      summa_manba: { type: "string", enum: ["itogo", "jami", "k_oplate", "hisoblangan", "noaniq"] },
      ishonch: { type: "number", description: "0 dan 1 gacha." },
      muammo: { type: ["string", "null"], description: "Muammo tegi(lari) vergul bilan (masalan: 'xira, bir_nechta'), yoki muammo bolmasa bosh satr/null. Ruxsat etilgan teglar: " + CHEK_MUAMMO.join(", ") + "." },
      izoh: { type: "string" },
    },
    required: [
      "summa", "valyuta", "sana", "vaqt", "savdo_nuqtasi", "chek_raqami",
      "tolov_turi", "summa_manba", "ishonch", "muammo", "izoh",
    ],
    additionalProperties: false,
  },
};

const SPIDO_TOOL = {
  name: "spidometr_natija",
  description: "Spidometr (odometr) rasmidan o'qilgan struktura natijasi.",
  input_schema: {
    type: "object",
    properties: {
      km: { type: ["integer", "null"], description: "UMUMIY odometr (ODO), TRIP EMAS." },
      birlik: { type: "string", enum: ["km", "mil"] },
      raqam_turi: { type: "string", enum: ["odo", "trip", "noaniq"] },
      ishonch: { type: "number" },
      muammo: { type: ["string", "null"], description: "Muammo tegi(lari) vergul bilan, yoki muammo bolmasa bosh satr/null. Ruxsat etilgan teglar: " + SPIDO_MUAMMO.join(", ") + "." },
      izoh: { type: "string" },
    },
    required: ["km", "birlik", "raqam_turi", "ishonch", "muammo", "izoh"],
    additionalProperties: false,
  },
};

// ---------------------------------------------------------------------
//  System promptlar
// ---------------------------------------------------------------------

const CHEK_SYSTEM = [
  "Sen O'zbekiston savdo cheklarini o'qiydigan aniq tahlilchisan.",
  "`chek_natija` asbobi bilan JAVOB BER — boshqa hech narsa yozma.",
  "",
  "`summa` — xaridor TO'LAGAN YAKUNIY summa: ИТОГО / JAMI / К ОПЛАТЕ / ВСЕГО /",
  "Jami to'lov (chegirmadan KEYINGI, oxirgi summa).",
  "🔴 BULAR SUMMA EMAS: 'Naqd berildi' / 'Сдача' (qaytim), 'Подытог' (oraliq",
  "jami, chegirmadan OLDIN), QQS/NDS qatori.",
  "Bir nechta chek yoki bir nechta 'yakuniy summa' nomzodi ko'rinsa —",
  "`ishonch` ni PASAYTIR va `muammo` ga `bir_nechta` yoz.",
  "Format: '150 000,00' / '150000.00' / '150.000' — hammasi SO'MDA BUTUN",
  "SON deb o'qi (kasr/tiyin tashlanadi). Dollar chek bo'lsa `valyuta:'USD'`.",
  "`sana` — chekdagi sana, AYNAN `YYYY-MM-DD`. Ko'rinmasa yoki noaniq bo'lsa",
  "`null` — HECH QACHON TAXMIN QILMA (bugungi sana emas, chekning o'zi).",
  "Chek umuman ko'rinmasa yoki boshqa hujjat bo'lsa `muammo` ga `chek_emas`",
  "yoz va `summa:null`.",
  "`muammo` — MATN maydoni (massiv EMAS): muammo bo'lmasa BO'SH SATR yoki",
  "`null`; bo'lsa bitta yoki bir nechta tegni vergul bilan yoz (masalan",
  "'xira, bir_nechta'). Bo'sh/`null` — 'muammo yo'q' degani, aniq() shunga",
  "qarab hisoblanadi — behuda to'ldirma.",
  "`ishonch` — 0 (umuman ishonchsiz) dan 1 (aniq) gacha, real baho ber.",
].join("\n");

const SPIDO_SYSTEM = [
  "Sen avtomobil spidometri (odometr) rasmini o'qiydigan aniq tahlilchisan.",
  "`spidometr_natija` asbobi bilan JAVOB BER — boshqa hech narsa yozma.",
  "",
  "`km` — UMUMIY odometr (ODO): eng katta, 5-7 xonali raqam, mashinaning",
  "umumiy yurgan masofasi. TRIP A / TRIP B (kichik, ko'pincha kasrli, safar",
  "hisoblagichi) EMAS — ular alohida, kichikroq ko'rsatkich.",
  "Barcha xonani (raqamlarning har birini) diqqat bilan ko'chir, birortasini",
  "tashlab ketma yoki qo'shib yozma.",
  "Ko'rsatkich milда bo'lsa `birlik:'mil'`, aks holda `birlik:'km'`.",
  "Faqat TRIP ko'rinsa (ODO ko'rinmasa) — `km:null`, `raqam_turi:'trip'`,",
  "`muammo` ga `trip_korsatilgan` yoz.",
  "Tezlik strelkasi/ko'rsatkichi RAQAM EMAS — uni km deb o'qima.",
  "Rasm qisman kesilgan yoki yoritish yomon bo'lsa mos `muammo` yoz va",
  "ishonchsiz bo'lsa `km:null` qoldir — TAXMIN QILMA.",
  "`muammo` — MATN maydoni (massiv EMAS): muammo bo'lmasa BO'SH SATR yoki",
  "`null`; bo'lsa bitta yoki bir nechta tegni vergul bilan yoz.",
  "`ishonch` — 0 dan 1 gacha, real baho ber.",
].join("\n");

// ---------------------------------------------------------------------
//  Validatsiya yordamchilari
// ---------------------------------------------------------------------

function b64Ok(v: unknown): v is string {
  if (typeof v !== "string" || !v) return false;
  if (v.length > IMG_B64_MAX) return false;
  if (v.length % 4 !== 0) return false;
  return B64_RE.test(v);
}

function stripCtl(v: string): string {
  let out = "";
  for (let i = 0; i < v.length; i++) {
    const c = v.charCodeAt(i);
    out += (c <= 31 || c === 127) ? " " : v[i];
  }
  return out;
}

function cleanCtxText(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const parts = stripCtl(v).split(" ").filter(Boolean);
  if (!parts.length) return null;
  return parts.join(" ").slice(0, CTX_TEXT_MAX);
}

function validDate(s: unknown): string | null {
  if (typeof s !== "string" || !DATE_RE.test(s)) return null;
  const t = Date.parse(s + "T00:00:00Z");
  if (!Number.isFinite(t)) return null;
  return new Date(t).toISOString().slice(0, 10) === s ? s : null;
}

type Body = {
  id: string;
  tur: "chek" | "spidometr";
  image: { media_type: string; data: string };
  kontekst: { modda_nomi: string | null; mashina_nomi: string | null };
};

function validateBody(raw: unknown): { v: Body } | { err: string } {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return { err: "So'rov shakli noto'g'ri." };
  }
  const b = raw as Record<string, unknown>;

  if (typeof b.id !== "string" || !UUID_RE.test(b.id)) {
    return { err: "`id` noto'g'ri (UUID kerak)." };
  }
  if (b.tur !== "chek" && b.tur !== "spidometr") {
    return { err: "`tur` faqat 'chek' yoki 'spidometr' bo'lishi mumkin." };
  }

  const img = b.image;
  if (!img || typeof img !== "object" || Array.isArray(img)) {
    return { err: "Rasm topilmadi." };
  }
  const i = img as Record<string, unknown>;
  // 🔴 `url` manba umuman qabul qilinmaydi — kirishda faqat {media_type,data}
  //    kutiladi, boshqa shakl (masalan `source:{type:'url'}`) shu yerda rad
  //    etiladi (kalit umuman yo'q, `checkBlock` kabi whitelist).
  const media = typeof i.media_type === "string" ? i.media_type.trim().toLowerCase() : "";
  if (!IMG_MEDIA.includes(media)) {
    return { err: "Rasm turi qo'llab-quvvatlanmaydi (JPEG, PNG, WEBP)." };
  }
  if (!b64Ok(i.data)) {
    return { err: "Rasm o'qilmadi yoki juda katta (2 MB gacha)." };
  }

  const ctxRaw = b.kontekst;
  const ctx = (ctxRaw && typeof ctxRaw === "object" && !Array.isArray(ctxRaw))
    ? ctxRaw as Record<string, unknown>
    : {};

  return {
    v: {
      id: b.id,
      tur: b.tur,
      image: { media_type: media, data: i.data as string },
      kontekst: {
        modda_nomi: cleanCtxText(ctx.modda_nomi),
        mashina_nomi: cleanCtxText(ctx.mashina_nomi),
      },
    },
  };
}

// ---------------------------------------------------------------------
//  Tezlik chegarasi
// ---------------------------------------------------------------------

function rateLimited(userId: string): boolean {
  const now = Date.now();
  if (rlHits.size > RL_MAP_MAX) rlHits.clear();
  const arr = (rlHits.get(userId) || []).filter((t) => now - t < RL_WINDOW_MS);
  if (arr.length >= RL_MAX_HITS) {
    rlHits.set(userId, arr);
    return true;
  }
  arr.push(now);
  rlHits.set(userId, arr);
  return false;
}

// Toshkent kuni (UTC+5) boshlanishi — UTC instant sifatida.
// CLAUDE.md: JS tomonda getUTC* bilan hisoblanadi.
function tashkentDayStartUtc(): Date {
  const shifted = new Date(Date.now() + 5 * 3600 * 1000);
  const y = shifted.getUTCFullYear();
  const m = shifted.getUTCMonth();
  const d = shifted.getUTCDate();
  // Tashkent 00:00 = UTC 00:00(shu kun) - 5soat
  return new Date(Date.UTC(y, m, d, 0, 0, 0) - 5 * 3600 * 1000);
}

// ---------------------------------------------------------------------
//  Anthropic xato → o'zbekcha (ai-chat bilan bir xil naqsh, qisqartirilgan)
// ---------------------------------------------------------------------

function errStatus(e: unknown): number | null {
  const s = (e as { status?: unknown } | null)?.status;
  return typeof s === "number" ? s : null;
}

function upstreamMsg(e: unknown): string {
  const st = errStatus(e);
  const detail = (e as { message?: string } | null)?.message || String(e);
  if (st === 429) return "AI xizmati band. Bir oz kutib qayta urinib ko'ring.";
  if (st === null || st === 408 || st === 504) {
    if (/timed?\s*out|timeout/i.test(detail)) {
      return "AI javobi juda uzoq kelmadi. Qaytadan urinib ko'ring yoki formani qo'lda to'ldiring.";
    }
  }
  return "AI rasm tahlilini o'qiy olmadi. Formani qo'lda to'ldiring.";
}

// =====================================================================
//  HANDLER
// =====================================================================

Deno.serve(async (req: Request): Promise<Response> => {
  const origin = req.headers.get("origin");

  // --- 1) CORS preflight -------------------------------------------------
  if (req.method === "OPTIONS") {
    if (!originOk(origin)) return new Response("Forbidden", { status: 403 });
    return new Response(null, { status: 204, headers: corsHeaders(origin) });
  }

  if (!originOk(origin)) {
    console.error("rasm-detect: ruxsatsiz origin:", origin);
    return new Response(
      JSON.stringify({ ok: false, error: "So'rov manbasi ruxsat etilmagan.", code: "origin" }),
      { status: 403, headers: { "Content-Type": "application/json" } },
    );
  }

  if (req.method !== "POST") {
    return fail(405, "method", "Faqat POST so'rov qabul qilinadi.", origin);
  }

  // --- 2) Server sozlamasi (API kaliti) -----------------------------------
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) {
    console.error("rasm-detect: ANTHROPIC_API_KEY secret o'rnatilmagan");
    return fail(500, "no_key", "AI xizmati sozlanmagan. Administratorga xabar bering.", origin);
  }

  // --- 3) Auth: foydalanuvchi JWT si MAJBURIY -----------------------------
  const authHeader = req.headers.get("Authorization") || "";
  if (!/^Bearer\s+\S+/i.test(authHeader)) {
    return fail(401, "no_auth", "Avtorizatsiya kerak. Qaytadan kiring.", origin);
  }

  const supaUrl = Deno.env.get("SUPABASE_URL") || "";
  const anonKey = Deno.env.get("AI_SUPABASE_ANON_KEY")
    || Deno.env.get("SUPABASE_PUBLISHABLE_KEY")
    || Deno.env.get("SUPABASE_ANON_KEY")
    || "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  if (!supaUrl || !anonKey || !serviceKey) {
    console.error("rasm-detect: SUPABASE_URL / ANON / SERVICE_ROLE kaliti topilmadi");
    return fail(500, "no_env", "Server sozlamasi to'liq emas.", origin);
  }

  // (a) Foydalanuvchi JWT'si bilan — auth va ruxsat FAQAT shu bilan.
  const sb = createClient(supaUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });

  const token = authHeader.replace(/^Bearer\s+/i, "").trim();
  const { data: userData, error: userErr } = await sb.auth.getUser(token);
  const user = userData?.user;
  if (userErr || !user) {
    console.error("rasm-detect: getUser xato:", userErr?.message || "user yo'q");
    return fail(401, "auth", "Sessiya yaroqsiz. Qaytadan kiring.", origin);
  }

  // --- 4) Ruxsat: has_provodka yoki is_admin, FAIL-CLOSED -----------------
  const { data: permsData, error: permsErr } = await sb.rpc("my_perms");
  if (permsErr) {
    console.error("rasm-detect: my_perms xato:", permsErr.message);
    return fail(403, "perm", "Ruxsat tekshirilmadi. Administratorga murojaat qiling.", origin);
  }
  const perms = permsData as { is_admin?: unknown; has_provodka?: unknown } | null;
  if (!perms || typeof perms !== "object") {
    console.error("rasm-detect: my_perms noma'lum shakl qaytardi");
    return fail(403, "perm", "Ruxsat tekshirilmadi. Administratorga murojaat qiling.", origin);
  }
  const isAdmin = perms.is_admin === true;
  const hasProvodka = perms.has_provodka === true;
  if (!isAdmin && !hasProvodka) {
    return fail(403, "forbidden", "Sizda Provodka ruxsati yo'q.", origin);
  }

  // --- 5) Tezlik chegarasi (foydalanuvchi) --------------------------------
  if (rateLimited(user.id)) {
    return fail(429, "rate", "Juda ko'p so'rov yuborildi. Bir daqiqadan keyin urinib ko'ring.", origin);
  }

  // (b) SERVICE_ROLE — FAQAT audit/hisob/Storage uchun. Claude ga
  //     yuboriladigan hech narsa bu klient bilan o'qilmaydi.
  const admin = createClient(supaUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });

  // --- 6) Kunlik chegara (butun kompaniya, narx qorovuli) -----------------
  const dayStart = tashkentDayStartUtc();
  const { count: dayCount, error: dayErr } = await admin
    .from("rasm_tahlil")
    .select("id", { count: "exact", head: true })
    .gte("created_at", dayStart.toISOString());
  if (dayErr) {
    // 🔴 Fail-closed emas — bu narx qorovuli, DB o'qish xatosi butun
    //    xizmatni to'xtatmasin. Faqat log.
    console.error("rasm-detect: kunlik hisoblagich xato:", dayErr.message);
  } else if (typeof dayCount === "number" && dayCount >= RASM_KUN_MAX) {
    return fail(429, "kun_limit", "Bugungi rasm tahlili chegarasiga yetildi. Ertaga urinib ko'ring yoki formani qo'lda to'ldiring.", origin);
  }

  // --- 7) Kiritma validatsiyasi --------------------------------------------
  let body: unknown;
  try {
    body = await req.json();
  } catch (_e) {
    return fail(400, "bad_json", "So'rov o'qilmadi.", origin);
  }
  const v = validateBody(body);
  if ("err" in v) return fail(400, "bad_input", v.err, origin);
  const { id, tur, image, kontekst } = v.v;

  // --- 8) Claude — bitta so'rov, tool_choice bilan struktura MAJBURIY -----
  const anthropic = new Anthropic({ apiKey, timeout: 20_000, maxRetries: 0 });

  const isChek = tur === "chek";
  const tool = isChek ? CHEK_TOOL : SPIDO_TOOL;
  const system = isChek ? CHEK_SYSTEM : SPIDO_SYSTEM;

  const ctxLines: string[] = [];
  if (kontekst.modda_nomi) ctxLines.push("Xarajat moddasi: " + kontekst.modda_nomi);
  if (kontekst.mashina_nomi) ctxLines.push("Mashina: " + kontekst.mashina_nomi);
  const userText = (isChek ? "Bu chek rasmi." : "Bu spidometr rasmi.")
    + (ctxLines.length ? "\n" + ctxLines.join("\n") : "")
    + "\nAsbob bilan strukturali javob ber.";

  let toolInput: Record<string, unknown> | null = null;
  let claudeErr: string | null = null;
  let usedModel = MODEL;

  try {
    const resp = await anthropic.messages.create({
      model: MODEL,
      max_tokens: MAX_TOKENS,
      system,
      // 🔴 `thinking` maydoni UMUMAN BERILMAYDI (tez/arzon javob).
      // 🔴 `temperature`/`top_p`/`top_k`/`budget_tokens` ISHLATILMAYDI.
      tools: [tool],
      tool_choice: { type: "tool", name: tool.name },
      messages: [
        {
          role: "user",
          content: [
            { type: "image", source: { type: "base64", media_type: image.media_type, data: image.data } },
            { type: "text", text: userText },
          ],
        },
      ],
    });
    usedModel = (resp as { model?: string }).model || MODEL;
    const blocks = (resp as { content?: Array<Record<string, unknown>> }).content || [];
    const tu = blocks.find((b) => b.type === "tool_use" && b.name === tool.name);
    if (tu && tu.input && typeof tu.input === "object") {
      toolInput = tu.input as Record<string, unknown>;
    } else {
      console.error("rasm-detect: tool_use topilmadi, stop_reason:", (resp as { stop_reason?: unknown }).stop_reason);
      claudeErr = "AI strukturali javob bermadi.";
    }
  } catch (e) {
    console.error("rasm-detect: Anthropic xato:", (e as { message?: string })?.message || String(e));
    claudeErr = upstreamMsg(e);
  }

  // --- 9) Natijani hisoblash + DB yozish ------------------------------------
  let holat: "ok" | "chek_emas" | "xato" = "ok";
  let aiSumma: number | null = null;
  let aiSana: string | null = null;
  let aiKm: number | null = null;
  let ishonch: number | null = null;
  let aniq = false;
  let natijaOut: Record<string, unknown> | null = null;

  if (claudeErr || !toolInput) {
    holat = "xato";
  } else {
    // 🔴 `muammo` — PROVODKA_RASM_DETECT.sql dagi `trg_rasm_tahlil_aniq_fn()`
    //    `natija->>'muammo'` ni TEXT sifatida o'qiydi (massiv EMAS): bo'sh
    //    massiv `->>` bilan "[]" matniga aylanib, "muammo bor" deb noto'g'ri
    //    hisoblanardi. Shuning uchun bu yerda ham QAT'IY string|null sifatida
    //    ishlatiladi va `natijaOut` ga string holida yoziladi (trigger bilan
    //    bir xil manba — DB "ishonchli manba" bo'lib qoladi).
    const muammoRaw = toolInput.muammo;
    const muammo = typeof muammoRaw === "string" ? muammoRaw.trim() : "";
    natijaOut = { ...toolInput, muammo: muammo || null };

    ishonch = typeof toolInput.ishonch === "number" && Number.isFinite(toolInput.ishonch)
      ? Math.max(0, Math.min(1, toolInput.ishonch))
      : null;

    if (isChek) {
      if (muammo.includes("chek_emas")) holat = "chek_emas";
      const summaRaw = toolInput.summa;
      const summaNum = (typeof summaRaw === "number" && Number.isFinite(summaRaw) && summaRaw >= 0)
        ? Math.round(summaRaw)
        : null;
      const valyuta = typeof toolInput.valyuta === "string" ? toolInput.valyuta : null;
      // `ai_summa` faqat UZS bo'lsa (valyuta null ham UZS deb hisoblanadi —
      // model chek so'mligini har doim yozmasligi mumkin).
      aiSumma = (summaNum !== null && (valyuta === "UZS" || valyuta === null)) ? summaNum : null;
      aiSana = validDate(toolInput.sana);
      aniq = ishonch !== null && ishonch >= 0.7 && !muammo && summaNum !== null;
    } else {
      const kmRaw = toolInput.km;
      aiKm = (typeof kmRaw === "number" && Number.isFinite(kmRaw) && kmRaw >= 0) ? Math.round(kmRaw) : null;
      aniq = ishonch !== null && ishonch >= 0.7 && !muammo && aiKm !== null;
    }
  }

  // Storage'ga yuklash — audit, XATOSI natijani TO'XTATMAYDI (faqat log).
  let storagePath: string | null = null;
  try {
    const bytes = Uint8Array.from(atob(image.data), (c) => c.charCodeAt(0));
    const ext = image.media_type === "image/png" ? "png" : image.media_type === "image/webp" ? "webp" : "jpg";
    const path = user.id + "/" + id + "." + ext;
    const { error: upErr } = await admin.storage
      .from("rasm-tahlil")
      .upload(path, bytes, { contentType: image.media_type, upsert: true });
    if (upErr) {
      console.error("rasm-detect: storage upload xato:", upErr.message);
    } else {
      // 🔴 PROVODKA_RASM_DETECT.sql KONTRAKTI: `storage_path` = '{user_id}/{id}.ext'
      //    — BUCKET NOMI PREFIKS QILIB QO'SHILMAYDI (storage RLS policy ham
      //    aynan shu yo'l shaklini kutadi: `storage.foldername(name)[1]`).
      storagePath = path;
    }
  } catch (e) {
    console.error("rasm-detect: storage upload istisno:", (e as { message?: string })?.message || String(e));
  }

  const { error: insErr } = await admin.from("rasm_tahlil").insert({
    id,
    user_id: user.id,
    tur,
    storage_path: storagePath,
    // 🔴 `natija` ustuni NOT NULL (PROVODKA_RASM_DETECT.sql) — hech qachon
    //    `null` yuborilmaydi, xato holatda bo'sh obyekt yoziladi.
    natija: natijaOut ?? {},
    ai_summa: aiSumma,
    ai_sana: aiSana,
    ai_km: aiKm,
    ishonch,
    aniq,
    model: usedModel,
    holat,
    xato: claudeErr,
  });
  if (insErr) {
    // 🔴 Yozib bo'lmasa ham foydalanuvchi javobsiz qolmaydi — audit
    //    yo'qolishi Claude natijasidan ko'ra kichikroq muammo.
    console.error("rasm-detect: rasm_tahlil insert xato:", insErr.message);
  }

  if (holat === "xato") {
    return json({ ok: false, code: "ai_xato", error: claudeErr || "AI tahlil qila olmadi." }, 200, origin);
  }

  return json({
    ok: true,
    id,
    tur,
    natija: natijaOut,
    aniq,
    ai_summa: aiSumma,
    ai_sana: aiSana,
    ai_km: aiKm,
  }, 200, origin);
});

/* =====================================================================
   Provodka — foydalanuvchi ruxsatlari (klient tomoni) — DEV
   ---------------------------------------------------------------------
   perms.js ning DEV nusxasi. Ochilish sababi (CLAUDE.md qoidasi: perms.js
   dev va prod uchun BITTA fayl, faqat semantika o'zgarsa nusxa ochiladi):

     ESKI (perms.js):  allowed_pages bo'sh = HAMMA sahifa ochiq
     YANGI (bu fayl):  allowed_pages bo'sh = HECH QAYSI sahifa ochiq emas

   Ikkalasi bir vaqtda ishlaydi — baza bitta, my_perms() javobi bir xil,
   farq faqat "bo'sh" ni qanday o'qishda. Promote paytida promote.sh bu
   faylni perms.js ustiga yozadi va o'sha daqiqada prod ham teskari
   semantikaga o'tadi.

   Server: my_perms() RPC (PROVODKA_PAGES_EMPTY.sql).
   Bu fayl FAQAT KO'RINISHNI boshqaradi — haqiqiy to'siq serverdagi
   entry_line trigger va perm_can_convert(). UI yashirish yetarli emas.
   ===================================================================== */
(function () {
  'use strict';

  var KEY = 'prov-perms';
  // Sahifa kalitlari — SQL dagi perm_pages() bilan bir xil bo'lishi shart (17 ta).
  // 'hodim' bu yerda YO'Q va bo'lmasligi kerak: hodim sahifasi hech qachon
  // cheklanmaydi (userlarning ~80% i faqat o'shani ishlatadi).
  var PAGES = ['kassa', 'jurnal', 'professional', 'hisobot', 'balans', 'cashflow',
               'qarzdor', 'filial', 'valyuta', 'konvert', 'sozlama', 'provodka', 'yuklar', 'standart',
               'tannarx', 'ai', 'sorovlar'];
  var HOME  = 'jurnal';           // Provodka'ning bosh bo'limi (login'dan keyingi ish sahifasi)
  // Login/dashboard hub sahifasi. PAGES ichida ATAYLAB yo'q — u ruxsat bilan
  // cheklanmaydi (o'zi ruxsatli bo'limlar ro'yxatini chizadi).
  var INDEX = 'index';
  var AUTH_KEY = 'sb-kxzerccdpcltmzrxutlo-auth-token';   // Supabase sessiya kaliti (localStorage)

  /* Havola qo'shimchasi joriy fayl nomidan olinadi: dev sahifada `-dev.html`,
     prod sahifada `.html`. Shu tufayli bu faylda birorta ham `NAME-dev.html`
     matni yo'q — promote.sh uni oddiy nusxalash bilan perms.js qila oladi va
     prod hech qachon dev sahifaga havola qilib qolmaydi. */
  function suf() { return /-dev\.html$/.test(location.pathname) ? '-dev.html' : '.html'; }
  function hodimUrl() { return 'hodim' + suf(); }
  function indexUrl() { return INDEX + suf(); }

  /* ---- LOGIN GUARD (2026-08-18) ---------------------------------------
     index sahifasi — yagona kirish yuzi (login + dashboard). Sessiya tokeni
     UMUMAN bo'lmasa boshqa sahifani ochish ma'nosiz: Supabase javobini kutib
     turgan bo'sh ekran o'rniga darrov login'ga yuboramiz.

     🔴 Bu QO'SHIMCHA qatlam. Har sahifadagi eski auth gate (boot() +
     getSession() + signOut/reload) FALLBACK sifatida joyida qoladi va
     olib tashlanmaydi — "token bor, lekin yaroqsiz/muddati o'tgan" holatni
     faqat o'sha ushlaydi, bu yerda faqat tokenning BORLIGI tekshiriladi.

     localStorage bloklangan brauzerda (Safari private, korporativ policy)
     getItem istisno tashlaydi — bunday holatda REDIRECT QILMAYMIZ: sahifa
     o'z gate'i bilan ishlayversin (aks holda hech kim kira olmasdi). */
  function loginGuard() {
    try {
      if (page() === INDEX) return;                    // login sahifasining o'zi
      if (localStorage.getItem(AUTH_KEY)) return;      // token bor — tekshiruvni sahifa davom ettiradi
      location.replace(indexUrl());
    } catch (e) { /* localStorage yo'q — jimgina o'tkazamiz */ }
  }
  loginGuard();

  /* Ruxsat MA'LUM BO'LMAGAN holat (RPC hali javob bermagan yoki xato bergan).
     Ataylab OCHIQ: bir martalik tarmoq nosozligi hech kimni sahifadan
     quvib chiqarmasin. Pul harakati baribir server guard bilan to'silgan,
     bu yerda "ochiq" qolish xavfsiz. Yopilish faqat my_perms() javobi
     HAQIQATAN kelganda boshlanadi (loaded=true). */
  var OPEN = { allowed_pages: [], kassa_scope: 'all', view_kassa_ids: [],
               op_kassa_ids: [], can_convert: true,
               filial_scope: 'all', filial_ids: [], is_admin: false, has_provodka: true };

  var P = null;          // joriy ruxsatlar
  var loaded = false;    // my_perms() javobi (yoki keshi) keldimi
  var applied = false;   // nav bir marta yashirilgan

  function arr(x) { return Array.isArray(x) ? x : []; }
  function norm(p) {
    if (!p || typeof p !== 'object') return null;
    var pages = arr(p.allowed_pages);
    return {
      user_id:        p.user_id || null,
      allowed_pages:  pages,
      kassa_scope:    p.kassa_scope === 'list' ? 'list' : 'all',
      view_kassa_ids: arr(p.view_kassa_ids),
      op_kassa_ids:   arr(p.op_kassa_ids),
      can_convert:    p.can_convert !== false,
      filial_scope:   p.filial_scope === 'list' ? 'list' : 'all',
      filial_ids:     arr(p.filial_ids),
      is_admin:       !!p.is_admin,
      // Server bermasa o'zimiz hisoblaymiz — eski my_perms() bilan ham ishlasin
      has_provodka:   typeof p.has_provodka === 'boolean'
                        ? p.has_provodka
                        : (!!p.is_admin || pages.length > 0)
    };
  }
  function setP(p) { P = norm(p) || OPEN; loaded = true; window.PERMS = P; return P; }
  function get() { return P || OPEN; }

  /* Sahifa kaliti: fayl nomi (.html va -dev qo'shimchasisiz). Ildiz "/" -> jurnal.
     `-dev` ni kesish MAJBURIY: aks holda dev nusxaning kaliti 'kassa-dev'
     ko'rinishida chiqardi, u hech qachon allowed_pages ichida bo'lmaydi va
     cheklangan user butun dev muhitidan quvilardi. */
  function page() {
    var f = (location.pathname.split('/').pop() || '').replace('.html', '');
    f = f.replace(/-dev$/, '');
    /* Ildiz "/" endi index.html ni beradi (login + dashboard hub), shuning uchun
       bo'sh nom HOME emas, 'index' kaliti. 'index' PAGES da yo'q => gate() uni
       cheklamaydi (hub o'zi ruxsatli bo'limlarni chizadi) va login guard uni
       o'ziga qayta yo'naltirmaydi. */
    return f || INDEX;
  }

  // ---- kesh (sessiya davomida) ---------------------------------------
  function fromCache() {
    try {
      var r = sessionStorage.getItem(KEY);
      if (r) return setP(JSON.parse(r));
    } catch (e) {}
    return null;
  }
  function toCache(p) { try { sessionStorage.setItem(KEY, JSON.stringify(p)); } catch (e) {} }
  /* Kirish/chiqishda MAJBURIY: sessionStorage reload'dan keyin ham qoladi, aks holda
     yangi foydalanuvchi eskisining ruxsatlari bilan ochilib ketardi. */
  function clear() {
    try { sessionStorage.removeItem(KEY); } catch (e) {}
    P = null; loaded = false; window.PERMS = OPEN;
  }

  /* Ruxsatlarni oladi. Keshda bo'lsa DARROV qaytaradi va fonda yangilaydi;
     yangilangani farq qilsa nav qayta qo'llanadi. Xatoda mavjud kesh saqlanadi. */
  async function load(sb) {
    var had = fromCache();
    if (had) { fetchFresh(sb); return had; }
    return await fetchFresh(sb);
  }
  /* 🔴 QAYTA URINISH (2026-08-18, prod bug) — login'dan KEYINGI birinchi chaqiruv poygasi.
     supabase-js Authorization sarlavhasini `SIGNED_IN` auth hodisasidan yangilaydi va bu
     hodisa ASINXRON keladi. `signInWithPassword` qaytishi bilan darrov `rpc('my_perms')`
     yuborilsa u hali ANON kalit bilan ketadi -> `auth.uid()` null -> xato/bo'sh javob ->
     `loaded` false qolib ketadi -> "yuklanmaguncha ochiq" qoidasi bo'yicha HAMMA sahifa
     ochiq ko'rinadi. Foydalanuvchi F5 bosgach to'g'rilanardi (o'shanda klient token bilan
     ishga tushadi). Shuning uchun xato/bo'sh javobda bir necha marta qayta uriniladi. */
  var RETRY_MS = [250, 600, 1200];
  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  async function fetchFresh(sb, tries) {
    tries = tries || 0;
    var fresh = null;
    try {
      var res = await sb.rpc('my_perms');
      if (!res.error) fresh = norm(res.data);
    } catch (e) { fresh = null; }
    if (!fresh) {
      if (tries < RETRY_MS.length) { await sleep(RETRY_MS[tries]); return fetchFresh(sb, tries + 1); }
      return get();                      // urinishlar tugadi — eski xatti-harakat (ochiq qoladi)
    }
    var changed = JSON.stringify(fresh) !== JSON.stringify(P);
    setP(fresh); toCache(fresh);
    if (changed && applied) { applied = false; gate(); }
    return fresh;
  }

  // ---- sahifalar ------------------------------------------------------
  /* Provodka'ga umuman kirish huquqi bormi (hodim.html bundan mustasno). */
  function hasProvodka() {
    if (!loaded) return true;          // hali noma'lum -> to'smaymiz
    var p = get();
    return p.is_admin || p.has_provodka;
  }
  function pageOk(k) {
    if (!loaded) return true;
    var p = get();
    if (p.is_admin) return true;
    if (PAGES.indexOf(k) < 0) return true;   // ro'yxatga kirmaydigan sahifa (hodim) — erkin
    return p.allowed_pages.indexOf(k) >= 0;  // BO'SH = hech narsa (yangi semantika)
  }
  /* Birinchi ochiq sahifa. Konvert ruxsati yo'q bo'lsa konvert O'TKAZIB YUBORILADI —
     aks holda gate() uni tanlab, foydalanuvchini yana "Ruxsat yo'q" ekraniga olib borardi. */
  function firstAllowed() {
    var p = get();
    if (p.is_admin) return HOME;
    for (var i = 0; i < PAGES.length; i++) {
      var k = PAGES[i];
      if (p.allowed_pages.indexOf(k) < 0) continue;
      if (k === 'konvert' && !p.can_convert) continue;
      return k;
    }
    return null;
  }

  /* Havoladan sahifa kalitini oladi: ".html" va "-dev" qo'shimchasi kesiladi. */
  function hrefKey(a) {
    return (a.getAttribute('href') || '').replace('.html', '').replace(/-dev$/, '');
  }

  /* Nav'dan ruxsatsiz sahifalarni olib tashlaydi (sidebar + bnav + "Ko'proq" sheet).
     Konvert ruxsati yo'q bo'lsa konvert sahifasi ham yashiriladi.
     Hech narsa qolmasa nav butunlay yashiriladi — bo'sh qutib turmasin.
     Chiqish/Mavzu tugmalari `.side-foot` va mobil sarlavhada, ular joyida qoladi. */
  function hideNav() {
    var p = get();
    var links = document.querySelectorAll('.sidebar a[href$=".html"], .bnav a[href$=".html"], .msheet a[href$=".html"]');
    var vis = 0;
    for (var i = 0; i < links.length; i++) {
      var k = hrefKey(links[i]);
      var ok = pageOk(k) && !(k === 'konvert' && !p.can_convert);
      if (ok) { vis++; } else { links[i].style.display = 'none'; }
    }
    // Sheet'dagi hamma havola yashiringan bo'lsa "Ko'proq" tugmasi ham keraksiz
    var sheet = document.querySelector('.msheet');
    if (sheet) {
      var sv = sheet.querySelectorAll('a[href$=".html"]:not([style*="display: none"])');
      if (!sv.length) {
        var more = document.querySelector('.bnav a[onclick*="openMore"]');
        if (more) more.style.display = 'none';
      }
    }
    if (!vis) {
      var sn = document.querySelector('.side-nav');  if (sn) sn.style.display = 'none';
      var bn = document.querySelector('.bnav');      if (bn) bn.style.display = 'none';
    }
  }

  /* Faqat `main` ichini almashtiradi — sidebar/bnav joyida qoladi, foydalanuvchi
     ochiq bo'limga o'ta oladi. (#app ni butunlay tozalash navigatsiyani o'chirardi.) */
  function denyScreen() {
    var app = document.querySelector('#app main.main') || document.getElementById('app');
    if (!app) return;
    var to = firstAllowed();
    var btn = 'display:inline-block;padding:11px 20px;border-radius:11px;' +
              'text-decoration:none;font-weight:600;font-size:14px';
    // Hech qaysi Provodka sahifasi ochiq emas -> matn boshqacha bo'lsin: user
    // "menga xato berdi" deb o'ylamasin, xarajat kiritish uchun yo'l ko'rsatilsin.
    var txt = to
      ? 'Bu bo\'limga kirish huquqingiz yo\'q. Kerak bo\'lsa administratorga murojaat qiling.'
      : 'Sizga Provodka sahifalari ochilmagan. Xarajat kiritish uchun hodim sahifasiga o\'ting.';
    app.innerHTML =
      '<div style="max-width:420px;margin:18vh auto;text-align:center;padding:24px">' +
        '<div style="font-size:44px;line-height:1;margin-bottom:14px">&#128274;</div>' +
        '<h2 style="margin:0 0 8px;font-size:20px;font-weight:800">Ruxsat yo\'q</h2>' +
        '<p style="margin:0 0 18px;color:var(--muted,#888);font-size:14px">' + txt + '</p>' +
        (to ? '<a href="' + to + suf() + '" style="' + btn + ';background:var(--primary,#2563eb);color:#fff">' +
              'Ochiq bo\'limga o\'tish</a>'
            : '<a href="' + hodimUrl() + '" style="' + btn + ';background:var(--primary,#2563eb);color:#fff">' +
              'Xarajat kiritish</a>') +
      '</div>';
  }

  /* Sahifani himoyalaydi. `false` qaytarsa — chaqiruvchi init() ni ishga tushirmasin.

     Uch xil natija:
       1) Provodka huquqi umuman yo'q + bosh sahifadamiz -> hodim sahifasiga
          JIMGINA o'tkaziladi (80% user "Ruxsat yo'q" ekranini ko'rmasligi kerak).
       2) Aynan shu sahifa yopiq -> "Ruxsat yo'q" ekrani.
       3) Ochiq -> true. */
  function gate() {
    applied = true;
    hideNav();
    var k = page();
    var p = get();
    if (PAGES.indexOf(k) < 0) return true;        // hodim va boshqa cheklanmagan sahifalar

    if (!hasProvodka()) {
      if (k === HOME) { location.replace(hodimUrl()); return false; }
      denyScreen(); return false;
    }
    if (!pageOk(k) || (k === 'konvert' && !p.can_convert)) {
      /* Bosh sahifa yopiq bo'lsa — "Ruxsat yo'q" ekrani o'rniga birinchi OCHIQ bo'limga
         jimgina o'tkazamiz. Masalan faqat 'ai' ruxsati bor user ildizga/jurnalga kirsa
         darrov AI sahifasiga tushadi (avval bitta ortiqcha klik kerak edi).
         Sikl xavfi yo'q: `to !== HOME` va o'sha sahifada pageOk() true bo'ladi. */
      if (k === HOME) {
        var to = firstAllowed();
        if (to && to !== HOME) { location.replace(to + suf()); return false; }
      }
      /* Sahifa yopiq -> "Ruxsat yo'q" ekrani o'rniga DASHBOARD (index).
         Sabab: index endi hub — user o'ziga OCHIQ bo'limlar ro'yxatini darrov
         ko'radi, boshi berk ekranda qolmaydi. Sikl xavfi yo'q: 'index' PAGES
         da yo'q, ya'ni gate() u yerda yuqorida `return true` bilan chiqadi.
         ⚠️ `!hasProvodka()` shoxi (hodim redirect + denyScreen) TEGILMAGAN —
         80% user o'sha yo'ldan yuradi. */
      location.replace(indexUrl()); return false;
    }
    return true;
  }

  // ---- kassalar --------------------------------------------------------
  /* Ruxsat kaliti: bola-hisob (valyuta YOKI pul turi) parent kassasiga tegishli.
     Serverdagi kassa_root()/perm_op_key() bilan AYNAN bir xil bo'lishi shart —
     aks holda klient naqd/Click/Payme hisobini yashiradi, server esa ruxsat beradi
     (yoki teskarisi: UI ko'rsatadi, guard trigger 42501 bilan rad etadi).
     parent_id UCH ma'noli — hodim kassasi (parent=5400, UZS, pul_turi yo'q) bola EMAS,
     shuning uchun shart currency<>'UZS' YOKI pul_turi bor bo'lishi kerak. */
  function keyOf(a) {
    if (!a) return null;
    var c = a.currency || 'UZS';
    return (a.parent_id && (c !== 'UZS' || a.pul_turi)) ? a.parent_id : a.id;
  }
  function viewOk(a) {
    var p = get();
    if (p.is_admin || p.kassa_scope !== 'list') return true;
    return p.view_kassa_ids.indexOf(keyOf(a)) >= 0;
  }
  function opOk(a) {
    var p = get();
    if (p.is_admin || p.kassa_scope !== 'list') return true;
    return p.op_kassa_ids.indexOf(keyOf(a)) >= 0;
  }
  /* Ro'yxatni filtrlaydi. Faqat pul hisoblari cheklanadi — xarajat/daromad
     moddalari (kod 5 bilan boshlanmaydi) hamisha qoladi. */
  function isPulAcc(a) {
    var c = String(a && a.code || '');
    return c.charAt(0) === '5' && (!a.type || a.type === 'aktiv');
  }
  function filterView(list) { return (list || []).filter(function (a) { return !isPulAcc(a) || viewOk(a); }); }
  function filterOp(list)   { return (list || []).filter(function (a) { return !isPulAcc(a) || opOk(a); }); }

  // ---- filiallar (xarajat metadata) -----------------------------------
  /* Filial multiselect ro'yxatini ruxsatga ko'ra filtrlaydi. Admin yoki
     filial_scope='all' -> hammasi. 'list' -> faqat filial_ids. Filiallar
     v_filial_tanlov'dan keladi (obyektda `id` bor). Server guard yo'q —
     filial faqat metadata, pul harakati emas. */
  function filterFilials(list) {
    var p = get();
    if (p.is_admin || p.filial_scope !== 'list') return list || [];
    var ids = p.filial_ids;
    return (list || []).filter(function (f) { return ids.indexOf(f.id) >= 0; });
  }

  // ---- xato matni ------------------------------------------------------
  /* Server guard xatosini odam o'qiydigan matnga aylantiradi. */
  function errText(e) {
    var m = (e && (e.message || e.error_description || e.details)) || String(e || '');
    if (/42501|Ruxsat yoq|row-level security/i.test(m)) {
      return m.indexOf('Ruxsat yoq') >= 0 ? m : 'Ruxsat yo\'q: bu kassada amaliyot qilish huquqingiz yo\'q';
    }
    return m;
  }

  window.PERMS         = OPEN;
  window.permPage      = page;
  window.permLoad      = load;
  window.permGate      = gate;
  window.permHideNav   = hideNav;
  window.permPageOk    = pageOk;
  window.permHasProvodka = hasProvodka;
  /* my_perms() javobi HAQIQATAN keldimi. Sahifalar buni bilishi SHART EMAS (ular uchun
     "yuklanmaguncha ochiq" qoidasi kuchda), lekin `index.html` dashboardi TESKARI ishlaydi:
     ruxsat noma'lum bo'lsa karta CHIZMAYDI — aks holda yangi user bir zumga hamma bo'limni
     ko'rib qolardi (2026-08-18 dagi prod bug). */
  window.permLoaded    = function () { return loaded; };
  window.permViewOk    = viewOk;
  window.permOpOk      = opOk;
  window.permFilterView = filterView;
  window.permFilterOp  = filterOp;
  window.permConvert   = function () { return get().can_convert; };
  /* Admin bayrog'i. `sorovlar.html` "Hammaning so'rovlari" almashtirgichini
     shu bilan ko'rsatadi. Ruxsat hali kelmagan bo'lsa OPEN sukutida is_admin=false —
     ya'ni fail-closed (almashtirgich chiqmaydi), bu ataylab: server baribir
     admin bo'lmagan userga p_hammasi bayrog'ini bermaydi. */
  window.permIsAdmin   = function () { return !!get().is_admin; };
  window.permScope     = function () { return get().kassa_scope; };
  window.permFilialScope = function () { return get().filial_scope; };
  window.permFilialIds = function () { return get().filial_ids; };
  window.permFilterFilials = filterFilials;
  window.permErr       = errText;
  window.permClear     = clear;

  // Keshdan darrov qo'llash — sahifa miltillamasin (RPC javobini kutmaymiz)
  fromCache();
})();

/* =====================================================================
   Provodka — foydalanuvchi ruxsatlari (klient tomoni)
   ---------------------------------------------------------------------
   Oddiy (module EMAS) skript — 12 sahifada `defer` bilan ulanadi, vendor
   skriptlardan keyin, module'dan oldin. Shuning uchun module ishga
   tushganda window.perm* funksiyalari tayyor bo'ladi.

   Server: my_perms() RPC (PROVODKA_PERMS.sql).
   Bu fayl FAQAT KO'RINISHNI boshqaradi — haqiqiy to'siq serverdagi
   entry_line trigger va perm_can_convert(). UI yashirish yetarli emas.
   ===================================================================== */
(function () {
  'use strict';

  var KEY = 'prov-perms';
  // Sahifa kalitlari — SQL dagi perm_pages() bilan bir xil bo'lishi shart
  var PAGES = ['kassa', 'jurnal', 'professional', 'hisobot', 'balans', 'cashflow',
               'qarzdor', 'filial', 'valyuta', 'konvert', 'sozlama', 'provodka'];
  // Cheklanmagan holat: allowed_pages bo'sh = hamma sahifa, scope 'all' = hamma kassa,
  // filial_scope 'all' = hamma filial (xarajat metadata filtri).
  var OPEN = { allowed_pages: [], kassa_scope: 'all', view_kassa_ids: [],
               op_kassa_ids: [], can_convert: true,
               filial_scope: 'all', filial_ids: [], is_admin: false };

  var P = null;          // joriy ruxsatlar
  var applied = false;   // nav bir marta yashirilgan

  function arr(x) { return Array.isArray(x) ? x : []; }
  function norm(p) {
    if (!p || typeof p !== 'object') return null;
    return {
      user_id:        p.user_id || null,
      allowed_pages:  arr(p.allowed_pages),
      kassa_scope:    p.kassa_scope === 'list' ? 'list' : 'all',
      view_kassa_ids: arr(p.view_kassa_ids),
      op_kassa_ids:   arr(p.op_kassa_ids),
      can_convert:    p.can_convert !== false,
      filial_scope:   p.filial_scope === 'list' ? 'list' : 'all',
      filial_ids:     arr(p.filial_ids),
      is_admin:       !!p.is_admin
    };
  }
  function setP(p) { P = norm(p) || OPEN; window.PERMS = P; return P; }
  function get() { return P || OPEN; }

  // Sahifa kaliti: fayl nomi (.html siz). Ildiz "/" -> jurnal (bosh sahifa).
  function page() {
    var f = (location.pathname.split('/').pop() || '').replace('.html', '');
    return f || 'jurnal';
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
  function clear() { try { sessionStorage.removeItem(KEY); } catch (e) {} P = null; window.PERMS = OPEN; }

  /* Ruxsatlarni oladi. Keshda bo'lsa DARROV qaytaradi va fonda yangilaydi;
     yangilangani farq qilsa nav qayta qo'llanadi. Xatoda mavjud kesh saqlanadi
     (server tekshiruvi baribir ishlaydi — bu yerda "ochiq" qolish xavfsiz). */
  async function load(sb) {
    var had = fromCache();
    if (had) { fetchFresh(sb); return had; }
    return await fetchFresh(sb);
  }
  async function fetchFresh(sb) {
    try {
      var res = await sb.rpc('my_perms');
      if (res.error) { return get(); }
      var fresh = norm(res.data);
      if (!fresh) return get();
      var changed = JSON.stringify(fresh) !== JSON.stringify(P);
      setP(fresh); toCache(fresh);
      if (changed && applied) { applied = false; gate(); }
      return fresh;
    } catch (e) { return get(); }
  }

  // ---- sahifalar ------------------------------------------------------
  function pageOk(k) {
    var p = get();
    if (p.is_admin) return true;
    if (!p.allowed_pages.length) return true;   // bo'sh = hammasi ochiq
    return p.allowed_pages.indexOf(k) >= 0;
  }
  function firstAllowed() {
    var p = get();
    if (!p.allowed_pages.length) return 'jurnal';
    for (var i = 0; i < PAGES.length; i++) if (p.allowed_pages.indexOf(PAGES[i]) >= 0) return PAGES[i];
    return null;
  }

  /* Nav'dan ruxsatsiz sahifalarni olib tashlaydi (sidebar + bnav + "Ko'proq" sheet).
     Konvert ruxsati yo'q bo'lsa konvert sahifasi ham yashiriladi. */
  function hideNav() {
    var p = get();
    var links = document.querySelectorAll('.sidebar a[href$=".html"], .bnav a[href$=".html"], .msheet a[href$=".html"]');
    for (var i = 0; i < links.length; i++) {
      var k = (links[i].getAttribute('href') || '').replace('.html', '');
      var ok = pageOk(k) && !(k === 'konvert' && !p.can_convert);
      if (!ok) links[i].style.display = 'none';
    }
    // Sheet'dagi hamma havola yashiringan bo'lsa "Ko'proq" tugmasi ham keraksiz
    var sheet = document.querySelector('.msheet');
    if (sheet) {
      var vis = sheet.querySelectorAll('a[href$=".html"]:not([style*="display: none"])');
      if (!vis.length) {
        var more = document.querySelector('.bnav a[onclick*="openMore"]');
        if (more) more.style.display = 'none';
      }
    }
  }

  /* Faqat `main` ichini almashtiradi — sidebar/bnav joyida qoladi, foydalanuvchi
     ochiq bo'limga o'ta oladi. (#app ni butunlay tozalash navigatsiyani o'chirardi.) */
  function denyScreen() {
    var app = document.querySelector('#app main.main') || document.getElementById('app');
    if (!app) return;
    var to = firstAllowed();
    app.innerHTML =
      '<div style="max-width:420px;margin:18vh auto;text-align:center;padding:24px">' +
        '<div style="font-size:44px;line-height:1;margin-bottom:14px">&#128274;</div>' +
        '<h2 style="margin:0 0 8px;font-size:20px;font-weight:800">Ruxsat yo\'q</h2>' +
        '<p style="margin:0 0 18px;color:var(--muted,#888);font-size:14px">' +
          'Bu bo\'limga kirish huquqingiz yo\'q. Kerak bo\'lsa administratorga murojaat qiling.</p>' +
        (to ? '<a href="' + to + '.html" style="display:inline-block;padding:11px 20px;border-radius:11px;' +
              'background:var(--primary,#2563eb);color:#fff;text-decoration:none;font-weight:600;font-size:14px">' +
              'Ochiq bo\'limga o\'tish</a>' : '') +
      '</div>';
  }

  /* Sahifani himoyalaydi. `false` qaytarsa — chaqiruvchi init() ni ishga tushirmasin. */
  function gate() {
    applied = true;
    hideNav();
    var k = page();
    var p = get();
    if (!pageOk(k) || (k === 'konvert' && !p.can_convert)) { denyScreen(); return false; }
    return true;
  }

  // ---- kassalar --------------------------------------------------------
  /* Ruxsat kaliti: valyuta bola-hisobi parent kassasiga tegishli.
     parent_id ikki ma'noli (valyuta juftligi + guruh a'zoligi) — shuning uchun
     currency sharti majburiy, aks holda hodim kassalari (parent = 5400) chalkashadi. */
  function keyOf(a) {
    if (!a) return null;
    var c = a.currency || 'UZS';
    return (a.parent_id && c !== 'UZS') ? a.parent_id : a.id;
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
  window.permViewOk    = viewOk;
  window.permOpOk      = opOk;
  window.permFilterView = filterView;
  window.permFilterOp  = filterOp;
  window.permConvert   = function () { return get().can_convert; };
  window.permScope     = function () { return get().kassa_scope; };
  window.permFilialScope = function () { return get().filial_scope; };
  window.permFilialIds = function () { return get().filial_ids; };
  window.permFilterFilials = filterFilials;
  window.permErr       = errText;
  window.permClear     = clear;

  // Keshdan darrov qo'llash — sahifa miltillamasin (RPC javobini kutmaymiz)
  fromCache();
})();

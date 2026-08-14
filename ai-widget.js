/* =====================================================================
   Provodka — floating AI tugmasi (widget) — DEV
   ---------------------------------------------------------------------
   BRIEF_PROVODKA_AI_3.md, 4-band. Boshqa sahifada turgan holda AI bilan
   gaplashish: o'ng past burchakda dumaloq tugma -> o'ngdan chiqadigan
   panel -> panel ichida `ai*.html?embed=1` IFRAME.

   🔴 NEGA IFRAME (ikkinchi chat YOZILMAYDI):
   chat mantiqi (Edge Function chaqiruvi, suhbat tarixi, manbalar, fayl
   yuklash) BITTA joyda — ai sahifasida — qoladi. Ikkinchi implementatsiya
   yozilsa ikkita kod bazasi bo'lardi (TaskFix'dagi "namoz moduli ikki
   marta yozildi" falokati aynan shundan chiqqan).

   🔴 perms.js NAQSHI: bu fayl 15 sahifa uchun BITTA. Ichida birorta
   `NAME-dev.html` matni YO'Q — havola qo'shimchasi suf() bilan joriy fayl
   nomidan olinadi. Shu tufayli promote.sh uni bayt-ma-bayt ko'chira oladi
   va prod hech qachon dev sahifaga havola qilib qolmaydi.

   🔴 RUXSAT — FAIL-CLOSED (sukut: YASHIRIN). Tugma faqat window.PERMS
   `is_admin === true` yoki `allowed_pages` ichida 'ai' bo'lsa chiziladi.
   perms.js yuklanmagan / my_perms() hali kelmagan holatda PERMS = OPEN
   (`allowed_pages: []`, `is_admin:false`) -> tugma YO'Q. Ruxsat kelgach
   poll bilan paydo bo'ladi.
   ⚠️ Bu FAQAT KO'RINISH. Haqiqiy to'siq — ai-chat Edge Function ichidagi
   server tekshiruvi (perm_has_page('ai') AND my_perms()).

   Z-INDEX XARITASI (mavjud sahifalar + shu widget):
      40  sidebar          50  bnav            60  .aiw-fab (tugma)
     100  .gate (login)   145  .aiw-ov         150  .aiw-panel
     200  .mmodal (sheet) 205/210 .aic drawer (faqat ai sahifasida)
   Tugma 60 da: navigatsiya ustida, lekin login gate'i (100) va har qanday
   modal (200+) ostida — modal ochiq turganda ustiga chiqib qolmaydi.
   Panel esa 145/150 da: sahifa modallaridan (200) past, chunki panel
   ochiq bo'lganda sahifaning o'z modali baribir ustun bo'lishi kerak.
   ===================================================================== */
(function () {
  'use strict';

  /* Iframe ichida ishlamaydi (widget ichida widget bo'lmasin). */
  if (window.top !== window.self) return;

  var POLL_MS  = 400;   // ruxsat kelishini kutish qadami
  var POLL_MAX = 20;    // 20 x 400ms = 8s, keyin to'xtaydi

  /* Havola qo'shimchasi joriy fayl nomidan: dev sahifada `-dev.html`,
     prod sahifada `.html` (perms.js dagi bilan aynan bir xil). */
  function suf() { return /-dev\.html$/.test(location.pathname) ? '-dev.html' : '.html'; }

  /* Sahifa kaliti: fayl nomi, `.html` va `-dev` qo'shimchasisiz. */
  function pageKey() {
    var f = (location.pathname.split('/').pop() || '').replace('.html', '');
    return f.replace(/-dev$/, '');
  }

  /* AI sahifasining o'zida widget kerak emas — u yerda to'liq chat bor. */
  if (pageKey() === 'ai') return;

  // ---- ruxsat (fail-closed) -------------------------------------------
  function allowed() {
    var p = window.PERMS;
    if (!p || typeof p !== 'object') return false;   // perms.js yo'q -> YASHIRIN
    if (p.is_admin === true) return true;
    var pages = p.allowed_pages;
    return Array.isArray(pages) && pages.indexOf('ai') >= 0;
  }

  /* Login ekranida (#app yashirin) tugma chizilmaydi. getClientRects()
     display:none ni ham, elementning umuman yo'qligini ham qamrab oladi. */
  function appVisible() {
    var a = document.getElementById('app');
    return !!(a && a.getClientRects().length);
  }

  // ---- ikonkalar (inline SVG, lucide 1.24 geometriyasi) ---------------
  /* Ataylab inline: widget HTML'i lucide.createIcons() dan keyin
     qo'shiladi, `<i data-lucide>` bo'lsa ikonka bo'sh qolardi. */
  function svg(inner, size) {
    return '<svg xmlns="http://www.w3.org/2000/svg" width="' + size + '" height="' + size +
           '" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" ' +
           'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + inner + '</svg>';
  }
  var IC_SPARKLES =
    '<path d="M11.017 2.814a1 1 0 0 1 1.966 0l1.051 5.558a2 2 0 0 0 1.594 1.594l5.558 1.051a1 1 0 0 1 0 1.966' +
    'l-5.558 1.051a2 2 0 0 0-1.594 1.594l-1.051 5.558a1 1 0 0 1-1.966 0l-1.051-5.558a2 2 0 0 0-1.594-1.594' +
    'l-5.558-1.051a1 1 0 0 1 0-1.966l5.558-1.051a2 2 0 0 0 1.594-1.594z"/>' +
    '<path d="M20 2v4"/><path d="M22 4h-4"/><circle cx="4" cy="20" r="2"/>';
  var IC_X    = '<path d="M18 6 6 18"/><path d="m6 6 12 12"/>';
  var IC_LINK = '<path d="M15 3h6v6"/><path d="M10 14 21 3"/>' +
                '<path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/>';

  // ---- CSS (prefiks .aiw-*, sahifadagi .ai-/.aic-/.mmodal bilan to'qnashmaydi)
  var CSS = [
    '.aiw-fab{position:fixed;right:22px;bottom:22px;width:54px;height:54px;border:none;border-radius:50%;',
      'background:var(--primary,#1ea83a);color:var(--on-primary,#fff);cursor:pointer;z-index:60;',
      'display:flex;align-items:center;justify-content:center;padding:0;',
      'box-shadow:0 6px 20px rgba(16,24,40,.22);',
      'transition:transform .14s,background .14s,box-shadow .14s}',
    '.aiw-fab:hover{background:var(--primary-hover,#17862f);box-shadow:0 8px 24px rgba(16,24,40,.28)}',
    '.aiw-fab:active{transform:translateY(1px)}',
    '.aiw-fab svg{width:24px;height:24px}',
    '.aiw-ov{position:fixed;inset:0;z-index:145;background:rgba(16,24,40,.42);opacity:0;transition:opacity .18s}',
    '.aiw-ov.on{opacity:1}',
    '.aiw-panel{position:fixed;top:0;right:0;bottom:0;width:420px;max-width:100vw;z-index:150;',
      'display:flex;flex-direction:column;background:var(--surface,#fff);',
      'border-left:1px solid var(--line,#e6e8ec);box-shadow:-12px 0 32px rgba(16,24,40,.16);',
      'transform:translateX(100%);transition:transform .22s cubic-bezier(.32,.72,0,1)}',
    '.aiw-panel.on{transform:none}',
    '.aiw-panel:focus{outline:none}',
    '.aiw-head{flex:0 0 auto;display:flex;align-items:center;gap:6px;padding:12px 12px 12px 16px;',
      'border-bottom:1px solid var(--line,#e6e8ec)}',
    '.aiw-title{flex:1 1 auto;min-width:0;display:flex;align-items:center;gap:9px;',
      'font-weight:700;font-size:15px;letter-spacing:-.01em;color:var(--ink,#101828)}',
    '.aiw-title svg{width:18px;height:18px;flex:0 0 auto;color:var(--primary,#1ea83a)}',
    '.aiw-title span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}',
    '.aiw-btn{flex:0 0 auto;width:36px;height:36px;display:flex;align-items:center;justify-content:center;',
      'border:none;border-radius:10px;background:transparent;color:var(--muted,#667085);cursor:pointer;',
      'text-decoration:none;transition:background .13s,color .13s}',
    '.aiw-btn:hover{background:var(--surface-2,#f0f2f5);color:var(--ink,#101828)}',
    '.aiw-btn svg{width:18px;height:18px}',
    '.aiw-body{flex:1 1 auto;min-height:0;position:relative;background:var(--bg,#f5f6f8)}',
    '.aiw-body iframe{display:block;width:100%;height:100%;border:0}',
    '.aiw-load{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;',
      'color:var(--muted,#667085);font-size:14px}',
    '.aiw-fab[hidden],.aiw-ov[hidden],.aiw-panel[hidden]{display:none}',
    /* Mobil: tugma bnav (76px) ustida, panel deyarli to'liq ekran */
    '@media(max-width:899px){',
      '.aiw-fab{right:16px;bottom:calc(76px + 12px + env(safe-area-inset-bottom));width:50px;height:50px}',
      '.aiw-panel{width:100%;left:0;border-left:none}',
      'body.aiw-open{overflow:hidden}',
    '}',
    '@media (prefers-reduced-motion:reduce){',
      '.aiw-fab,.aiw-ov,.aiw-panel{transition:none}',
    '}'
  ].join('');

  // ---- holat -----------------------------------------------------------
  var styled = false;   // CSS quyilganmi
  var fab = null;       // dumaloq tugma
  var ov = null;        // qoplama
  var panel = null;     // o'ng panel
  var frame = null;     // iframe (LAZY — birinchi ochilishda yaratiladi)
  var isOpen = false;
  var timer = null, ticks = 0;

  function injectCss() {
    if (styled) return;
    styled = true;
    var s = document.createElement('style');
    s.setAttribute('data-aiw', '1');
    s.textContent = CSS;
    (document.head || document.documentElement).appendChild(s);
  }

  function build() {
    if (fab) return;
    injectCss();

    fab = document.createElement('button');
    fab.type = 'button';
    fab.id = 'aiwFab';
    fab.className = 'aiw-fab';
    fab.hidden = true;
    fab.setAttribute('aria-label', 'AI yordamchi');
    fab.setAttribute('aria-haspopup', 'dialog');
    fab.setAttribute('aria-expanded', 'false');
    fab.setAttribute('aria-controls', 'aiwPanel');
    fab.title = 'AI yordamchi';
    fab.innerHTML = svg(IC_SPARKLES, 24);
    fab.addEventListener('click', toggle);

    ov = document.createElement('div');
    ov.id = 'aiwOverlay';
    ov.className = 'aiw-ov';
    ov.hidden = true;
    ov.addEventListener('click', close);

    panel = document.createElement('div');
    panel.id = 'aiwPanel';
    panel.className = 'aiw-panel';
    panel.hidden = true;
    panel.tabIndex = -1;
    panel.setAttribute('role', 'dialog');
    panel.setAttribute('aria-modal', 'true');
    panel.setAttribute('aria-label', 'AI yordamchi');
    panel.innerHTML =
      '<div class="aiw-head">' +
        '<div class="aiw-title">' + svg(IC_SPARKLES, 18) + '<span>AI yordamchi</span></div>' +
        '<a class="aiw-btn" id="aiwFull" href="' + aiUrl('') + '" title="To\'liq ekranda ochish" ' +
          'aria-label="To\'liq ekranda ochish">' + svg(IC_LINK, 18) + '</a>' +
        '<button type="button" class="aiw-btn" id="aiwClose" title="Yopish" aria-label="Yopish">' +
          svg(IC_X, 18) + '</button>' +
      '</div>' +
      '<div class="aiw-body" id="aiwBody"><div class="aiw-load" id="aiwLoad">Yuklanmoqda…</div></div>';
    panel.querySelector('#aiwClose').addEventListener('click', close);

    document.body.appendChild(fab);
    document.body.appendChild(ov);
    document.body.appendChild(panel);

    document.addEventListener('keydown', onKey);
    window.addEventListener('message', onMsg);
  }

  /* AI sahifasi manzili. `q` — qo'shimcha query ('' yoki '?embed=1').
     ⚠️ Fayl nomi shu yerda YAGONA joyda quriladi va `-dev` matni
     literal sifatida yozilmaydi (promote uchun). */
  function aiUrl(q) { return 'ai' + suf() + q; }

  // ---- ochish / yopish -------------------------------------------------
  function ensureFrame() {
    if (frame) return;
    frame = document.createElement('iframe');
    frame.id = 'aiwFrame';
    frame.title = 'AI yordamchi';
    /* ?embed=1 — ai sahifasi shu rejimda nav/sarlavhani yashiradi.
       Iframe FAQAT birinchi ochilishda yaratiladi (sahifa yuklanishiga
       ta'sir qilmasin), yopilganda DOM da qoladi — chat holati saqlanadi. */
    frame.src = aiUrl('?embed=1');
    frame.addEventListener('load', function () {
      var l = document.getElementById('aiwLoad');
      if (l) l.style.display = 'none';
    });
    document.getElementById('aiwBody').appendChild(frame);
  }

  function open() {
    if (isOpen) return;
    if (!allowed() || !appVisible()) return;   // fail-closed: ruxsatsiz ochilmaydi
    build();
    isOpen = true;
    ov.hidden = false;
    panel.hidden = false;
    ensureFrame();
    document.body.classList.add('aiw-open');
    fab.setAttribute('aria-expanded', 'true');
    /* Sinxron `hidden=false` dan keyin darrov klass qo'shilsa brauzer
       o'tishni chizmaydi — bitta kadr kutamiz. */
    requestAnimationFrame(function () {
      requestAnimationFrame(function () {
        if (!isOpen) return;
        ov.classList.add('on');
        panel.classList.add('on');
      });
    });
    panel.focus();
  }

  function close() {
    if (!isOpen || !panel) return;
    isOpen = false;
    ov.classList.remove('on');
    panel.classList.remove('on');
    document.body.classList.remove('aiw-open');
    if (fab) fab.setAttribute('aria-expanded', 'false');
    var p = panel, o = ov;
    setTimeout(function () {
      if (isOpen) return;          // shu orada qayta ochilgan bo'lsa tegmaymiz
      p.hidden = true;
      o.hidden = true;
    }, 220);
    if (fab && !fab.hidden) fab.focus();   // fokus tugmaga qaytadi
  }

  function toggle() { if (isOpen) close(); else open(); }

  function onKey(e) {
    if (!isOpen) return;
    if (e.key === 'Escape' || e.key === 'Esc') { e.stopPropagation(); close(); }
  }

  /* Iframe ichidan yopish. ⚠️ Escape iframe ichida bosilsa u hodisa ota
     hujjatga YETMAYDI — shuning uchun embed rejimidagi ai sahifasi
     `parent.postMessage({source:'aros-ai', type:'close'}, location.origin)`
     yuborsa panel yopiladi. Boshqa manba/oyna e'tiborsiz. */
  function onMsg(e) {
    if (e.origin !== location.origin) return;
    if (!frame || e.source !== frame.contentWindow) return;
    var d = e.data;
    if (d && d.source === 'aros-ai' && d.type === 'close') close();
  }

  // ---- ko'rinishni sinxronlash ----------------------------------------
  function sync() {
    var ok = appVisible() && allowed();
    if (ok) {
      build();
      fab.hidden = false;
    } else if (fab) {
      if (isOpen) close();
      fab.hidden = true;
    }
  }

  /* Ruxsat kech kelishi mumkin (my_perms() RPC). Sodda va ishonchli yo'l —
     poll: 400ms x 20 = 8s. Keyin to'xtaydi (cheksiz interval qolmasin).
     Har tikda sync() ikki tomonlama ishlaydi: kech kelgan ruxsat tugmani
     ko'rsatadi, kesh keyin bekor qilinsa yashiradi. */
  function startPoll() {
    ticks = 0;
    if (timer) return;
    timer = setInterval(function () {
      ticks++;
      sync();
      if (ticks >= POLL_MAX) { clearInterval(timer); timer = null; }
    }, POLL_MS);
  }

  function init() {
    sync();
    startPoll();
    /* Login ekranidan app'ga o'tish: enterApp() `#app` ning inline
       style'ini o'zgartiradi — o'shani kuzatamiz va poll oynasini
       qaytadan ochamiz (ruxsat login'dan keyin yuklanadi). */
    var app = document.getElementById('app');
    if (app && window.MutationObserver) {
      new MutationObserver(function () { sync(); startPoll(); })
        .observe(app, { attributes: true, attributeFilter: ['style', 'class'] });
    }
  }

  window.aiwOpen   = open;
  window.aiwClose  = close;
  window.aiwToggle = toggle;

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();

#!/usr/bin/env bash
# COMPOSITOR_CLEAN_LOGO_20261120.sh — aros-compositor: CLEAN rejimda aros logo + shior QAYTIB CHIQMASIN.
# Sabab (20.11.2026, Ekranlar Ajib i1 #11072): DESIGN_STYLE=clean bo'lsa ham natijada eski brendli shablon ko'rinishi
# (chap yuqorida aros logo + «Vaqtingizni va pulingizni tejaydi!») chiqdi. Logdan: AI clean promptga qaramay kichik brend
# bloki chizgan, keyin fix_logo2 uni ASL logo + shior bilan ALMASHTIRIB zaxira nomzod (best) qilib qo'ygan; verify 3 marta
# «mahsulot mos emas» deb rad etgach aynan shu zaxira nomzod yuborilgan. Ya'ni brendni biz o'zimiz chizganmiz.
# Tuzatish: CLEAN rejimda fix_logo2 faqat ANIQLAYDI (almashtirmaydi); brend topilsa 1-urinishda qayta chizdiriladi
# («remove the brand block…»); zaxira nomzod — brendsiz kadr afzal, bo'lmasa oxirgi toza kadr. Boshqa rejimlar o'zgarmaydi.
# Ishga tushirish (Asilbek, lokal mashinadan):
#   ssh root@37.27.15.184 'bash -s' < COMPOSITOR_CLEAN_LOGO_20261120.sh
# Orqaga qaytarish:
#   ssh root@37.27.15.184 'bash -s' -- --rollback < COMPOSITOR_CLEAN_LOGO_20261120.sh
set -euo pipefail
D=/var/www/n8n/aros-compositor
F=$D/create_v2.py
B=$D/create_v2.py.bak_20261120_clean_logo
cd /var/www/n8n
if [ "${1:-}" = "--rollback" ]; then
  [ -f "$B" ] || { echo "zaxira yo'q: $B"; exit 1; }
  cp "$B" "$F" && echo "qaytarildi: $F"
  docker compose build aros-compositor && docker compose up -d aros-compositor
  exit 0
fi
if grep -q "CLEAN_LOGO_20261120" "$F"; then echo "allaqachon patchlangan — faqat qayta quriladi"; else
  cp -n "$F" "$B" && echo "zaxira: $B"
  cat > /tmp/patch_clean_logo.py <<'PY'
# create_v2.py ga 2 ta aniq almashtirish. Har anchor AYNAN 1 marta uchrashi shart, aks holda hech narsa yozilmaydi.
import sys, io
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
OLD1 = (
"            if not HEADER_OURS and pack_fb is None:\n"
"                fixed, finfo = fix_logo2(cand)\n"
"                # 2 = shior logo ostida (to'g'ri), 1 = o'ngda (zaxira), 0 = joy yo'q\n"
"                tag_ok = {\"band\": 2, \"band_kichik\": 2, \"gap\": 2, \"right\": 1}.get(finfo.get(\"tagline\"), 0)\n"
"                if best is None or tag_ok > best_tag:        # shiori joylashgan nomzod afzal\n"
"                    best, best_tag = fixed, tag_ok\n"
)
NEW1 = (
"            brand_found = False\n"
"            if CLEAN and pack_fb is None:\n"
"                # 🔴 CLEAN_LOGO_20261120 (Asilbek, Ekranlar Ajib i1): CLEAN rejimda fix_logo2 AI chizgan brend blokini ASL logo +\n"
"                #    shior bilan ALMASHTIRIB zaxira nomzod (best) qilib qo'yardi — verify hamma urinishni rad etganda shu nomzod\n"
"                #    chiqib, eski brendli shablon ko'rinishi qaytardi. Endi faqat ANIQLASH: brend topilsa 1-urinishda qayta\n"
"                #    chizdiriladi, zaxira nomzod — brendsiz kadr afzal (bo'lmasa oxirgi toza cand). Logo/shior hech qachon bosilmaydi.\n"
"                finfo = {}\n"
"                try:\n"
"                    _dummy, finfo = fix_logo2(cand.copy())\n"
"                    brand_found = finfo.get(\"logo\") in (\"match\", \"cluster\")\n"
"                except Exception as _fe:  # noqa\n"
"                    print(\"[v2 clean] logo aniqlash xato:\", repr(_fe), flush=True)\n"
"                if brand_found:\n"
"                    print(f\"[v2 clean] DIQQAT: AI brend bloki chizgan (logo={finfo.get('logo')}, score={finfo.get('score')}) -> \"\n"
"                          f\"{'qayta chizdiriladi' if attempt == 0 else 'zaxira sifatida past darajada'}\", flush=True)\n"
"                _rank = 0 if brand_found else 1\n"
"                if best is None or _rank > best_tag:\n"
"                    best, best_tag = cand, _rank\n"
"                if brand_found and attempt == 0:\n"
"                    hdr_problem = (\"remove the brand block from the top-left: NO logo, NO wordmark, NO slogan, NO 'aros' \"\n"
"                                   \"anywhere on the page — the top-left corner must stay plain empty white\")\n"
"            elif not HEADER_OURS and pack_fb is None:\n"
"                fixed, finfo = fix_logo2(cand)\n"
"                # 2 = shior logo ostida (to'g'ri), 1 = o'ngda (zaxira), 0 = joy yo'q\n"
"                tag_ok = {\"band\": 2, \"band_kichik\": 2, \"gap\": 2, \"right\": 1}.get(finfo.get(\"tagline\"), 0)\n"
"                if best is None or tag_ok > best_tag:        # shiori joylashgan nomzod afzal\n"
"                    best, best_tag = fixed, tag_ok\n"
)
OLD2 = "            hard = (HDR_REDRAW and tag_ok == 0) if not HEADER_OURS else (restored is None)\n"
NEW2 = (
"            hard = (HDR_REDRAW and tag_ok == 0) if not HEADER_OURS else (restored is None)\n"
"            hard = hard or (CLEAN and brand_found and attempt == 0)     # CLEAN_LOGO_20261120: brend chizilgan -> bir marta qayta\n"
)
for old, new in ((OLD1, NEW1), (OLD2, NEW2)):
    n = s.count(old)
    if n != 1:
        sys.exit(f"ANCHOR {n} marta topildi (1 kerak): {old[:80]!r}")
    s = s.replace(old, new)
io.open(p, "w", encoding="utf-8").write(s)
print("patch OK:", p)
PY
  python3 -I /tmp/patch_clean_logo.py "$F"
  python3 -m py_compile "$F" && echo "py_compile OK"
fi
grep -n "CLEAN_LOGO_20261120" "$F" | head -3
docker compose build aros-compositor 2>&1 | tail -3
docker compose up -d aros-compositor
sleep 4
docker ps --filter name=aros-compositor --format '{{.Names}} {{.Status}}'
docker logs --since 20s aros-compositor 2>&1 | tail -5
echo "TAYYOR. Tekshirish: botga ekran suratini yuboring — logda [v2 clean] qatorlari, natijada chap yuqorida logo/shior BO'LMASLIGI kerak."

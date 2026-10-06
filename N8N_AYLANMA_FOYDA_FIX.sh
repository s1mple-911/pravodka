#!/usr/bin/env bash
# =====================================================================
# N8N_AYLANMA_FOYDA_FIX.sh — 2026-10-06 — «Aros Provodka - Aylanma Snapshot» (o3BZP8uYatGkRu8b)
# Foyda sinxroni mustahkamlanadi (Postgres orqali, n8n MCP update_workflow ISHLATILMAYDI — kreditlar uzilmasin):
#   * Foyda URL      — oxirgi 2 kun → oxirgi 5 KUN (Metabase hisoboti kechikib to'lsa keyingi kunlarda o'zi tushadi)
#   * Foyda Payload  — Metabase da kun hali TO'LMAGAN bo'lsa (faqat bo'sh «JAMI», hamma raqam null) o'sha kun YOZILMAYDI
#                      (eski to'liq ma'lumot ustiga null tushmasin); HAMMA kun bo'sh bo'lsa — xato (jimgina 0 YO'Q).
# Hodisa: 04.10 va 05.10 foyda yozilmadi — Metabase «Profit report» 03.10 dan to'xtab qolgan (10-02 to'liq 21 filial,
# 10-03 faqat Samarqand Samsung, 10-04/05 bo'sh) — n8n bo'sh JAMI qatorini yozib qo'ygan. Metabase manbasi ALOHIDA tekshiriladi.
#
# ISHLATISH (Asilbek, bitta buyruq):
#   ssh root@37.27.15.184 'bash -s' < /Users/s1mple/Projects/pravodka/N8N_AYLANMA_FOYDA_FIX.sh
# Keyin n8n UI da workflow'ni OCHIB «Publish» bosiladi (faol ishga tushadigan versiya — activeVersionId).
# Zaxira: /root/n8n-backups/o3BZP8uYatGkRu8b_<vaqt>.json (row_to_json). Qayta ishga tushirish xavfsiz (assert'lar tekshiradi).
# =====================================================================
set -euo pipefail
WF=o3BZP8uYatGkRu8b
PG="docker exec n8n-postgres psql -U n8n -d n8n"
mkdir -p /root/n8n-backups
$PG -Atc "select row_to_json(w) from workflow_entity w where id='$WF'" > /root/n8n-backups/${WF}_$(date +%Y%m%d_%H%M%S).json
echo "zaxira: $(ls -t /root/n8n-backups/${WF}_*.json | head -1)"
$PG -Atc "select nodes::text from workflow_entity where id='$WF'" > /tmp/ayl_nodes.json

python3 - <<'PYEOF'
import json
nodes=json.load(open("/tmp/ayl_nodes.json"))
done=[]
for n in nodes:
    if n["name"]=="Foyda URL":
        c=n["parameters"]["jsCode"]
        if "k <= 5" in c:
            print("Foyda URL allaqachon 5 kun"); done.append("url(skip)"); continue
        assert c.count("for (var k = 1; k <= 2; k++) {")==1, "Foyda URL: kutilgan sikl topilmadi"
        c=c.replace("// Kunlik foyda — kecha va undan oldingi kun (Toshkent).",
                    "// Kunlik foyda — oxirgi 5 kun (Toshkent): Metabase hisoboti kechikib to'lsa keyingi kunlarda o'zi tushadi (2026-10-06).")
        c=c.replace("for (var k = 1; k <= 2; k++) {","for (var k = 1; k <= 5; k++) {")
        n["parameters"]["jsCode"]=c; done.append("url")
    if n["name"]=="Foyda Payload":
        c=n["parameters"]["jsCode"]
        if "boshKunlar" in c:
            print("Foyda Payload allaqachon patch qilingan"); done.append("payload(skip)"); continue
        old="    if (o.filial) rows.push(o);\n  }\n}"
        assert c.count(old)==1, "Foyda Payload: kutilgan blok topilmadi"
        new=(old+"\n"
             "// 2026-10-06: Metabase da kun hali TO'LMAGAN bo'lsa faqat bo'sh «JAMI» (hamma raqam null) qaytadi — bunday kun YOZILMAYDI\n"
             "// (eski to'liq ma'lumot ustiga null tushmasin); keyingi kunlardagi 5 kunlik oyna uni o'zi to'ldiradi.\n"
             "var bosh = {};\n"
             "rows.forEach(function (o) { var isEmpty = (o.foyda_usd == null && o.sotuv_usd == null && o.sotilgan == null); if (!isEmpty) bosh[o.sana] = false; else if (!(o.sana in bosh)) bosh[o.sana] = true; });\n"
             "var boshKunlar = Object.keys(bosh).filter(function (s) { return bosh[s]; });\n"
             "rows = rows.filter(function (o) { return !bosh[o.sana]; });\n"
             "if (boshKunlar.length) xato.push('Metabase bo\\'sh (hali to\\'lmagan): ' + boshKunlar.sort().join(', '));")
        c=c.replace(old,new)
        c=c.replace("// JIMGINA 0 YO'Q: ikkala kun ham bo'sh bo'lsa xato (Metabase savoli/parametri o'zgargan bo'lishi mumkin)",
                    "// JIMGINA 0 YO'Q: HAMMA kun bo'sh bo'lsa xato (Metabase savoli/parametri o'zgargan yoki hisobot butunlay to'xtagan)")
        n["parameters"]["jsCode"]=c; done.append("payload")
assert "url" in " ".join(done) and "payload" in " ".join(done), "node topilmadi: %s" % done
json.dump(nodes, open("/tmp/ayl_nodes_new.json","w"), ensure_ascii=False)
print("patched:", done)
PYEOF

docker cp /tmp/ayl_nodes_new.json n8n-postgres:/tmp/ayl_nodes_new.json
cat > /tmp/ayl_upd.sql <<'SQLEOF'
\set nodes `cat /tmp/ayl_nodes_new.json`
begin;
update workflow_entity
   set nodes = :'nodes'::json, "versionId" = gen_random_uuid(), "updatedAt" = now()
 where id = 'o3BZP8uYatGkRu8b';
insert into workflow_history ("versionId","workflowId",authors,"createdAt","updatedAt",nodes,connections)
select "versionId", id, 'Asilbek (foyda fix 2026-10-06)', now(), now(), nodes, connections
  from workflow_entity where id = 'o3BZP8uYatGkRu8b';
commit;
select "versionId" as yangi_versiya, "activeVersionId" as faol_versiya from workflow_entity where id = 'o3BZP8uYatGkRu8b';
SQLEOF
docker cp /tmp/ayl_upd.sql n8n-postgres:/tmp/ayl_upd.sql
$PG -f /tmp/ayl_upd.sql
echo "TAYYOR — endi n8n UI da «Aros Provodka - Aylanma Snapshot» ni ochib Publish bosing (faol_versiya yangi_versiya ga teng bo'lsin)."

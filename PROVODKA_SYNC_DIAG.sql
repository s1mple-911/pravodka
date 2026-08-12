-- =====================================================================
--  PROVODKA_SYNC_DIAG.sql — "yozuvlar: 0, tafsilot: []" ni ochish
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).  TaskFix EMAS.
--
--  ⚠️ BU FAYL HECH NARSA YOZMAYDI. Hammasi select yoki dry_run.
--     (D.5 dagi sync_filial_balans chaqiruvi p_dry_run = TRUE.)
--
--  MUAMMO: Balans Sync `{"yozuvlar": 0, "tafsilot": []}` qaytardi, lekin
--  Aros'da kassa puli ko'paygan. Javobning o'zi sababni ko'rsatmaydi,
--  chunki RPC ichida UCH xil yo'l bir xil natija berardi:
--
--     1) JSON'da `cash`/`click`/`payme` maydoni YO'Q          -> jimgina continue
--     2) maydon bor, lekin delta = 0 (daftar Aros'ga teng)     -> jimgina continue
--     3) massiv bo'sh keldi (filiallar: 0)                     -> sikl umuman aylanmaydi
--
--  Uchalasida ham `tafsilot` bo'sh, `ogohlantirishlar` bo'sh qoladi.
--  Shuning uchun PROVODKA_SYNC_BALANS.sql dagi funksiyaga sanoq qo'shildi
--  (`tegilmadi`, `ozgarmagan`, `ozgarmagan_royxat`) — AVVAL O'SHA FAYLNING
--  funksiya blokini qayta RUN qiling, keyin shu yerdagi D.5 ni.
--  Imzo o'zgarmagan (p_data jsonb, p_dry_run boolean) — prod sinmaydi.
--
--  YANGI JAVOB VORONKASI:
--     filiallar × 4 tur  =  tegilmadi + ozgarmagan + yozuvlar + otkazildi
--     tegilmadi  > 0  -> n8n maydonni yubormagan  (muammo n8n'da, RPC'da emas)
--     ozgarmagan > 0  -> daftar HAQIQATAN Aros'ga teng
--     ikkovi 0        -> massiv bo'sh / filial mapping'ga tushmagan
-- =====================================================================


-- ---------------------------------------------------------------------
-- D.0 RPC "joriy" ni QAYERDAN oladi — javob
-- ---------------------------------------------------------------------
-- Har filial × har tur uchun:
--   joriy = SUM(entry_line.debit − entry_line.credit)
--           WHERE account_id = <TUR CHILD hisobi>          <-- parent kassa EMAS
--             AND entry.status = 'posted' AND is_deleted = false
--   aros  = JSON'dagi cash | click | payme (dollar uchun fc_amount/dollar_usd)
--   delta = aros − joriy
-- Ya'ni "joriy" hech qanday snapshot/kesh EMAS — har chaqiruvda entry_line'dan
-- qayta hisoblanadi. Oldingi Aros balansi HECH QAYERDA saqlanmaydi.
-- ⚠️ MUHIM: parent kassaning O'ZIGA (masalan 5211) yozilgan pul joriy ga
--    KIRMAYDI — faqat tur child'lari (naqd/click/payme/USD) sanaladi.


-- ---------------------------------------------------------------------
-- D.1 Bitta filial: mapping qatorlari (5211 Izza / filial_ref = 1)
-- ---------------------------------------------------------------------
-- Bo'sh chiqsa -> RPC bu filialga UMUMAN yeta olmaydi (ogohlantirish beradi).
-- 4 qator chiqishi kerak: cash, click, payme, dollar_usd.
select filial_ref, warehouse_id, kassa_code, kassa_name, kassa_turi,
       aros_maydon, turi, hisob_code, account_id, currency
  from v_filial_sync_mapping
 where btrim(filial_ref::text) = '1'
    or kassa_code = '5211'
 order by aros_maydon;


-- ---------------------------------------------------------------------
-- D.2 O'SHA filial uchun RPC "joriy" ni AYNAN qanday hisoblasa — shunday
-- ---------------------------------------------------------------------
-- `satrlar` = 0 bo'lsa RPC uni "birinchi marta" deb biladi (Kt boshlang'ich
-- kapital). `oxirgi_yozuv` — o'sha hisobga eng oxirgi marta qachon tegilgan.
select m.kassa_code, m.aros_maydon, m.hisob_code,
       coalesce(sum(l.debit - l.credit), 0)                                as joriy_uzs,
       coalesce(sum(case when l.debit > 0 then coalesce(l.fc_amount,0)
                         else -coalesce(l.fc_amount,0) end), 0)            as joriy_fc,
       count(l.id)                                                        as satrlar,
       max(e.created_at)                                                  as oxirgi_yozuv
  from v_filial_sync_mapping m
  left join entry_line l on l.account_id = m.account_id
  left join entry e on e.id = l.entry_id
                   and e.status = 'posted' and e.is_deleted = false
 where btrim(m.filial_ref::text) = '1'
    or m.kassa_code = '5211'
 group by m.kassa_code, m.aros_maydon, m.hisob_code
 order by m.aros_maydon;


-- ---------------------------------------------------------------------
-- D.3 HAMMA filial × tur — joriy qoldiq jadvali (Aros bilan ko'z bilan solishtiring)
-- ---------------------------------------------------------------------
select m.kassa_code, m.kassa_name,
       max(case when m.aros_maydon = 'cash'  then j.joriy end)       as naqd,
       max(case when m.aros_maydon = 'click' then j.joriy end)       as click,
       max(case when m.aros_maydon = 'payme' then j.joriy end)       as payme,
       max(case when m.aros_maydon = 'dollar_usd' then j.joriy_fc end) as usd,
       sum(j.satrlar)                                                as jami_satr
  from v_filial_sync_mapping m
  cross join lateral (
       select coalesce(sum(l.debit - l.credit), 0) as joriy,
              coalesce(sum(case when l.debit > 0 then coalesce(l.fc_amount,0)
                                else -coalesce(l.fc_amount,0) end), 0) as joriy_fc,
              count(*) as satrlar
         from entry_line l
         join entry e on e.id = l.entry_id
        where l.account_id = m.account_id
          and e.status = 'posted' and e.is_deleted = false) j
 group by m.kassa_code, m.kassa_name
 order by m.kassa_code;


-- ---------------------------------------------------------------------
-- D.4 Delta sync OXIRGI MARTA qachon yozgan (kun bo'yicha)
-- ---------------------------------------------------------------------
-- Bo'sh yoki faqat eski sanalar chiqsa — sync bir hafta hech narsa yozmagan,
-- ya'ni "delta har doim 0" degani. Bu Aros o'zgarayotgan bo'lsa MUMKIN EMAS
-- -> demak maydonlar RPC'ga yetib bormayapti (D.5 shuni isbotlaydi).
select date(e.created_at at time zone 'Asia/Tashkent') as kun,
       count(distinct e.id) as entrylar,
       sum(l.debit) filter (where l.debit > 0) as jami_dt
  from entry e
  join entry_line l on l.entry_id = e.id
 where e.source = 'aros_auto' and e.created_by = 'aros_sync'
   and e.is_deleted = false
 group by 1
 order by 1 desc
 limit 20;


-- ---------------------------------------------------------------------
-- D.5 ⭐ HAL QILUVCHI SINOV — bitta filial, QO'LDA yozilgan Aros raqami
-- ---------------------------------------------------------------------
-- 5211 Izza ning HOZIRGI Aros naqd balansini (filial.html "Yangilash" yoki
-- Aros kassa sahifasidan) 999 o'rniga yozing va RUN qiling. p_dry_run = true,
-- HECH NARSA YOZILMAYDI.
--
-- NATIJANI SHUNDAY O'QING:
--   • "yozuvlar": 1 va tafsilot'da delta ko'rinsa
--         -> RPC TO'G'RI ISHLAYAPTI. Muammo n8n'da: Balans Sync o'sha
--            raqamni yubormayapti (Build Payload / Get Cachier Detail).
--   • "ozgarmagan": 1 (tafsilot bo'sh)
--         -> daftar Aros'ga haqiqatan teng; ko'paygan deb o'ylagan pul
--            allaqachon yozilgan yoki boshqa turga (click/payme) tushgan.
--   • "otkazildi": 1 + ogohlantirish
--         -> mapping muammosi, ogohlantirish matnini o'qing.
--   • "filiallar": 0
--         -> filial_ref noto'g'ri (matn/raqam farqi).
select jsonb_pretty(
  sync_filial_balans('[{"filial_ref": 1, "cash": 999}]'::jsonb, true)
);

-- D.5b To'rtala turni birga sinash (Aros raqamlarini qo'ying):
-- select jsonb_pretty(sync_filial_balans('[
--   {"filial_ref": 1, "cash": 0, "click": 0, "payme": 0, "dollar_usd": 0}
-- ]'::jsonb, true));


-- ---------------------------------------------------------------------
-- D.6 TOSHKENT MARKAZIY KASSA nega 0 — transfer tomoni
-- ---------------------------------------------------------------------
-- Markaziy kassaga pul FAQAT transfer sync'dan tushadi (sync_filial_balans
-- unga UMUMAN tegmaydi: mapping'da filial_ref bo'lgan kassalargina bor).
-- Shuning uchun "Toshkent 0" — balans sync'ning xatosi EMAS.

-- D.6.1 Markaziy kassa child'larida nima bor
select k.code as kassa, k.name, k.filial_ref,
       c.code as hisob, coalesce(c.pul_turi, c.currency) as tur,
       coalesce((select sum(l.debit - l.credit)
                   from entry_line l join entry e on e.id = l.entry_id
                  where l.account_id = c.id
                    and e.status = 'posted' and e.is_deleted = false), 0) as qoldiq
  from accounts k
  join accounts c on c.parent_id = k.id and c.is_active
 where k.code in ('5011','5012','5110')
 order by k.code, c.code;

-- D.6.2 Transfer sync umuman yozganmi
select coalesce(e.created_by, '(bo''sh)') as kim, count(*) as entrylar,
       min(e.created_at) as birinchi, max(e.created_at) as oxirgi
  from entry e
 where e.source = 'aros_auto' and e.is_deleted = false
 group by 1
 order by 1;

-- D.6.3 Cutoff — transfer sync qaysi sanadan keyingi transferni yozadi
select jsonb_pretty(aros_transfer_cutoff());
-- 'cutoff' null bo'lsa RPC hech narsa yozmaydi (ok:false).
-- cutoff BUGUNGI bo'lsa — undan oldingi hamma transfer "allaqachon singigan"
-- deb hisoblanadi va HECH QACHON yozilmaydi (mantiq shunday, ataylab).

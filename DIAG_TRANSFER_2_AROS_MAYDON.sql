-- =====================================================================
--  DIAG_TRANSFER_2_AROS_MAYDON.sql   (2026-09-09, 2-bosqich)
--  1-bosqich natijasidan kelib chiqqan ANIQ tekshiruvlar.
-- ---------------------------------------------------------------------
--  🟢 FAQAT O'QIYDI.
--
--  ## 1-BOSQICHDA NIMA TOPILDI
--  Bugungi 12 ta «received» transferda summalar HAMMASI 0:
--      naqd 0 · click 0 · payme 0 · dollar 0
--  LEKIN `dollar_rate` TO'G'RI keldi (11850 / 11900).
--
--  `N8N_YOLDA_SYNC.js` ichida bu ikkalasi AYNI joydan o'qiladi:
--      dollar_rate := (i->'document')->>'currency_rate'      ✅ ishlayapti
--      s_cash      := (i->'document')->>'seller_cash'        ❌ 0
--      c_cash      := i->>'confirmed_cash'                   ❌ 0
--
--  Demak `items[].document` MAVJUD va to'la — faqat PUL maydonlarining
--  NOMLARI o'zgargan. Bu Aros adminka yangilanishining bevosita oqibati.
--  Pul yozadigan sinxron ham AYNI maydonlarni o'qiydi -> 0 -> yozmaydi ->
--  Toshkent kassada pul ko'p, Provodkada kam.
--
--  ## 1-SO'ROV n8n POSTGRES da (Aros nusxasi) ishlatiladi — Provodkada EMAS
--  ## 2-3-SO'ROV Provodkada ishlatiladi
-- =====================================================================


-- #####################################################################
--  1-SO'ROV ⭐ — n8n POSTGRES da RUN QILING (Provodka bazasida EMAS!)
--  YANGI maydon nomlarini aniqlaydi. Butun tuzatish shunga bog'liq.
-- #####################################################################
-- ⬇⬇⬇  (a) item darajasidagi kalitlar — `confirmed_*` qayerga ketdi
select distinct k.key as item_kaliti
  from cachier_transfers t,
       jsonb_array_elements(t.items) i,
       jsonb_each(i) k
 where t.id = 1448
 order by 1;
-- ⬆⬆⬆

-- ⬇⬇⬇  (b) document ichidagi kalitlar — `seller_*` qayerga ketdi
select distinct k.key as document_kaliti
  from cachier_transfers t,
       jsonb_array_elements(t.items) i,
       jsonb_each(i->'document') k
 where t.id = 1448
 order by 1;
-- ⬆⬆⬆

-- ⬇⬇⬇  (c) to'liq JSON — yuqoridagilar tushunarsiz bo'lsa shuni yuboring
select t.id, t.status, t.sender_title, t.receiver_title,
       jsonb_pretty(t.items) as items
  from cachier_transfers t
 where t.id = 1448;
-- ⬆⬆⬆

-- ⬇⬇⬇  (d) QACHON buzilgani: kunma-kun 0 bo'lmagan summalar soni.
--        Oxirgi «sog'lom» kunni ko'rsatadi — o'sha kundan keyin sinxron
--        pulsiz ishlagan.
select date(t.received_at) as kun,
       count(*) as transfer,
       count(*) filter (where (
         select coalesce(sum(coalesce((i->>'confirmed_cash')::numeric,0)
                            +coalesce((i->>'confirmed_click')::numeric,0)
                            +coalesce((i->>'confirmed_payme')::numeric,0)),0)
           from jsonb_array_elements(t.items) i) > 0) as summasi_bor
  from cachier_transfers t
 where t.status = 'received'
   and t.received_at > now() - interval '20 days'
 group by 1 order by 1 desc;
-- ⬆⬆⬆


-- #####################################################################
--  2-SO'ROV ⭐⭐ — PROVODKA da. AVGUST BACKLOGI YOZILGANMI?
-- #####################################################################
--  Nega muhim: `aros_transfer_dropped` da 2026-08-08..08-12 orasidagi
--  ~50 transfer `hal_qilindi=false` bo'lib turibdi (cutoff sababli
--  tashlangan, `urinishlar` 443..647). Ular `oxirgi_at`=2026-08-26 da
--  urinishdan TO'XTAGAN — chunki n8n payloadi 14 kunlik oyna beradi va
--  ular oynadan chiqib ketgan. Ya'ni o'z-o'zidan HECH QACHON tiklanmaydi.
--  1-bosqichdagi 1-SO'ROV ularni KO'RA OLMAYDI (`aros_transfer_yolda`
--  ham 14 kunlik oyna bilan to'ladi).
--
--  Bu so'rov: drop logidagi har transfer uchun `entry` bormi.
--  `yozuv_bor=false` qatorlar = HALI HAM YOZILMAGAN PUL.
-- ⬇⬇⬇
select d.tr_id,
       d.received_at,
       d.payload ->> 'kimdan' as kimdan,
       d.payload ->> 'kimga'  as kimga,
       exists (select 1 from entry e
                where e.ext_ref like 'aros_tr:' || d.tr_id || ':%'
                  and e.is_deleted = false) as yozuv_bor
  from aros_transfer_dropped d
 where d.hal_qilindi = false
 order by (exists (select 1 from entry e
                    where e.ext_ref like 'aros_tr:' || d.tr_id || ':%'
                      and e.is_deleted = false)),
          d.received_at;
-- ⬆⬆⬆

-- ⬇⬇⬇  Qisqa xulosa: nechtasi yozilmagan
select count(*) filter (where not yb) as yozilmagan,
       count(*) filter (where yb)     as yozilgan,
       min(received_at) filter (where not yb) as eng_eski_yozilmagan,
       max(received_at) filter (where not yb) as eng_yangi_yozilmagan
  from (
    select d.received_at,
           exists (select 1 from entry e
                    where e.ext_ref like 'aros_tr:' || d.tr_id || ':%'
                      and e.is_deleted = false) as yb
      from aros_transfer_dropped d
     where d.hal_qilindi = false
  ) x;
-- ⬆⬆⬆


-- #####################################################################
--  3-SO'ROV — PROVODKA da. Sinxron umuman ishlayaptimi?
-- #####################################################################
--  Nimani ko'rsatadi: oxirgi transfer yozuvi qachon tushgan. Bugungi
--  sana bo'lmasa — sinxron pul yozishni butunlay to'xtatgan.
-- ⬇⬇⬇
select max(e.created_at)                       as oxirgi_transfer_yozuvi,
       count(*) filter (where e.created_at > now() - interval '1 day')  as bugun,
       count(*) filter (where e.created_at > now() - interval '7 days') as hafta
  from entry e
 where left(e.ext_ref, 8) = 'aros_tr:'
   and e.is_deleted = false;
-- ⬆⬆⬆

-- =====================================================================
--  PROVODKA_PERM_TUR_FIX.sql — tur bola-hisobi ruxsatni PARENT kassadan olsin
-- ---------------------------------------------------------------------
--  Project: Provodka (kxzerccdpcltmzrxutlo).  TaskFix EMAS.
--
--  🔴 PROD'GA CHIQISHDAN OLDIN — cheklangan (kassa_scope='list')
--     foydalanuvchilar uchun BLOKER.
--
--  MUAMMO:
--     perm_op_key() bola-hisobni parentga faqat `currency <> 'UZS'`
--     bo'lganda bog'laydi (valyuta bolasi: 56xx USD…). Pul TURI bolalari
--     esa (naqd/click/payme) currency='UZS' — ya'ni ular uchun kalit
--     o'z id'si bo'lib qoladi.
--
--     Ruxsat esa KASSA darajasida beriladi: admin op_kassa_ids ga
--     5211 (Izza) ni qo'yadi, tur bolalarining (5312 Izza·Naqd va h.k.)
--     id'lari u yerda YO'Q.
--
--     Natija: professional.html da kassa → "💵 Naqd" segmenti tanlansa
--     yozuv 5312 ga ketadi, entry_line trigger'i (trg_perm_guard_entry_line)
--     perm_check_accounts → perm_op_key(5312) = 5312 ni op_kassa_ids da
--     topa olmaydi va yozuvni RAD ETADI (42501). Foydalanuvchi
--     "Ruxsat yo'q" xatosini oladi, sababi esa ko'rinmaydi.
--
--     Admin sezmaydi: is_admin() tekshiruvdan oldin o'tadi.
--
--  YECHIM: kalit qoidasiga `pul_turi is not null` ni qo'shish.
--     "Bu hisob kassaning bolasimi?" degan savolga endi IKKALA belgi ham
--     javob beradi:
--        • currency <> 'UZS'   -> valyuta bolasi (56xx USD, 57xx CNY…)
--        • pul_turi is not null -> pul turi bolasi (naqd/click/payme)
--
--  ⚠️ HODIM KASSALARI TEGILMAYDI — bu shartning butun mohiyati shunda:
--     hodim kassasining parenti 5400 (konteyner guruh), lekin uning
--     currency='UZS' VA pul_turi=NULL. Ya'ni ikkala shart ham ishlamaydi
--     va kalit o'z id'si bo'lib qoladi — hodimga ruxsat aynan o'z
--     kassasiga beriladi, guruhga emas. (parent_id ikki ma'noli —
--     shuning uchun hech qachon yolg'iz parent_id ga tayanilmaydi.)
--
--  IMZO O'ZGARMAYDI: perm_op_key(uuid) -> uuid. create or replace,
--     grant'lar saqlanadi. Faqat qaytariladigan kalit to'g'rilanadi.
--
--  YONDOSH: perms.js dagi keyOf() ham AYNI qoidaga keltirildi (klientda
--     nav/tanlagich filtri). Server bilan klient bir xil o'ylashi shart —
--     aks holda tugma ko'rinadi, lekin saqlashda xato chiqadi.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. AVVAL: muammo sizda BORMI (cheklangan user bo'lmasa — yo'q)
-- ---------------------------------------------------------------------
-- 0.1 kassa_scope='list' foydalanuvchilar bormi
select user_id, kassa_scope,
       coalesce(array_length(op_kassa_ids, 1), 0) as op_kassa_soni,
       can_convert
  from user_perms
 where kassa_scope = 'list';

-- 0.2 ⭐ ASOSIY TEKSHIRUV: har bir cheklangan userning op_kassa_ids idagi
--     kassalarning tur bolalari ruxsatdan CHETDA qolganmi.
--     Qatorlar chiqsa — muammo bor, 1-bo'limni RUN qiling.
select up.user_id,
       k.code  as ruxsat_berilgan_kassa,
       c.code  as chetda_qolgan_bola,
       c.name,
       c.pul_turi
  from user_perms up
  join accounts k on k.id = any(up.op_kassa_ids)
  join accounts c on c.parent_id = k.id
                 and c.is_active
                 and c.pul_turi is not null
 where up.kassa_scope = 'list'
   and not (c.id = any(up.op_kassa_ids))
 order by up.user_id, k.code, c.code;


-- ---------------------------------------------------------------------
-- 1. TUZATISH
-- ---------------------------------------------------------------------
create or replace function perm_op_key(p_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select case
           -- Kassaning bola-hisobi -> ruxsat PARENT kassadan.
           -- Ikkala bola turi ham shu yerda: valyuta (currency<>UZS) va
           -- pul turi (pul_turi to'ldirilgan, currency='UZS').
           when a.parent_id is not null
                and (coalesce(a.currency,'UZS') <> 'UZS' or a.pul_turi is not null)
             then a.parent_id
           -- Aks holda hisobning o'zi. Hodim kassasi (parent = 5400 konteyner,
           -- UZS, pul_turi NULL) SHU YERGA tushadi — ruxsati o'ziga bog'liq.
           else a.id
         end
    from accounts a where a.id = p_id;
$$;

revoke all on function perm_op_key(uuid) from public, anon;
grant execute on function perm_op_key(uuid) to authenticated, service_role;

comment on function perm_op_key(uuid) is
  'Hisob uchun ruxsat kaliti. Kassaning bola-hisobi (valyuta YOKI pul turi) '
  'ruxsatni parent kassadan oladi; hodim kassasi (parent=5400 konteyner) — o''zidan.';


-- ---------------------------------------------------------------------
-- 2. TEKSHIRUV
-- ---------------------------------------------------------------------
-- 2.1 Kalit to'g'ri chiqyaptimi. Kutilgan natija:
--     parent kassa      -> o'zi
--     · Naqd / · Click  -> parent kassa kodi
--     · USD             -> parent kassa kodi
--     hodim kassasi     -> o'zi (5400 EMAS!)
select a.code, a.name, a.pul_turi, a.currency, a.kassa_turi,
       p.code as parent_kod,
       k.code as ruxsat_kaliti,
       case when k.id = a.id then 'o''zi' else 'parentdan' end as qaydan
  from accounts a
  left join accounts p on p.id = a.parent_id
  left join accounts k on k.id = perm_op_key(a.id)
 where a.is_active and a.section = 'pul'
   and (a.parent_id is not null or a.kassa_turi = 'xarajat')
 order by coalesce(p.code, a.code), a.code
 limit 40;

-- 2.2 0.2 ni QAYTA RUN qiling — endi ham qator chiqsa, o'sha kassalar
--     haqiqatan ruxsatdan tashqarida (bu so'rov perm_op_key'ga bog'liq emas,
--     shuning uchun u baribir qator ko'rsatadi — 2.3 aniqroq).

-- 2.3 ⭐ Yakuniy: cheklangan user endi tur bolasiga yoza oladimi.
--     `mumkin` ustuni hamma qatorda true bo'lishi kerak.
select up.user_id, c.code, c.name,
       perm_op_key(c.id) = any(up.op_kassa_ids) as mumkin
  from user_perms up
  join accounts k on k.id = any(up.op_kassa_ids)
  join accounts c on c.parent_id = k.id and c.is_active
 where up.kassa_scope = 'list'
 order by up.user_id, c.code;

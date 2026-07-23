-- =====================================================================
-- PROVODKA — YUK QISMAN TO'LOV (entry_yuk + holat/kurs RPC'lari)
-- ---------------------------------------------------------------------
-- Yuk bo'lib-bo'lib to'lanishi mumkin. entry.yuk_ids faqat "qaysi yuk"ni
-- saqlaydi, "qancha to'langan"ni emas. Shuning uchun har (entry,yuk) juftligi
-- uchun to'langan summa (UZS) alohida saqlanadi: entry_yuk.
--
-- entry.yuk_ids USTUNI QOLADI (eski yozuvlar + eski kod uchun). Yangi yozuvlar
-- IKKALASINI ham to'ldiradi (yuk_ids = idlar, entry_yuk = idlar+summalar).
--
-- Foiz FRONTENDDA hisoblanadi: tolangan_uzs / narx_uzs (narx Aros'dan/n8n).
-- Additive. Asilbek qo'lda RUN qiladi.
-- =====================================================================


-- =====================================================================
-- 1-BO'LIM — entry_yuk jadvali
-- =====================================================================

create table if not exists entry_yuk (
  entry_id  uuid    not null references entry(id) on delete cascade,
  yuk_id    integer not null,
  summa_uzs numeric not null check (summa_uzs > 0),
  primary key (entry_id, yuk_id)
);

create index if not exists entry_yuk_yuk_idx on entry_yuk(yuk_id);

comment on table entry_yuk is
  'Xarajat yozuvidan har yukka tushgan to''lov (UZS). Yuk to''lov holati shundan hisoblanadi.';

-- RLS: authenticated o'qiydi/yozadi (metadata — pul harakati emas, entry_line guard alohida). Anon yopiq.
alter table entry_yuk enable row level security;

drop policy if exists entry_yuk_sel on entry_yuk;
create policy entry_yuk_sel on entry_yuk for select to authenticated using (true);

drop policy if exists entry_yuk_ins on entry_yuk;
create policy entry_yuk_ins on entry_yuk for insert to authenticated with check (true);

drop policy if exists entry_yuk_del on entry_yuk;
create policy entry_yuk_del on entry_yuk for delete to authenticated using (true);   -- kompensatsiya uchun

revoke all on entry_yuk from public, anon;
grant select, insert, delete on entry_yuk to authenticated;


-- =====================================================================
-- 2-BO'LIM — yuk_tolangan_summa(p_ids) — har yuk uchun to'langan jami + entrylar
-- ---------------------------------------------------------------------
-- FAQAT posted + o'chirilmagan entrylar. Foiz frontendda (narx_uzs bilan).
-- =====================================================================

create or replace function yuk_tolangan_summa(p_ids integer[])
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'yuk_id',       y.yuk_id,
           'tolangan_uzs', y.tot,
           'entrylar',     y.entrylar) order by y.yuk_id), '[]'::jsonb)
    from (
      select ey.yuk_id,
             sum(ey.summa_uzs)::numeric as tot,
             jsonb_agg(jsonb_build_object(
               'entry_id',  e.id,
               'entry_date',e.entry_date,
               'summa_uzs', ey.summa_uzs) order by e.entry_date) as entrylar
        from entry_yuk ey
        join entry e on e.id = ey.entry_id
       where e.status = 'posted' and e.is_deleted = false
         and ey.yuk_id = any(coalesce(p_ids, '{}'))
       group by ey.yuk_id
    ) y;
$$;

revoke all on function yuk_tolangan_summa(integer[]) from public, anon;
grant execute on function yuk_tolangan_summa(integer[]) to authenticated;

comment on function yuk_tolangan_summa(integer[]) is
  'Har yuk uchun to''langan jami (UZS) + qaysi entrylardan. entry_yuk dan (posted, o''chirilmagan).';


-- =====================================================================
-- 3-BO'LIM — yuk_kurslar(p_curs) — valyuta → UZS kursi (1 birlik necha so'm)
-- ---------------------------------------------------------------------
-- Mavjud conv_baza_kurs(p_cur) ishlatiladi (USD → aros_usd_rate, boshqasi
-- currency_rate oxirgisi). CHY (Aros) → CNY (currency_rate) moslashtiriladi.
-- UZS = 1. Kurs topilmasa null (frontend "kurs yo'q" deb ko'rsatadi).
-- =====================================================================

create or replace function yuk_kurslar(p_curs text[])
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare c text; m text; r numeric; out jsonb := '{}'::jsonb;
begin
  if p_curs is null then return out; end if;
  foreach c in array p_curs loop
    if c is null or c = '' then continue; end if;
    if upper(c) = 'UZS' then
      r := 1;
    else
      m := case upper(c) when 'CHY' then 'CNY' else upper(c) end;   -- Aros CHY = CNY
      begin
        r := conv_baza_kurs(m);
      exception when others then r := null;
      end;
    end if;
    out := out || jsonb_build_object(c, r);
  end loop;
  return out;
end $$;

revoke all on function yuk_kurslar(text[]) from public, anon;
grant execute on function yuk_kurslar(text[]) to authenticated;

comment on function yuk_kurslar(text[]) is
  'Valyuta kodlari → UZS kursi (conv_baza_kurs; CHY=CNY). UZS=1, topilmasa null.';


-- =====================================================================
-- 4-BO'LIM — Tekshiruv
-- =====================================================================

do $$
begin
  if to_regclass('public.entry_yuk') is null then
    raise exception 'entry_yuk jadvali yaratilmadi';
  end if;
  if to_regprocedure('public.yuk_tolangan_summa(integer[])') is null then
    raise exception 'yuk_tolangan_summa yaratilmadi';
  end if;
  if to_regprocedure('public.yuk_kurslar(text[])') is null then
    raise exception 'yuk_kurslar yaratilmadi';
  end if;
  if to_regprocedure('public.conv_baza_kurs(text)') is null then
    raise notice 'DIQQAT: conv_baza_kurs(text) topilmadi — PROVODKA_KASSA2.sql ishga tushirilganmi? yuk_kurslar null qaytaradi.';
  end if;
  raise notice 'Yuk qisman to''lov DB tayyor. entry_yuk qatorlari: % ta',
    (select count(*) from entry_yuk);
end $$;

-- ============================================================================
--  PROVODKA_GRAFIK_MAQSAD_BOJXONASIZ.sql — 2026-09-19
--  Grafik maqsadi (butun tannarx) dan AROS BOJXONA chiqarildi.
--  Sabab: aros_yuk_bojxona.bojxona_uzs — Aros hujjatidagi KUTILAYOTGAN bojxona, u tannarx
--  LIMITI (yuk_tannarx_qosh tekshiradi), qarz emas. Bojxona haqiqatda to'langanda u
--  yuk_tannarx ga (xizmat to'lovi) tushadi va to'lov bilan yopiladi. Maqsadga ham qo'shilsa
--  IKKI MARTA sanaladi (2026-09-19 tekshiruvi: Zahra ¥466 000 ortiqcha).
--  Endi maqsad = narx + (tannarx − yopiq) / kurs  — Yuklar / Qarz / 5 kunlik qoldiq formulasi
--  bilan bir xil asos. Imzo, kalitlar o'zgarmagan (bojxona_uzs ma'lumot uchun qaytadi).
--  Additive: create or replace, drop yo'q. Asilbek RUN qiladi.
-- ============================================================================

create or replace function _yuk_grafik_maqsad_calc(p_yuk_id integer, p_narx numeric, p_valyuta text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $yg_maqsad_calc$
declare
  v_valyuta text := upper(coalesce(p_valyuta, 'UZS'));
  v_kurs    numeric;
  v_tannarx numeric := 0;
  v_bojxona numeric := 0;
  v_yopiq   numeric := 0;
begin
  if v_valyuta = 'UZS' then
    v_kurs := 1;
  else
    v_kurs := conv_baza_kurs(v_valyuta);
  end if;
  if v_kurs is null or v_kurs <= 0 then
    return jsonb_build_object('ok', false, 'kod', 'kurs_yoq', 'valyuta', v_valyuta);
  end if;

  select coalesce((yuk_tannarx_jami(array[p_yuk_id]) -> p_yuk_id::text ->> 'jami_uzs')::numeric, 0)
    into v_tannarx;
  -- faqat ma'lumot uchun (UI ko'rsatadi) — maqsadga QO'SHILMAYDI
  select coalesce((yuk_bojxona_jami(array[p_yuk_id]) -> p_yuk_id::text ->> 'bojxona_uzs')::numeric, 0)
    into v_bojxona;
  select coalesce(sum(summa_uzs), 0) into v_yopiq
    from yuk_yopiq where yuk_id = p_yuk_id and not is_deleted;

  return jsonb_build_object(
    'ok', true,
    'maqsad', greatest(0, coalesce(p_narx, 0) + (v_tannarx - v_yopiq) / v_kurs),
    'valyuta', v_valyuta,
    'narx', p_narx,
    'tannarx_uzs', v_tannarx,
    'bojxona_uzs', v_bojxona,
    'yopiq_uzs', v_yopiq,
    'kurs', v_kurs);
end
$yg_maqsad_calc$;
revoke all on function _yuk_grafik_maqsad_calc(integer, numeric, text) from public, anon, authenticated;
comment on function _yuk_grafik_maqsad_calc(integer, numeric, text) is
  'ICHKI: grafik maqsadi = narx + (tannarx − yopiq)/kurs. Aros bojxona QOSHILMAYDI (u limit, qarz emas). '
  'ENG OXIRGI versiya: PROVODKA_GRAFIK_MAQSAD_BOJXONASIZ.sql.';

select '_yuk_grafik_maqsad_calc (bojxonasiz)' as obyekt,
       case when pg_get_functiondef('public._yuk_grafik_maqsad_calc(integer,numeric,text)'::regprocedure)
                 like '%(v_tannarx - v_yopiq)%' then '✅' else '❌' end as holat;

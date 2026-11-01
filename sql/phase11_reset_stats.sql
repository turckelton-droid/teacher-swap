-- المرحلة 11: «تصفير العدادات» (المشرف). من غير مسح: app_meta.stats_from — الطلبات اللي اتعملت قبله بتختفي
-- من الإحصائيات والسجل، ماعدا المعلّق/المقبول اللي لسه جاي (عشان الاتفاقات القائمة ماتضيعش). الحسابات والإشعارات زي ما هي.
-- للتراجع: update public.app_meta set stats_from = null where id = 1;
alter table public.app_meta add column if not exists stats_from timestamptz;

do $$
declare f record; d text;
begin
  for f in select * from (values
    ('get_bundle', E'from public.requests r\n      where case when', E'from public.requests r\n      where (r.created_at >= (select coalesce(m.stats_from, ''-infinity'') from public.app_meta m where m.id = 1)\n             or (r.status in (''pending'',''accepted'') and r.on_date >= td))\n        and case when'),
    ('get_bundle', '''has_viewer'', case when s.is_admin', E'''stats_from'', case when s.is_admin then (select m.stats_from from public.app_meta m where m.id = 1) end,\n    ''has_viewer'', case when s.is_admin'),
    ('admin_stats', 'from public.requests r where r.on_date between p_from and p_to)', E'from public.requests r where r.on_date between p_from and p_to\n        and r.created_at >= (select coalesce(m.stats_from, ''-infinity'') from public.app_meta m where m.id = 1))'),
    ('admin_stats', '''today'', td,', '''today'', td, ''reset_at'', (select m.stats_from from public.app_meta m where m.id = 1),')
  ) v(fn, a, b) loop
    select pg_get_functiondef(p.oid) into d from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = f.fn;
    if position(f.a in d) = 0 then raise exception 'pattern not found in %: %', f.fn, f.a; end if;
    execute replace(d, f.a, f.b);
  end loop;
end $$;

create or replace function public.reset_stats(p_token uuid)
returns timestamptz language plpgsql security definer set search_path to 'public' as $$
declare s public.sessions; t timestamptz := now();
begin
  s := public._session(p_token);
  if not coalesce(s.is_admin,false) then raise exception 'not_admin'; end if;
  update public.app_meta set stats_from = t where id = 1;
  return t;
end $$;
grant execute on function public.reset_stats(uuid) to anon, authenticated;

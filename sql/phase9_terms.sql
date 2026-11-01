-- المرحلة 9: بداية الترم يحددها المشرف من صفحة الإحصائيات
alter table public.app_meta add column if not exists term1 date default '2026-09-06';
alter table public.app_meta add column if not exists term2 date default '2027-01-31';
update public.app_meta set term1 = coalesce(term1, '2026-09-06'), term2 = coalesce(term2, '2027-01-31') where id = 1;

create or replace function public.get_terms(p_token uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare s public.sessions;
begin
  s := public._session(p_token);
  if s.token is null then raise exception 'no_session'; end if;
  if not s.is_admin then raise exception 'not_admin'; end if;
  return (select jsonb_build_object('t1', term1, 't2', term2) from public.app_meta where id = 1);
end $$;

create or replace function public.set_terms(p_token uuid, p_t1 date, p_t2 date)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare s public.sessions;
begin
  s := public._session(p_token);
  if s.token is null then raise exception 'no_session'; end if;
  if not s.is_admin or s.is_viewer then raise exception 'not_admin'; end if;
  if p_t1 is null or p_t2 is null or p_t2 <= p_t1 then raise exception 'bad_terms'; end if;
  update public.app_meta set term1 = p_t1, term2 = p_t2 where id = 1;
  return jsonb_build_object('t1', p_t1, 't2', p_t2);
end $$;

grant execute on function public.get_terms(uuid) to anon, authenticated;
grant execute on function public.set_terms(uuid, date, date) to anon, authenticated;

-- المرحلة 8: تسجيل أخطاء البرنامج عند المعلمين وعرضها في صفحة الإحصائيات
create table if not exists public.client_errors(
  id bigserial primary key,
  at timestamptz not null default now(),
  last_at timestamptz not null default now(),
  n int not null default 1,
  teacher_id text, src text, msg text, ua text, page text);
create index if not exists client_errors_last_at on public.client_errors(last_at desc);
alter table public.client_errors enable row level security;

-- بيتنادى من البرنامج؛ التوكن اختياري (ممكن الخطأ يحصل قبل الدخول)
-- نفس الخطأ لنفس المعلم خلال ساعة بيزوّد العدد بس. حد أقصى 300 صف في اليوم. بيمسح الأقدم من 60 يوم.
create or replace function public.log_error(p_token uuid, p_src text, p_msg text, p_ua text, p_page text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare tid text; e bigint;
begin
  if p_token is not null then
    select case when is_admin then 'admin' when is_viewer then 'mgr' else teacher_id end into tid
      from public.sessions where token = p_token;
  end if;
  p_msg := left(coalesce(p_msg, ''), 500); p_src := left(coalesce(p_src, ''), 40);
  select id into e from public.client_errors
    where coalesce(teacher_id, '') = coalesce(tid, '') and msg = p_msg and last_at > now() - interval '1 hour'
    order by last_at desc limit 1;
  if e is not null then
    update public.client_errors set n = n + 1, last_at = now() where id = e; return;
  end if;
  if (select count(*) from public.client_errors where at > now() - interval '1 day') >= 300 then return; end if;
  insert into public.client_errors(teacher_id, src, msg, ua, page)
    values (tid, p_src, p_msg, left(p_ua, 300), left(p_page, 200));
  if random() < 0.05 then delete from public.client_errors where last_at < now() - interval '60 days'; end if;
end $$;

-- للمشرف بس: آخر 100 خطأ في الفترة
create or replace function public.admin_errors(p_token uuid, p_from date, p_to date)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare s public.sessions;
begin
  s := public._session(p_token);
  if s.token is null then raise exception 'no_session'; end if;
  if not s.is_admin then raise exception 'not_admin'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'at', e.at, 'last', e.last_at, 'n', e.n,
      't', e.teacher_id, 'src', e.src, 'msg', e.msg, 'ua', e.ua, 'page', e.page) order by e.last_at desc), '[]')
    from (select * from public.client_errors
          where (last_at at time zone 'Asia/Muscat')::date between p_from and p_to
          order by last_at desc limit 100) e);
end $$;

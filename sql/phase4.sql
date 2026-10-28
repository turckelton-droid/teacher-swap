-- المرحلة 4: حساب المدير (متابعة فقط) + الملخص اليومي + أول دخول بآخر 4 أرقام من الواتساب

alter table public.sessions add column if not exists is_viewer boolean not null default false;

-- رمز المدير (6 أرقام) يحدده المشرف من لوحته
create or replace function public.set_viewer_code(p_token uuid, p_code text)
returns void language plpgsql security definer set search_path to 'public','extensions' as $$
declare s public.sessions;
begin
  s := public._session(p_token);
  if not coalesce(s.is_admin,false) then raise exception 'not_admin'; end if;
  if p_code !~ '^\d{6}$' then raise exception 'code_format'; end if;
  if exists (select 1 from public.settings where key = 'admin_hash' and value = crypt(p_code, value)) then raise exception 'code_same'; end if;
  insert into public.settings values ('viewer_hash', crypt(p_code, gen_salt('bf')))
    on conflict (key) do update set value = excluded.value;
  delete from public.sessions where is_viewer;
  delete from public.push_subs where teacher_id = 'mgr';
end $$;

-- نفس شاشة «دخول المشرف»: رمز المشرف ← لوحة المشرف، رمز المدير ← متابعة فقط
create or replace function public.admin_login(p_code text)
returns uuid language plpgsql security definer set search_path to 'public','extensions' as $$
declare h text; vh text; tok uuid; fails int; until_ts timestamptz;
begin
  select value::timestamptz into until_ts from public.settings where key = 'admin_locked_until';
  if until_ts is not null and until_ts > now() then raise exception 'locked'; end if;
  select value::int into fails from public.settings where key = 'admin_fails';
  select value into h from public.settings where key = 'admin_hash';
  select value into vh from public.settings where key = 'viewer_hash';
  if h is not null and h = crypt(p_code, h) then
    delete from public.settings where key in ('admin_fails','admin_locked_until');
    insert into public.sessions(is_admin) values (true) returning token into tok;
    return tok;
  end if;
  if vh is not null and vh = crypt(p_code, vh) then
    delete from public.settings where key in ('admin_fails','admin_locked_until');
    insert into public.sessions(is_viewer) values (true) returning token into tok;
    return tok;
  end if;
  fails := coalesce(fails,0) + 1;
  if fails >= 10 then
    insert into public.settings values ('admin_locked_until', (now() + interval '15 minutes')::text)
      on conflict (key) do update set value = excluded.value;
    fails := 0;
  end if;
  insert into public.settings values ('admin_fails', fails::text)
    on conflict (key) do update set value = excluded.value;
  return null;
end $$;

-- إشعارات المدير تتخزن باسم 'mgr'
create or replace function public.save_push_sub(p_token uuid, p_sub jsonb)
returns void language plpgsql security definer set search_path to 'public' as $$
declare s public.sessions; ep text; who text;
begin
  s := public._session(p_token);
  who := coalesce(s.teacher_id, case when s.is_viewer then 'mgr' end);
  if who is null then raise exception 'no_session'; end if;
  ep := p_sub->>'endpoint';
  if ep is null or ep !~ '^https://' or length(p_sub::text) > 4000 then raise exception 'bad_sub'; end if;
  insert into public.push_subs(endpoint, teacher_id, sub) values (ep, who, p_sub)
    on conflict (endpoint) do update set teacher_id = excluded.teacher_id, sub = excluded.sub, created_at = now();
end $$;

create or replace function public.test_push(p_token uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
declare s public.sessions; who text;
begin
  s := public._session(p_token);
  who := coalesce(s.teacher_id, case when s.is_viewer then 'mgr' end);
  if who is null then raise exception 'no_session'; end if;
  perform public._push_hook(jsonb_build_object('ev','test','to',who));
end $$;

-- الملخص اليومي للمدير (pg_cron بيناديها)
create or replace function public._daily_summary()
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if extract(isodow from (now() at time zone 'Asia/Muscat')) in (5,6) then return; end if; -- الجمعة والسبت
  perform public._push_hook(jsonb_build_object('ev','summary','to','mgr',
    'date', (now() at time zone 'Asia/Muscat')::date));
end $$;
revoke execute on function public._daily_summary() from public, anon, authenticated;

-- أول دخول: لازم آخر 4 أرقام من الواتساب المسجّل
create or replace function public.setup_account(p_teacher text, p_pin text, p_phone text)
returns uuid language plpgsql security definer set search_path to 'public','extensions' as $$
declare t public.teachers; tok uuid; n int; ph text;
begin
  if p_pin !~ '^\d{4}$' then raise exception 'pin_format'; end if;
  select * into t from public.teachers where id = p_teacher and active;
  if not found then raise exception 'no_teacher'; end if;
  if t.pin_hash is not null then raise exception 'already_set'; end if;
  if t.locked_until is not null and t.locked_until > now() then raise exception 'locked'; end if;
  ph := right(regexp_replace(coalesce(p_phone,''), '\D', '', 'g'), 4);
  if t.phone is null then raise exception 'no_phone'; end if;
  if length(ph) < 4 or ph <> right(regexp_replace(t.phone, '\D', '', 'g'), 4) then
    n := t.failed_attempts + 1;
    if n >= 5 then update public.teachers set failed_attempts = 0, locked_until = now() + interval '15 minutes' where id = p_teacher;
    else update public.teachers set failed_attempts = n where id = p_teacher; end if;
    return null;
  end if;
  update public.teachers set pin_hash = crypt(p_pin, gen_salt('bf')), failed_attempts = 0, locked_until = null where id = p_teacher;
  insert into public.sessions(teacher_id) values (p_teacher) returning token into tok;
  return tok;
end $$;

-- get_bundle: is_viewer + المدير يشوف سجل 60 يوم زي المشرف
create or replace function public.get_bundle(p_token uuid, p_ver bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare s public.sessions; v bigint; b jsonb; td date := (now() at time zone 'Asia/Muscat')::date;
begin
  s := public._session(p_token);
  if s.token is null then raise exception 'no_session'; end if;
  perform public._expire_requests();
  select tt_ver into v from public.app_meta where id = 1;
  b := jsonb_build_object(
    'me', s.teacher_id,
    'is_admin', s.is_admin,
    'is_viewer', s.is_viewer,
    'tt_ver', v,
    'teachers', (select coalesce(jsonb_agg(jsonb_build_object('id',t.id,'name',t.name,'short',t.short,'phone',t.phone,'has_pin',t.pin_hash is not null)), '[]') from public.teachers t where t.active),
    'flags', (select coalesce(jsonb_agg(f), '[]') from public.flags f where f.on_date is null or f.on_date >= current_date - 1),
    'requests', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', r.id, 'kind', r.kind, 'from', r.from_teacher, 'date', r.on_date, 'p', r.period,
        'c', r.class_id, 's', r.subject_id, 'note', r.note, 'status', r.status,
        'by', r.accepted_by, 'cx', r.cancelled_by, 'at', r.created_at, 'dt', r.decided_at,
        'to', (select coalesce(jsonb_agg(jsonb_build_object('t', x.teacher_id, 'r', x.response)), '[]')
               from public.request_targets x where x.request_id = r.id)
      ) order by r.on_date, r.period), '[]')
      from public.requests r
      where r.on_date >= td - case when s.is_admin or s.is_viewer then 60 else 1 end),
    'has_viewer', case when s.is_admin then exists (select 1 from public.settings where key = 'viewer_hash') end
  );
  if p_ver is not null and p_ver = v then
    return b || jsonb_build_object('same', true);
  end if;
  return b || jsonb_build_object(
    'days', (select coalesce(jsonb_agg(d order by d.day), '[]') from public.days d),
    'periods', (select coalesce(jsonb_agg(p order by p.period), '[]') from public.periods p),
    'classes', (select coalesce(jsonb_agg(c), '[]') from public.classes c),
    'subjects', (select coalesce(jsonb_agg(x), '[]') from public.subjects x),
    'schedule', (select coalesce(jsonb_agg(jsonb_build_array(sc.day, sc.period, sc.teacher_id, sc.class_id, sc.subject_id)), '[]') from public.schedule sc)
  );
end $$;

-- الملخص الساعة 12 الضهر بتوقيت مسقط (08:00 UTC)، الأحد..الخميس
create extension if not exists pg_cron;
select cron.schedule('badeel_daily_summary', '0 8 * * 0-4', $$select public._daily_summary()$$);

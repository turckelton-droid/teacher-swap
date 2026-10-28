-- ===== المرحلة 3: إضافة زملاء لطلب قائم، نسيت الرمز، الإشعارات =====
-- (اتشغّل من الشات. سر الـ hook مش متخزن هنا؛ متخزن في جدول push_cfg بس)

-- 1) create_request: لو فيه طلب معلّق لنفس الحصة ونفس النوع، نضيف الزملاء الجدد عليه
create or replace function public.create_request(p_token uuid, p_kind text, p_date date, p_period int, p_targets text[], p_note text)
returns bigint language plpgsql security definer set search_path to 'public' as $$
declare s public.sessions; l public.schedule; nid bigint; ex public.requests;
begin
  s := public._session(p_token);
  if s.teacher_id is null then raise exception 'no_session'; end if;
  if p_kind not in ('cover','swap') then raise exception 'bad_kind'; end if;
  if public._req_deadline(p_date, p_period) <= now() then raise exception 'too_late'; end if;
  select * into l from public.schedule
    where teacher_id = s.teacher_id and day = public._school_day(p_date) and period = p_period limit 1;
  if l.id is null then raise exception 'no_lesson'; end if;
  p_targets := array(select distinct x from unnest(p_targets) x
                     where x <> s.teacher_id and exists (select 1 from public.teachers t where t.id = x and t.active));
  if cardinality(p_targets) = 0 then raise exception 'targets_required'; end if;
  perform public._expire_requests();
  select * into ex from public.requests where from_teacher = s.teacher_id and on_date = p_date and period = p_period
    and status in ('pending','accepted') for update;
  if ex.id is not null then
    if ex.status <> 'pending' or ex.kind <> p_kind then raise exception 'already_requested'; end if;
    insert into public.request_targets(request_id, teacher_id) select ex.id, x from unnest(p_targets) x
      on conflict (request_id, teacher_id) do nothing;
    if (select count(*) from public.request_targets where request_id = ex.id) > 15 then raise exception 'too_many_targets'; end if;
    return ex.id;
  end if;
  if cardinality(p_targets) > 15 then raise exception 'too_many_targets'; end if;
  insert into public.requests(kind, from_teacher, on_date, period, class_id, subject_id, note)
    values (p_kind, s.teacher_id, p_date, p_period, l.class_id, l.subject_id, left(p_note, 200))
    returning id into nid;
  insert into public.request_targets(request_id, teacher_id) select nid, x from unnest(p_targets) x;
  return nid;
end $$;

-- 2) نسيت الرمز: بالرقم المحفوظ (آخر 8 أرقام). بيقفل بعد 5 محاولات غلط، وبيمسح الجلسات القديمة
create or replace function public.reset_pin(p_teacher text, p_phone text, p_pin text)
returns uuid language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare t public.teachers; tok uuid; n int; ph text;
begin
  if p_pin !~ '^\d{4}$' then raise exception 'pin_format'; end if;
  select * into t from public.teachers where id = p_teacher and active;
  if not found then raise exception 'no_teacher'; end if;
  if t.locked_until is not null and t.locked_until > now() then raise exception 'locked'; end if;
  ph := right(regexp_replace(coalesce(p_phone,''), '\D', '', 'g'), 8);
  if t.phone is null or length(ph) < 8 or ph <> right(regexp_replace(t.phone, '\D', '', 'g'), 8) then
    n := t.failed_attempts + 1;
    if n >= 5 then update public.teachers set failed_attempts = 0, locked_until = now() + interval '15 minutes' where id = p_teacher;
    else update public.teachers set failed_attempts = n where id = p_teacher; end if;
    return null;  -- (raise كان هيلغي عدّاد المحاولات)
  end if;
  update public.teachers set pin_hash = crypt(p_pin, gen_salt('bf')), failed_attempts = 0, locked_until = null where id = p_teacher;
  delete from public.push_subs where teacher_id = p_teacher;
  delete from public.sessions where teacher_id = p_teacher;
  insert into public.sessions(teacher_id) values (p_teacher) returning token into tok;
  return tok;
end $$;

-- 3) الإشعارات
create table if not exists public.push_subs (
  endpoint text primary key,
  teacher_id text not null references public.teachers(id) on delete cascade,
  sub jsonb not null,
  created_at timestamptz not null default now()
);
create index if not exists push_subs_t on public.push_subs(teacher_id);
create table if not exists public.push_cfg (id int primary key default 1, hook_url text, hook_secret text, vapid_pub text, vapid_priv text);
alter table public.push_subs enable row level security;
alter table public.push_cfg enable row level security;
revoke all on public.push_subs, public.push_cfg from anon, authenticated;

create or replace function public.save_push_sub(p_token uuid, p_sub jsonb)
returns void language plpgsql security definer set search_path to 'public' as $$
declare s public.sessions; ep text;
begin
  s := public._session(p_token);
  if s.teacher_id is null then raise exception 'no_session'; end if;
  ep := p_sub->>'endpoint';
  if ep is null or ep !~ '^https://' or length(p_sub::text) > 4000 then raise exception 'bad_sub'; end if;
  insert into public.push_subs(endpoint, teacher_id, sub) values (ep, s.teacher_id, p_sub)
    on conflict (endpoint) do update set teacher_id = excluded.teacher_id, sub = excluded.sub, created_at = now();
end $$;

create or replace function public.delete_push_sub(p_endpoint text)
returns void language sql security definer set search_path to 'public' as $$
  delete from public.push_subs where endpoint = p_endpoint;
$$;

create extension if not exists pg_net;

create or replace function public._push_hook(p_body jsonb)
returns void language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare c public.push_cfg;
begin
  select * into c from public.push_cfg where id = 1;
  if c.hook_url is null then return; end if;
  perform net.http_post(url := c.hook_url, body := p_body,
    headers := jsonb_build_object('Content-Type','application/json','x-hook-secret', c.hook_secret));
exception when others then null;  -- الإشعار مايوقفش الطلب أبدًا
end $$;

create or replace function public._tg_target_new() returns trigger language plpgsql security definer set search_path to 'public' as $$
begin perform public._push_hook(jsonb_build_object('ev','new','id',new.request_id,'to',new.teacher_id)); return null; end $$;
drop trigger if exists tg_target_new on public.request_targets;
create trigger tg_target_new after insert on public.request_targets for each row execute function public._tg_target_new();

create or replace function public._tg_req_status() returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if new.status = old.status then return null; end if;
  if new.status in ('accepted','declined') or (new.status = 'cancelled' and old.status = 'accepted') then
    perform public._push_hook(jsonb_build_object('ev', new.status, 'id', new.id, 'prev', old.status));
  end if;
  return null;
end $$;
drop trigger if exists tg_req_status on public.requests;
create trigger tg_req_status after update of status on public.requests for each row execute function public._tg_req_status();

grant execute on function public.reset_pin(text,text,text), public.save_push_sub(uuid,jsonb), public.delete_push_sub(text) to anon;
revoke execute on function public._push_hook(jsonb) from anon, authenticated, public;

-- إشعار تجربة بعد التفعيل
create or replace function public.test_push(p_token uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
declare s public.sessions;
begin
  s := public._session(p_token);
  if s.teacher_id is null then raise exception 'no_session'; end if;
  perform public._push_hook(jsonb_build_object('ev','test','to',s.teacher_id));
end $$;
grant execute on function public.test_push(uuid) to anon;
-- push_cfg: صف واحد (hook_url = .../functions/v1/push، hook_secret، مفاتيح VAPID) — اتملى من الشات، مش هنا.

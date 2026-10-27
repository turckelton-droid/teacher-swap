-- ===== المرحلة 2: طلبات التأمين/التبديل =====
-- شغّل الملف كله مرة واحدة في Supabase SQL Editor.

create table if not exists public.requests (
  id bigserial primary key,
  kind text not null check (kind in ('cover','swap')),
  from_teacher text not null references public.teachers(id) on delete cascade,
  on_date date not null,
  period int not null,
  class_id text,
  subject_id text,
  note text,
  status text not null default 'pending' check (status in ('pending','accepted','declined','cancelled','expired')),
  accepted_by text references public.teachers(id) on delete set null,
  cancelled_by text,
  created_at timestamptz not null default now(),
  decided_at timestamptz
);
create table if not exists public.request_targets (
  request_id bigint not null references public.requests(id) on delete cascade,
  teacher_id text not null references public.teachers(id) on delete cascade,
  response text not null default 'pending' check (response in ('pending','declined')),
  responded_at timestamptz,
  primary key (request_id, teacher_id)
);
create unique index if not exists requests_one_active
  on public.requests(from_teacher, on_date, period) where status in ('pending','accepted');
create index if not exists requests_date on public.requests(on_date);
create index if not exists request_targets_t on public.request_targets(teacher_id);

alter table public.requests enable row level security;
alter table public.request_targets enable row level security;
revoke all on public.requests, public.request_targets from anon, authenticated;

-- وقت بداية الحصة بتوقيت مسقط
create or replace function public._req_deadline(p_date date, p_period int)
returns timestamptz language sql stable security definer set search_path to 'public' as $$
  select ((p_date + coalesce((select starttime::time from public.periods where period = p_period), time '07:00'))
          at time zone 'Asia/Muscat')
$$;

create or replace function public._school_day(p_date date)
returns int language sql immutable as $$
  select case when extract(dow from p_date)::int between 0 and 4 then extract(dow from p_date)::int + 1 end
$$;

create or replace function public._expire_requests()
returns void language sql security definer set search_path to 'public' as $$
  update public.requests set status = 'expired', decided_at = now()
  where status = 'pending' and public._req_deadline(on_date, period) <= now();
$$;

create or replace function public.create_request(p_token uuid, p_kind text, p_date date, p_period int, p_targets text[], p_note text)
returns bigint language plpgsql security definer set search_path to 'public' as $$
declare s public.sessions; l public.schedule; nid bigint;
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
  if cardinality(p_targets) > 15 then raise exception 'too_many_targets'; end if;
  perform public._expire_requests();
  begin
    insert into public.requests(kind, from_teacher, on_date, period, class_id, subject_id, note)
      values (p_kind, s.teacher_id, p_date, p_period, l.class_id, l.subject_id, left(p_note, 200))
      returning id into nid;
  exception when unique_violation then raise exception 'already_requested';
  end;
  insert into public.request_targets(request_id, teacher_id) select nid, x from unnest(p_targets) x;
  return nid;
end $$;

create or replace function public.respond_request(p_token uuid, p_id bigint, p_accept boolean)
returns text language plpgsql security definer set search_path to 'public' as $$
declare s public.sessions; r public.requests; d int;
begin
  s := public._session(p_token);
  if s.teacher_id is null then raise exception 'no_session'; end if;
  perform public._expire_requests();
  select * into r from public.requests where id = p_id for update;
  if r.id is null then raise exception 'not_found'; end if;
  if not exists (select 1 from public.request_targets where request_id = p_id and teacher_id = s.teacher_id) then
    raise exception 'not_target'; end if;
  if r.status <> 'pending' then raise exception 'not_pending'; end if;
  if p_accept then
    d := public._school_day(r.on_date);
    if exists (select 1 from public.schedule where teacher_id = s.teacher_id and day = d and period = r.period)
       or exists (select 1 from public.requests where accepted_by = s.teacher_id and status = 'accepted'
                  and on_date = r.on_date and period = r.period)
       or exists (select 1 from public.flags where teacher_id = s.teacher_id and kind = 'appointment'
                  and on_date = r.on_date and r.period = any(periods))
    then raise exception 'not_free'; end if;
    update public.requests set status = 'accepted', accepted_by = s.teacher_id, decided_at = now() where id = p_id;
    return 'accepted';
  end if;
  update public.request_targets set response = 'declined', responded_at = now()
    where request_id = p_id and teacher_id = s.teacher_id;
  if not exists (select 1 from public.request_targets where request_id = p_id and response = 'pending') then
    update public.requests set status = 'declined', decided_at = now() where id = p_id;
    return 'declined_all';
  end if;
  return 'declined';
end $$;

create or replace function public.cancel_request(p_token uuid, p_id bigint)
returns void language plpgsql security definer set search_path to 'public' as $$
declare s public.sessions; r public.requests;
begin
  s := public._session(p_token);
  if s.token is null then raise exception 'no_session'; end if;
  select * into r from public.requests where id = p_id for update;
  if r.id is null then raise exception 'not_found'; end if;
  if r.status not in ('pending','accepted') then raise exception 'not_active'; end if;
  if not (s.is_admin or r.from_teacher = s.teacher_id or (r.status = 'accepted' and r.accepted_by = s.teacher_id)) then
    raise exception 'not_allowed'; end if;
  update public.requests set status = 'cancelled', decided_at = now(),
    cancelled_by = case when s.is_admin then 'admin' else s.teacher_id end
  where id = p_id;
end $$;

-- get_bundle + الطلبات
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
      where r.on_date >= td - case when s.is_admin then 60 else 1 end)
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

revoke execute on function public._req_deadline(date,int), public._expire_requests() from anon, authenticated, public;
grant execute on function public.create_request(uuid,text,date,int,text[],text), public.respond_request(uuid,bigint,boolean),
  public.cancel_request(uuid,bigint), public.get_bundle(uuid,bigint) to anon;

-- المرحلة 13: قفل ثغرة أرقام الواتساب
-- get_bundle مابقاش بيبعت أرقام الزملاء للمعلم (رقمه هو بس + 'wa' = عنده رقم ولا لأ).
-- الرقم بيتجاب وقت الضغط على زر الواتساب من wa_phone، بحد 15 زميل مختلف في اليوم لكل معلم.
create table if not exists public.wa_lookups (
  teacher_id text not null,
  target text not null,
  on_date date not null,
  at timestamptz not null default now(),
  primary key (teacher_id, target, on_date)
);
alter table public.wa_lookups enable row level security;

create or replace function public.wa_phone(p_token uuid, p_teacher text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare s public.sessions; td date := (now() at time zone 'Asia/Muscat')::date; ph text; n int;
begin
  s := public._session(p_token);
  if s.token is null then raise exception 'no_session'; end if;
  select t.phone into ph from public.teachers t where t.id = p_teacher and t.active and not t.exempt;
  if coalesce(ph, '') = '' then raise exception 'wa_no_phone'; end if;
  if not (s.is_admin or s.is_viewer) then
    if s.teacher_id is null then raise exception 'no_session'; end if;
    if not exists (select 1 from public.wa_lookups w where w.teacher_id = s.teacher_id and w.target = p_teacher and w.on_date = td) then
      select count(*) into n from public.wa_lookups w where w.teacher_id = s.teacher_id and w.on_date = td;
      if n >= 15 then raise exception 'wa_limit'; end if;
      insert into public.wa_lookups(teacher_id, target, on_date) values (s.teacher_id, p_teacher, td)
      on conflict do nothing;
    end if;
  end if;
  return jsonb_build_object('phone', ph);
end $$;

-- get_bundle: نفس المرحلة 12 بس الأرقام للمشرف وصاحبها بس
CREATE OR REPLACE FUNCTION public.get_bundle(p_token uuid, p_ver bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s public.sessions; v bigint; b jsonb; td date := (now() at time zone 'Asia/Muscat')::date;
  ms date := date_trunc('month', (now() at time zone 'Asia/Muscat'))::date;
begin
  s := public._session(p_token);
  if s.token is null then raise exception 'no_session'; end if;
  perform public._expire_requests();
  if not (s.is_admin or s.is_viewer) and s.teacher_id is not null then perform public._log_open(s.teacher_id); end if;
  select tt_ver into v from public.app_meta where id = 1;
  b := jsonb_build_object(
    'me', s.teacher_id,
    'is_admin', s.is_admin,
    'is_viewer', s.is_viewer,
    'tt_ver', v,
    'teachers', (select coalesce(jsonb_agg(jsonb_build_object('id',t.id,'name',t.name,'short',t.short,'phone',case when s.is_admin or t.id = s.teacher_id then t.phone end,'wa',coalesce(t.phone,'') <> '','has_pin',t.pin_hash is not null,'ex',t.exempt)), '[]') from public.teachers t where t.active),
    'flags', (select coalesce(jsonb_agg(f), '[]') from public.flags f where f.on_date is null or f.on_date >= current_date - 1),
    'requests', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', r.id, 'kind', r.kind, 'from', r.from_teacher, 'date', r.on_date, 'p', r.period,
        'c', r.class_id, 's', r.subject_id, 'note', r.note, 'status', r.status,
        'by', r.accepted_by, 'cx', r.cancelled_by, 'at', r.created_at, 'dt', r.decided_at,
        'to', (select coalesce(jsonb_agg(jsonb_build_object('t', x.teacher_id, 'r', x.response)), '[]')
               from public.request_targets x where x.request_id = r.id)
      ) order by r.on_date, r.period), '[]')
      from public.requests r
      where (r.created_at >= (select coalesce(m.stats_from, '-infinity') from public.app_meta m where m.id = 1)
             or (r.status in ('pending','accepted') and r.on_date >= td))
        and case when s.is_admin or s.is_viewer then r.on_date >= least(td - 60, ms)
                 else r.on_date >= td - 1
                   or (r.on_date >= ms and (r.from_teacher = s.teacher_id or r.accepted_by = s.teacher_id)) end),
    'stats_from', case when s.is_admin then (select m.stats_from from public.app_meta m where m.id = 1) end,
    'has_viewer', case when s.is_admin then exists (select 1 from public.settings where key = 'viewer_hash') end,
    'invites', case when s.is_admin and not s.is_viewer then public._invite_info() end
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
end $function$;

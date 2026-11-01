-- المرحلة 12: دعوة المعلمين بالواتساب + تذكير الإشعارات (علامة «أُرسلت»)
create table if not exists public.invites (
  teacher_id text not null,
  kind text not null check (kind in ('join','push')),
  sent_at timestamptz not null default now(),
  primary key (teacher_id, kind)
);
alter table public.invites enable row level security;

create or replace function public.mark_invite(p_token uuid, p_teacher text, p_kind text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare s public.sessions;
begin
  s := public._session(p_token);
  if s.token is null then raise exception 'no_session'; end if;
  if not s.is_admin or s.is_viewer then raise exception 'not_admin'; end if;
  if p_kind not in ('join','push') then raise exception 'bad_kind'; end if;
  insert into public.invites(teacher_id, kind, sent_at) values (p_teacher, p_kind, now())
  on conflict (teacher_id, kind) do update set sent_at = excluded.sent_at;
  return jsonb_build_object('ok', true);
end $$;

-- للمشرف بس: مين مفعّل الإشعارات + آخر دعوة اتبعتت
create or replace function public._invite_info()
returns jsonb language sql security definer set search_path to 'public' as $$
  select jsonb_build_object(
    'push', (select coalesce(jsonb_agg(distinct p.teacher_id), '[]') from public.push_subs p),
    'inv',  (select coalesce(jsonb_object_agg(i.teacher_id || ':' || i.kind, i.sent_at), '{}') from public.invites i)
  )
$$;
revoke all on function public._invite_info() from public, anon, authenticated;

-- get_bundle: نفس المرحلة 11 + 'invites' للمشرف بس
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
    'teachers', (select coalesce(jsonb_agg(jsonb_build_object('id',t.id,'name',t.name,'short',t.short,'phone',t.phone,'has_pin',t.pin_hash is not null,'ex',t.exempt)), '[]') from public.teachers t where t.active),
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

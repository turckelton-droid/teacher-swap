-- المرحلة 7: صفحة «إحصائيات بديل» (للمشرف فقط) + تسجيل فتح البرنامج
-- كل فتح يتسجل في app_opens (صف لكل معلم لكل يوم). n يزيد لو آخر نشاط أقدم من 30 دقيقة.
create table if not exists public.app_opens(
  teacher_id text not null, on_date date not null, n int not null default 1,
  first_at timestamptz not null default now(), last_at timestamptz not null default now(),
  primary key (teacher_id, on_date));
alter table public.app_opens enable row level security;

create or replace function public._log_open(p_teacher text)
returns void language sql security definer set search_path to 'public' as $$
  insert into public.app_opens(teacher_id, on_date) values (p_teacher, (now() at time zone 'Asia/Muscat')::date)
  on conflict (teacher_id, on_date) do update
    set n = app_opens.n + case when app_opens.last_at < now() - interval '30 minutes' then 1 else 0 end,
        last_at = now()
    where app_opens.last_at < now() - interval '2 minutes';
$$;

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
      where case when s.is_admin or s.is_viewer then r.on_date >= least(td - 60, ms)
                 else r.on_date >= td - 1
                   or (r.on_date >= ms and (r.from_teacher = s.teacher_id or r.accepted_by = s.teacher_id)) end),
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
end $function$;


-- إحصائيات المشرف (المدير لأ)
create or replace function public.admin_stats(p_token uuid, p_from date, p_to date)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare s public.sessions; td date := (now() at time zone 'Asia/Muscat')::date; ws date;
begin
  s := public._session(p_token);
  if s.token is null then raise exception 'no_session'; end if;
  if not s.is_admin then raise exception 'not_admin'; end if;
  perform public._expire_requests();
  ws := td - extract(dow from td)::int;  -- الأحد
  return jsonb_build_object(
    'today', td, 'week_start', ws,
    'since', (select min(on_date) from public.app_opens),
    'periods', (select coalesce(jsonb_agg(jsonb_build_object('p',p.period,'s',p.starttime,'e',p.endtime) order by p.period), '[]') from public.periods p),
    'classes', (select coalesce(jsonb_object_agg(c.id, c.name), '{}') from public.classes c),
    'subjects', (select coalesce(jsonb_object_agg(x.id, x.name), '{}') from public.subjects x),
    'week_open', (select count(distinct teacher_id) from public.app_opens where on_date >= ws),
    'teachers', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', t.id, 'name', t.name, 'pin', t.pin_hash is not null,
        'push', exists (select 1 from public.push_subs ps where ps.teacher_id = t.id),
        'last', greatest((select max(last_at) from public.app_opens o where o.teacher_id = t.id),
                         (select max(created_at) from public.sessions x where x.teacher_id = t.id)),
        'days', (select count(*) from public.app_opens o where o.teacher_id = t.id and o.on_date between p_from and p_to),
        'opens', (select coalesce(sum(n),0) from public.app_opens o where o.teacher_id = t.id and o.on_date between p_from and p_to)
      )), '[]') from public.teachers t where t.active),
    'requests', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', r.id, 'kind', r.kind, 'from', r.from_teacher, 'date', r.on_date, 'p', r.period,
        'c', r.class_id, 's', r.subject_id, 'status', r.status, 'by', r.accepted_by, 'cx', r.cancelled_by,
        'at', r.created_at, 'dt', r.decided_at,
        'to', (select coalesce(jsonb_agg(jsonb_build_object('t', x.teacher_id, 'r', x.response, 'rt', x.responded_at)), '[]')
               from public.request_targets x where x.request_id = r.id)
      ) order by r.on_date desc, r.period desc), '[]')
      from public.requests r where r.on_date between p_from and p_to)
  );
end $$;

revoke all on function public._log_open(text) from public, anon, authenticated;

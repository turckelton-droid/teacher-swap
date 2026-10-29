-- المرحلة 6: «تمّت» + إحصائية الشهر
-- المعلم: كل الطلبات من امبارح (زي الأول) + طلباته هو من أول الشهر (عشان إحصائيته).
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

-- المعلم مايقدرش يلغي حصة خلصت (المشرف لسه يقدر)
CREATE OR REPLACE FUNCTION public.cancel_request(p_token uuid, p_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s public.sessions; r public.requests; e text;
begin
  s := public._session(p_token);
  if s.token is null then raise exception 'no_session'; end if;
  select * into r from public.requests where id = p_id for update;
  if r.id is null then raise exception 'not_found'; end if;
  if r.status not in ('pending','accepted') then raise exception 'not_active'; end if;
  if not (s.is_admin or r.from_teacher = s.teacher_id or (r.status = 'accepted' and r.accepted_by = s.teacher_id)) then
    raise exception 'not_allowed'; end if;
  if r.status = 'accepted' and not s.is_admin then
    select endtime into e from public.periods where period = r.period;
    if (r.on_date + coalesce(e, '23:59')::time) <= (now() at time zone 'Asia/Muscat') then raise exception 'done'; end if;
  end if;
  update public.requests set status = 'cancelled', decided_at = now(),
    cancelled_by = case when s.is_admin then 'admin' else s.teacher_id end
  where id = p_id;
end $function$;

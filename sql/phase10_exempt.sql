-- المرحلة 10: إعفاء معلمين (المشرف). المُعفى: مايدخلش، مايظهرش في الاقتراحات ولا الإحصائيات، وطلباته الجاية تتلغي.
-- admin_stats بترجّع ex والصفحة بتفلتر (عشان أسماءهم تفضل في الطلبات القديمة).
-- من غير مسح: جلساته بتترفض في _session، وإشعاراته متسابة (لو اتفعّل تاني ترجع تشتغل).
alter table public.teachers add column if not exists exempt boolean not null default false;

do $$
declare f record; d text;
begin
  for f in select * from (values
    ('list_teachers', 'from public.teachers where active order', 'from public.teachers where active and not exempt order'),
    ('login',         'where id = p_teacher and active;', 'where id = p_teacher and active and not exempt;'),
    ('setup_account', 'where id = p_teacher and active;', 'where id = p_teacher and active and not exempt;'),
    ('reset_pin',     'where id = p_teacher and active;', 'where id = p_teacher and active and not exempt;'),
    ('create_request','t.id = x and t.active)', 't.id = x and t.active and not t.exempt)'),
    ('get_bundle',    '''has_pin'',t.pin_hash is not null)', '''has_pin'',t.pin_hash is not null,''ex'',t.exempt)'),
    ('admin_stats',   '''id'', t.id, ''name'', t.name,', '''id'', t.id, ''name'', t.name, ''ex'', t.exempt,')
  ) v(fn, a, b) loop
    select pg_get_functiondef(p.oid) into d from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = f.fn;
    if position(f.b in d) > 0 then continue; end if;
    if position(f.a in d) = 0 then raise exception 'pattern not found in %', f.fn; end if;
    execute replace(d, f.a, f.b);
  end loop;
end $$;

create or replace function public._session(p_token uuid)
returns public.sessions language sql security definer set search_path to 'public' as $$
  select * from public.sessions s where s.token = p_token and s.created_at > now() - interval '120 days'
    and not exists (select 1 from public.teachers t where t.id = s.teacher_id and t.exempt)
$$;

create or replace function public.set_exempt(p_token uuid, p_teacher text, p_on boolean)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare s public.sessions; n_own int := 0; n_solo int := 0; now_m timestamp := now() at time zone 'Asia/Muscat';
begin
  s := public._session(p_token);
  if not coalesce(s.is_admin,false) then raise exception 'not_admin'; end if;
  update public.teachers set exempt = p_on where id = p_teacher;
  if not found then raise exception 'no_teacher'; end if;
  if not p_on then return jsonb_build_object('cancelled', 0); end if;
  perform public._expire_requests();
  -- طلباته هو، أو اللي قبلها، اللي لسه ماخلصتش
  with c as (
    update public.requests r set status = 'cancelled', decided_at = now(), cancelled_by = 'admin'
    where r.status in ('pending','accepted') and (r.from_teacher = p_teacher or r.accepted_by = p_teacher)
      and (r.on_date + coalesce((select endtime from public.periods p where p.period = r.period), '23:59')::time) > now_m
    returning 1) select count(*) into n_own from c;
  -- طلب معلّق مالوش غير المُعفى → يتلغي
  with c as (
    update public.requests r set status = 'cancelled', decided_at = now(), cancelled_by = 'admin'
    where r.status = 'pending'
      and exists (select 1 from public.request_targets x where x.request_id = r.id and x.teacher_id = p_teacher)
      and not exists (select 1 from public.request_targets x join public.teachers t on t.id = x.teacher_id
                      where x.request_id = r.id and x.response = 'pending' and not t.exempt)
    returning 1) select count(*) into n_solo from c;
  return jsonb_build_object('cancelled', n_own + n_solo);
end $$;
grant execute on function public.set_exempt(uuid, text, boolean) to anon, authenticated;

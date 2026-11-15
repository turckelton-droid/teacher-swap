-- المرحلة 15 — تذكير الحصة المتفق عليها (2026-11-15)
-- قبل بداية الحصة بـ 5 دقائق، إشعار للي هيدخل الحصة (accepted_by) بس — تأمين أو تبديل.
-- cron كل دقيقة من 7:00 لـ 11:59 بتوقيت مسقط (3–7 UTC)، الأحد–الخميس.

create table if not exists public.reminders (
  request_id bigint primary key references public.requests(id) on delete cascade,
  sent_at timestamptz not null default now()
);
alter table public.reminders enable row level security;
revoke all on public.reminders from anon, authenticated;

-- p_now للتجربة بس
create or replace function public._remind_periods(p_now timestamptz default now())
returns int
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  loc timestamp := p_now at time zone 'Asia/Muscat';
  r record;
  n int := 0;
begin
  for r in
    select q.id, (q.on_date + p.starttime::time) as st
    from public.requests q
    join public.periods p on p.period = q.period
    where q.status = 'accepted' and q.accepted_by is not null
      and q.on_date = loc::date
      and (q.on_date + p.starttime::time) - interval '5 minutes' <= loc
      and (q.on_date + p.starttime::time) > loc
      and not exists (select 1 from public.reminders m where m.request_id = q.id)
  loop
    insert into public.reminders(request_id) values (r.id) on conflict do nothing;
    if found then
      perform public._push_hook(jsonb_build_object('ev', 'remind', 'id', r.id,
        'min', ceil(extract(epoch from (r.st - loc)) / 60)::int));
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

revoke all on function public._remind_periods(timestamptz) from public, anon, authenticated;

select cron.schedule('badeel_period_reminders', '* 3-7 * * 0-4', 'select public._remind_periods()');

-- مهلة الـ hook كانت 5 ثواني (الافتراضي) والـ edge function لما تكون نايمة بتاخد أكتر (ملخص 12 وصل لـ timeout يوم 11-15)
create or replace function public._push_hook(p_body jsonb)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare c public.push_cfg;
begin
  select * into c from public.push_cfg where id = 1;
  if c.hook_url is null then return; end if;
  perform net.http_post(url := c.hook_url, body := p_body,
    headers := jsonb_build_object('Content-Type','application/json','x-hook-secret', c.hook_secret),
    timeout_milliseconds := 20000);
exception when others then null;
end $function$;

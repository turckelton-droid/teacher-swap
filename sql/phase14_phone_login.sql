-- المرحلة 14: الدخول برقم الواتساب بدل البحث في قائمة الأسماء
-- بيرجّع رقم المعلم (id) لو الرقم مسجّل، وإلا null (مع تأخير بسيط يبطّئ التخمين)
create or replace function public.find_by_phone(p_phone text)
returns text language plpgsql security definer set search_path = public as $$
declare ph text := right(regexp_replace(coalesce(p_phone,''), '\D', '', 'g'), 8); tid text;
begin
  if length(ph) < 8 then return null; end if;
  select id into tid from public.teachers
   where active and not exempt and phone is not null and right(regexp_replace(phone, '\D', '', 'g'), 8) = ph limit 1;
  if tid is null then perform pg_sleep(0.6); end if;
  return tid;
end $$;
revoke execute on function public.find_by_phone(text) from public;
grant execute on function public.find_by_phone(text) to anon, authenticated;

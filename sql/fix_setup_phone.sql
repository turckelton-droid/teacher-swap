-- الدخول الأول لا يمسح رقم الواتساب المحفوظ من الكشف.
-- لو وصل رقم جديد يُحفظ، ولو فاضي يفضل الرقم القديم.
create or replace function public.setup_account(p_teacher text, p_pin text, p_phone text)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare t public.teachers; tok uuid;
begin
  if p_pin !~ '^\d{4}$' then raise exception 'pin_format'; end if;
  select * into t from public.teachers where id = p_teacher and active;
  if not found then raise exception 'no_teacher'; end if;
  if t.pin_hash is not null then raise exception 'already_set'; end if;
  update public.teachers set pin_hash = crypt(p_pin, gen_salt('bf')),
    phone = coalesce(nullif(regexp_replace(coalesce(p_phone,''), '\D', '', 'g'), ''), phone)
    where id = p_teacher;
  insert into public.sessions(teacher_id) values (p_teacher) returning token into tok;
  return tok;
end $function$;

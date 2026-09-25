-- =====================================================================
--  التقييم الإلكتروني — ترقية «لوحة التحكم»
--  شغّل هذا الملف كاملًا مرة واحدة في:  Supabase → SQL Editor → New query
--  آمن للتكرار (يمكن تشغيله أكثر من مرة بلا ضرر).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) أعمدة جديدة على المستخدمين: حد التقارير + إلزام بتغيير كلمة المرور
-- ---------------------------------------------------------------------
alter table public.profiles
  add column if not exists report_limit   int     not null default 0,   -- ٠ = بلا حد
  add column if not exists must_change_pw boolean not null default false;

-- ---------------------------------------------------------------------
-- 2) جدول إعدادات التطبيق (صف واحد فقط)
-- ---------------------------------------------------------------------
create table if not exists public.app_settings (
  id              int primary key default 1,
  maintenance     boolean not null default false,
  maintenance_msg text    not null default 'التطبيق مغلق مؤقتًا للصيانة. حاول لاحقًا.',
  allow_signup    boolean not null default true,
  auto_approve    boolean not null default false,
  allow_export    boolean not null default true,
  default_limit   int     not null default 0,   -- الحد الافتراضي للمستخدم الجديد
  max_reports     int     not null default 0,   -- سقف التقارير في النظام كله
  notice          text    not null default '',
  updated_at      timestamptz not null default now(),
  constraint app_settings_single check (id = 1)
);

insert into public.app_settings (id) values (1) on conflict (id) do nothing;

alter table public.app_settings enable row level security;

drop policy if exists "settings read"        on public.app_settings;
drop policy if exists "settings write admin" on public.app_settings;
drop policy if exists "settings ins admin"   on public.app_settings;

-- القراءة مفتوحة (لا تحتوي أي سر) حتى تعمل شاشة الدخول ووضع الصيانة قبل تسجيل الدخول
create policy "settings read" on public.app_settings for select using (true);
create policy "settings write admin" on public.app_settings for update
  using (public.my_role() = 'admin') with check (true);
create policy "settings ins admin" on public.app_settings for insert
  with check (public.my_role() = 'admin');

-- ---------------------------------------------------------------------
-- 3) المستخدم الجديد: أول مستخدم يصبح مديرًا،
--    ثم تطبيق «الاعتماد التلقائي» و«الحد الافتراضي» من الإعدادات
-- ---------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  first_user boolean;
  s          public.app_settings;
  new_role   text;
begin
  select not exists (select 1 from public.profiles where role = 'admin') into first_user;
  select * into s from public.app_settings where id = 1;

  if first_user then
    new_role := 'admin';
  elsif coalesce(s.auto_approve, false) then
    new_role := 'entry';
  else
    new_role := 'pending';
  end if;

  insert into public.profiles (id, full_name, email, role, report_limit)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'full_name', new.email),
          new.email,
          new_role,
          case when first_user then 0 else coalesce(s.default_limit, 0) end)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------
-- 4) فرض حد التقارير على مستوى قاعدة البيانات (لا يمكن تجاوزه من المتصفح)
-- ---------------------------------------------------------------------
create or replace function public.enforce_report_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  lim int;
  cap int;
  cnt int;
begin
  select coalesce(report_limit, 0) into lim from public.profiles where id = new.owner;
  if coalesce(lim, 0) > 0 then
    select count(*) into cnt from public.valuations where owner = new.owner;
    if cnt >= lim then
      raise exception 'بلغتَ الحد المسموح من التقارير (%). راجع مدير النظام.', lim
        using errcode = 'check_violation';
    end if;
  end if;

  select coalesce(max_reports, 0) into cap from public.app_settings where id = 1;
  if coalesce(cap, 0) > 0 then
    select count(*) into cnt from public.valuations;
    if cnt >= cap then
      raise exception 'بلغ النظام سقف التقارير (%). راجع مدير النظام.', cap
        using errcode = 'check_violation';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_report_limit on public.valuations;
create trigger trg_report_limit
  before insert on public.valuations
  for each row execute function public.enforce_report_limit();

-- ---------------------------------------------------------------------
-- 5) وضع الصيانة على مستوى قاعدة البيانات:
--    يمنع أي كتابة على التقييمات لغير المدير أثناء الصيانة
-- ---------------------------------------------------------------------
create or replace function public.maint_on()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select maintenance from public.app_settings where id = 1), false);
$$;

drop policy if exists "valuations insert" on public.valuations;
drop policy if exists "valuations update" on public.valuations;

create policy "valuations insert" on public.valuations for insert
  with check (
    public.my_role() in ('entry','entry_export','admin')
    and owner = auth.uid()
    and (not public.maint_on() or public.my_role() = 'admin')
  );
create policy "valuations update" on public.valuations for update
  using (owner = auth.uid() or public.my_role() = 'admin')
  with check (
    (owner = auth.uid() or public.my_role() = 'admin')
    and (not public.maint_on() or public.my_role() = 'admin')
  );

-- ---------------------------------------------------------------------
-- 6) المستخدم يمسح عَلَم «إلزام بتغيير كلمة المرور» عن نفسه بعد التغيير
--    (دالة محصورة بهذا الحقل فقط — لا تسمح بتعديل الصلاحية أو الحد)
-- ---------------------------------------------------------------------
create or replace function public.clear_pw_flag()
returns void
language sql
security definer
set search_path = public
as $$
  update public.profiles set must_change_pw = false where id = auth.uid();
$$;

revoke all on function public.clear_pw_flag() from public;
grant execute on function public.clear_pw_flag() to authenticated;

-- ---------------------------------------------------------------------
-- 7) حذف المستخدم من قِبل المدير
-- ---------------------------------------------------------------------
drop policy if exists "profiles delete admin" on public.profiles;
create policy "profiles delete admin" on public.profiles for delete
  using (public.my_role() = 'admin' and id <> auth.uid());

-- ---------------------------------------------------------------------
-- للتحقق
-- ---------------------------------------------------------------------
-- select * from public.app_settings;
-- select email, role, report_limit, must_change_pw from public.profiles order by created_at;
-- select owner, count(*) from public.valuations group by owner;

-- =====================================================================
--  نظام التقييم الإلكتروني — إعداد قاعدة بيانات التقييم العقاري
--  شغّل هذا الملف كاملًا مرة واحدة في:  Supabase → SQL Editor → New query
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) جدول المستخدمين (الملفات الشخصية والصلاحيات)
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id         uuid primary key references auth.users on delete cascade,
  full_name  text,
  email      text,
  role       text not null default 'pending'
             check (role in ('pending','entry','entry_export','admin','blocked')),
  created_at timestamptz not null default now()
);

-- إنشاء ملف شخصي تلقائيًا عند تسجيل أي مستخدم جديد (بحالة "بانتظار الاعتماد")
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, email)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'full_name', new.email),
          new.email)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- دالة مساعدة تُرجع صلاحية المستخدم الحالي (تتفادى التكرار داخل سياسات RLS)
create or replace function public.my_role()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select role from public.profiles where id = auth.uid();
$$;

-- ---------------------------------------------------------------------
-- 2) جدول التقييمات
-- ---------------------------------------------------------------------
create table if not exists public.valuations (
  id         text primary key,
  name       text,
  form_no    text,
  owner      uuid references auth.users on delete set null,
  by_name    text,
  state      jsonb not null,
  updated_at timestamptz not null default now()
);

create index if not exists valuations_updated_idx on public.valuations (updated_at desc);
create index if not exists valuations_form_idx    on public.valuations (form_no);

-- ---------------------------------------------------------------------
-- 3) سياسات الحماية (RLS) — لا أحد يقرأ أو يكتب إلا بصلاحية معتمدة
-- ---------------------------------------------------------------------
alter table public.profiles   enable row level security;
alter table public.valuations enable row level security;

drop policy if exists "profiles read own"    on public.profiles;
drop policy if exists "profiles read admin"  on public.profiles;
drop policy if exists "profiles insert own"  on public.profiles;
drop policy if exists "profiles update admin" on public.profiles;

create policy "profiles read own"     on public.profiles for select
  using (id = auth.uid());
create policy "profiles read admin"   on public.profiles for select
  using (public.my_role() = 'admin');
create policy "profiles insert own"   on public.profiles for insert
  with check (id = auth.uid());
create policy "profiles update admin" on public.profiles for update
  using (public.my_role() = 'admin') with check (true);

drop policy if exists "valuations read"   on public.valuations;
drop policy if exists "valuations insert" on public.valuations;
drop policy if exists "valuations update" on public.valuations;
drop policy if exists "valuations delete" on public.valuations;

create policy "valuations read"   on public.valuations for select
  using (public.my_role() in ('entry','entry_export','admin'));
create policy "valuations insert" on public.valuations for insert
  with check (public.my_role() in ('entry','entry_export','admin') and owner = auth.uid());
create policy "valuations update" on public.valuations for update
  using (owner = auth.uid() or public.my_role() = 'admin')
  with check (owner = auth.uid() or public.my_role() = 'admin');
create policy "valuations delete" on public.valuations for delete
  using (owner = auth.uid() or public.my_role() = 'admin');

-- ---------------------------------------------------------------------
-- 4) مخزن المرفقات (صور الصك والكروكي وصور العقار) — خاص وغير علني
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('attachments', 'attachments', false)
on conflict (id) do nothing;

drop policy if exists "attach read"   on storage.objects;
drop policy if exists "attach upload" on storage.objects;
drop policy if exists "attach delete" on storage.objects;

create policy "attach read"   on storage.objects for select to authenticated
  using (bucket_id = 'attachments' and public.my_role() in ('entry','entry_export','admin'));
create policy "attach upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'attachments' and public.my_role() in ('entry','entry_export','admin'));
create policy "attach delete" on storage.objects for delete to authenticated
  using (bucket_id = 'attachments' and (owner = auth.uid() or public.my_role() = 'admin'));

-- =====================================================================
-- 5) تعيين المدير الأول
--    سجّل حسابك أولًا من التطبيق، ثم شغّل هذا السطر مرة واحدة
--    بعد تغيير البريد إلى بريدك:
-- =====================================================================
-- update public.profiles set role = 'admin' where email = 'ao545777031@gmail.com';

-- للتحقق من النتيجة:
-- select email, role from public.profiles order by created_at;

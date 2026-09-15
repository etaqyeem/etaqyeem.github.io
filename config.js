/* =====================================================================
   إعدادات الاتصال بقاعدة بيانات Supabase
   ---------------------------------------------------------------------
   ضع هنا القيمتين اللتين تنسخهما من:
   Supabase → Project Settings → API

   1) Project URL      →  url
   2) anon public key  →  anonKey

   ملاحظة: المفتاح العام (anon key) مصمَّم ليكون ظاهرًا في المتصفح،
   وحماية البيانات تتم عبر سياسات RLS في ملف supabase-setup.sql.
   لا تضع هنا أبدًا المفتاح service_role.
   ===================================================================== */

window.APP_CONFIG = {
  url:     "https://cbnlwwwggbqgrjzllxje.supabase.co",
  anonKey: "sb_publishable_6fMC5NEftxTK8d8ui03lZw_uMkS06ga"
};

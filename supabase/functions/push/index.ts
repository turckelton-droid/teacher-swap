// إشعارات «بديل»: الـ trigger في قاعدة البيانات بيندهها بعد أي طلب جديد / قبول / اعتذار الكل / إلغاء اتفاق
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const DAYS = ["الأحد", "الاثنين", "الثلاثاء", "الأربعاء", "الخميس", "الجمعة", "السبت"];
const KIND: Record<string, string> = { cover: "تأمين", swap: "تبديل" };
const first = (n: string) => { const w = String(n || "").trim().split(/\s+/); return /^(عبد|عبدال|أبو|ابو)$/.test(w[0]) && w[1] ? w[0] + " " + w[1] : w[0]; };
let CFG: any = null;

async function send(to: string, title: string, body: string, tag: string) {
  let n = 0;
  const { data: subs } = await db.from("push_subs").select("endpoint,sub").eq("teacher_id", to);
  for (const s of subs || []) {
    try {
      await webpush.sendNotification(s.sub, JSON.stringify({ title, body, tag, url: "./?tab=req" }), { TTL: 6 * 3600, urgency: "high" });
      n++;
    } catch (e: any) {
      if (e?.statusCode === 404 || e?.statusCode === 410) await db.from("push_subs").delete().eq("endpoint", s.endpoint);
      else console.log("push err", e?.statusCode, e?.body || String(e));
    }
  }
  return n;
}

Deno.serve(async (req) => {
  if (!CFG) CFG = (await db.from("push_cfg").select("*").eq("id", 1).single()).data;
  if (!CFG || req.headers.get("x-hook-secret") !== CFG.hook_secret) return new Response("no", { status: 401 });
  const ev = await req.json();
  webpush.setVapidDetails("https://teacher-swap.pages.dev", CFG.vapid_pub, CFG.vapid_priv);
  if (ev.ev === "test") return new Response(JSON.stringify({ sent: await send(ev.to, "تم تفعيل الإشعارات ✓", "ستصلك هنا تنبيهات الطلبات في «بديل».", "test") }));
  const { data: r } = await db.from("requests").select("*").eq("id", ev.id).single();
  if (!r) return new Response("gone");
  const ids = [r.from_teacher, r.accepted_by, ev.to, r.cancelled_by].filter(Boolean);
  const { data: ts } = await db.from("teachers").select("id,name").in("id", ids);
  const nm = (id: string) => "أ. " + first((ts || []).find((t: any) => t.id === id)?.name || "");
  const { data: c } = await db.from("classes").select("name").eq("id", r.class_id).maybeSingle();
  const d = new Date(r.on_date + "T00:00:00Z");
  const when = `${DAYS[d.getUTCDay()]} ${d.getUTCDate()}/${d.getUTCMonth() + 1}، الحصة ${r.period}${c?.name ? " · الصف " + c.name : ""}`;
  const k = KIND[r.kind] || "";
  const out: { to: string; title: string; body: string }[] = [];
  if (ev.ev === "new") {
    if (r.status === "pending") out.push({ to: ev.to, title: `طلب ${k} جديد`, body: `${nm(r.from_teacher)} يطلب منك ${k} حصة ${when}` });
  } else if (ev.ev === "accepted") {
    out.push({ to: r.from_teacher, title: "تم قبول طلبك ✓", body: `${nm(r.accepted_by)} قَبِل ${k} حصة ${when}` });
  } else if (ev.ev === "declined") {
    out.push({ to: r.from_teacher, title: "اعتذر الزملاء عن طلبك", body: `لم يقبل أحد ${k} حصة ${when}. يمكنك إرسال الطلب لزملاء آخرين.` });
  } else if (ev.ev === "cancelled" && ev.prev === "accepted") {
    const by = r.cancelled_by === "admin" ? "المشرف" : nm(r.cancelled_by);
    for (const t of [r.from_teacher, r.accepted_by]) if (t && t !== r.cancelled_by)
      out.push({ to: t, title: "أُلغي اتفاق", body: `ألغى ${by} ${k} حصة ${when}` });
  }
  let sent = 0;
  for (const m of out) sent += await send(m.to, m.title, m.body, "r" + r.id);
  return new Response(JSON.stringify({ sent }), { headers: { "Content-Type": "application/json" } });
});

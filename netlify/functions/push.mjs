// Sends Orbyt push notifications. The database queues a job and calls this with a one-time token.
// This trades the token for the job (and the signing key, which lives in Supabase's Vault), sends one
// notification per device, and reports back which devices have turned notifications off.
import webpush from "web-push";

const SB_URL = process.env.SUPABASE_URL || "https://wqlsmrkmmbydqsuooshc.supabase.co";
const SB_KEY = process.env.SUPABASE_ANON_KEY || "sb_publishable_vmIhLd3MJNWkraNwDe4n_Q_DAMFLavF";

const rpc = (fn, args) => fetch(`${SB_URL}/rest/v1/rpc/${fn}`, {
  method: "POST",
  headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`, "Content-Type": "application/json" },
  body: JSON.stringify(args),
});

export default async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const { id, token } = await req.json().catch(() => ({}));
  if (typeof id !== "string" || typeof token !== "string") return new Response("Bad request", { status: 400 });
  const res = await rpc("push_claim", { p_id: id, p_token: token });
  const job = res.ok ? await res.json() : null;
  if (!job || !Array.isArray(job.subs)) return new Response("No job", { status: 404 });
  webpush.setVapidDetails(job.subject || "mailto:ashleigh@orbytconnect.com", job.public_key, job.private_key);
  const payload = JSON.stringify({ title: job.title, body: job.body, url: job.url, tag: job.tag });
  const gone = [];
  let sent = 0;
  await Promise.all(job.subs.map(async (s) => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 86400, urgency: "high" });
      sent++;
    } catch (e) {
      if (e && (e.statusCode === 404 || e.statusCode === 410)) gone.push(s.endpoint);
      else console.log("push failed", e && e.statusCode, e && e.body);
    }
  }));
  await rpc("push_done", { p_id: id, p_token: token, p_gone: gone, p_sent: sent });
  return Response.json({ sent, gone: gone.length });
};

// Resend calls this when an email is delivered, bounced, marked as spam or clicked.
// It checks Resend's signature (Svix), then records the event on the email's row in the email log.
// Netlify settings this needs (Site configuration > Environment variables, Production):
//   RESEND_WEBHOOK_SECRET  the signing secret of the Resend webhook (whsec_...)
//   ORBYT_BILLING_SECRET   the shared secret already set up for card payments (reused here)
import crypto from "node:crypto";
import { rpc, json, env } from "../lib/stripe.mjs";

const HANDLED = new Set(["email.sent", "email.delivered", "email.delivery_delayed", "email.bounced", "email.complained", "email.opened", "email.clicked"]);

// Svix signatures: base64(HMAC-SHA256(key, `${id}.${timestamp}.${body}`)), key = base64 part of whsec_...
export function checkResend(raw, id, ts, sigHeader, secret) {
  if (!secret) return "RESEND_WEBHOOK_SECRET isn't set in Netlify";
  if (!id || !ts || !sigHeader) return "missing signature headers";
  const age = Math.abs(Date.now() / 1000 - Number(ts));
  if (!Number.isFinite(age) || age > 300) return "timestamp too old";
  let key;
  try { key = Buffer.from(secret.replace(/^whsec_/, ""), "base64"); } catch (_) { return "secret isn't a whsec_ value"; }
  const want = crypto.createHmac("sha256", key).update(`${id}.${ts}.${raw}`).digest("base64");
  const ok = sigHeader.split(" ").some(p => { const [v, s] = p.split(","); if (v !== "v1" || !s) return false;
    const a = Buffer.from(s), b = Buffer.from(want); return a.length === b.length && crypto.timingSafeEqual(a, b); });
  return ok ? "ok" : "signature doesn't match";
}

export default async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const raw = await req.text();
  const why = checkResend(raw, req.headers.get("svix-id"), req.headers.get("svix-timestamp"), req.headers.get("svix-signature"), env("RESEND_WEBHOOK_SECRET"));
  if (why !== "ok") { console.log("resend webhook rejected:", why); return json({ error: "Bad signature", why }, 400); }
  let event;
  try { event = JSON.parse(raw); } catch (_) { return json({ error: "Bad body" }, 400); }
  if (!HANDLED.has(event.type)) return json({ received: true, result: "ignored" });
  try {
    const result = await rpc("email_event_apply", { p_secret: env("ORBYT_BILLING_SECRET"), p_event: event });
    return json({ received: true, result });
  } catch (e) {
    console.log("email_event_apply failed", event.type, e.message);
    return json({ error: "Not recorded yet", why: e.message }, 500); // Resend retries
  }
};

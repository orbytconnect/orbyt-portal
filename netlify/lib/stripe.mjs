// Shared helpers for the Orbyt Stripe functions. No Stripe library: just its REST API.
// Netlify settings this needs (Site configuration > Environment variables):
//   STRIPE_SECRET_KEY      the Stripe secret key (sk_test_... while testing, sk_live_... when live)
//   STRIPE_WEBHOOK_SECRET  the signing secret of the Stripe webhook (whsec_...)
//   ORBYT_BILLING_SECRET   the shared secret Ashleigh creates in her portal (Set up card payments)
import crypto from "node:crypto";

export const SB_URL = process.env.SUPABASE_URL || "https://wqlsmrkmmbydqsuooshc.supabase.co";
export const SB_KEY = process.env.SUPABASE_ANON_KEY || "sb_publishable_vmIhLd3MJNWkraNwDe4n_Q_DAMFLavF";
export const PORTAL = process.env.ORBYT_PORTAL_URL || "https://portal.orbytconnect.com";
const STRIPE = process.env.STRIPE_API || "https://api.stripe.com";

export const json = (body, status = 200) => Response.json(body, { status });
// settings pasted into Netlify sometimes pick up spaces or line breaks
export const env = (k) => String(process.env[k] || "").trim();

// call a database function, as the signed-in person (their token) or as the public key
export async function rpc(fn, args, token) {
  const res = await fetch(`${SB_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { apikey: SB_KEY, Authorization: `Bearer ${token || SB_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify(args || {}),
  });
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch (_) { data = text; }
  if (!res.ok) {
    const msg = (data && (data.message || data.error)) || `Database error ${res.status}`;
    const err = new Error(msg); err.status = res.status; throw err;
  }
  return data;
}

// Stripe wants form encoding, with nested keys like metadata[vendor_id]
export function form(obj, prefix = "", out = new URLSearchParams()) {
  for (const [k, v] of Object.entries(obj)) {
    if (v === undefined || v === null) continue;
    const key = prefix ? `${prefix}[${k}]` : k;
    if (typeof v === "object") form(v, key, out);
    else out.append(key, String(v));
  }
  return out;
}

export async function stripe(path, params) {
  const key = env("STRIPE_SECRET_KEY");
  if (!key) { const e = new Error("Card payments aren't set up yet."); e.status = 503; throw e; }
  const res = await fetch(`${STRIPE}/v1/${path}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/x-www-form-urlencoded" },
    body: form(params).toString(),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    console.log("stripe error", path, res.status, data && data.error && data.error.message);
    const e = new Error("Stripe couldn't start that payment. Try again in a minute."); e.status = 502; throw e;
  }
  return data;
}

// the signed-in person's token, from the portal
export const bearer = (req) => {
  const h = req.headers.get("authorization") || "";
  const m = h.match(/^Bearer\s+(.+)$/i);
  return m ? m[1] : "";
};

// Stripe-Signature: t=timestamp,v1=hmac. Reject anything not signed with our webhook secret, or older than 5 minutes.
export function verifyStripe(raw, header, secret, now = Date.now()) {
  return checkStripe(raw, header, secret, now) === "ok";
}
// the same check, saying why it failed (for the log; never includes the secret)
export function checkStripe(raw, header, secret, now = Date.now()) {
  if (!secret) return "STRIPE_WEBHOOK_SECRET is not set in Netlify";
  if (!secret.startsWith("whsec_")) return `STRIPE_WEBHOOK_SECRET should start with whsec_ but starts with ${secret.slice(0, 3)}...`;
  if (!header) return "no Stripe-Signature header";
  const parts = Object.fromEntries(header.split(",").map((p) => p.split("=")).filter((p) => p.length === 2).map(([k, v]) => [k.trim(), v.trim()]));
  const sigs = header.split(",").filter((p) => p.trim().startsWith("v1=")).map((p) => p.trim().slice(3));
  const t = Number(parts.t);
  if (!t || !sigs.length) return "signature header is malformed";
  if (Math.abs(now / 1000 - t) > 300) return "signature is more than 5 minutes old";
  const expected = crypto.createHmac("sha256", secret).update(`${t}.${raw}`, "utf8").digest("hex");
  return sigs.some((s) => s.length === expected.length && crypto.timingSafeEqual(Buffer.from(s), Buffer.from(expected)))
    ? "ok" : `signature doesn't match (secret is ${secret.length} characters; check it's this webhook's live signing secret)`;
}

// Backup to the webhook: when someone comes back from Stripe Checkout, the portal asks this function to
// confirm the checkout with Stripe directly and record it, so a delayed or failed webhook can't leave them stuck.
// It only acts on a checkout that belongs to the signed-in business.
import { rpc, json, bearer, env } from "../lib/stripe.mjs";

const STRIPE = process.env.STRIPE_API || "https://api.stripe.com";

async function get(path) {
  const key = env("STRIPE_SECRET_KEY");
  if (!key) { const e = new Error("Card payments aren't set up yet."); e.status = 503; throw e; }
  const res = await fetch(`${STRIPE}/v1/${path}`, { headers: { Authorization: `Bearer ${key}` } });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) { console.log("stripe sync error", path, res.status, data && data.error && data.error.message); const e = new Error("Couldn't confirm with Stripe yet."); e.status = 502; throw e; }
  return data;
}

export default async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const token = bearer(req);
  if (!token) return json({ error: "Sign in first." }, 401);
  const { session_id } = await req.json().catch(() => ({}));
  if (!/^cs_[A-Za-z0-9_]+$/.test(session_id || "")) return json({ error: "Missing checkout." }, 400);
  try {
    const mine = await rpc("billing_whoami", {}, token);
    const s = await get(`checkout/sessions/${encodeURIComponent(session_id)}`);
    if (!mine || s.client_reference_id !== mine) return json({ error: "That checkout isn't yours." }, 403);
    if (s.status !== "complete") return json({ result: "not finished", status: s.status });
    const secret = env("ORBYT_BILLING_SECRET");
    const out = [await rpc("billing_apply", { p_secret: secret, p_event: { type: "checkout.session.completed", data: { object: s } } })];
    if (s.mode === "subscription" && s.subscription) {
      const sub = await get(`subscriptions/${encodeURIComponent(typeof s.subscription === "string" ? s.subscription : s.subscription.id)}`);
      out.push(await rpc("billing_apply", { p_secret: secret, p_event: { type: "customer.subscription.updated", data: { object: sub } } }));
    }
    return json({ result: out });
  } catch (e) {
    console.log("stripe sync failed", e.message);
    return json({ error: e.message || "That didn't work." }, e.status && e.status < 500 ? 400 : (e.status || 500));
  }
};

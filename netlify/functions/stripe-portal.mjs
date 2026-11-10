// Opens Stripe's billing page for the signed-in business, where they update their card,
// see receipts, or cancel.
import { rpc, stripe, json, bearer, PORTAL } from "../lib/stripe.mjs";

export default async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const token = bearer(req);
  if (!token) return json({ error: "Sign in first." }, 401);
  try {
    const { customer } = await rpc("billing_portal_info", {}, token);
    const s = await stripe("billing_portal/sessions", { customer, return_url: `${PORTAL}/` });
    return json({ url: s.url });
  } catch (e) {
    return json({ error: e.message || "That didn't work. Try again." }, e.status && e.status < 500 ? 400 : (e.status || 500));
  }
};

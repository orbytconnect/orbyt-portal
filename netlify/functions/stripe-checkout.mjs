// Starts a Stripe Checkout for the signed-in business:
//   kind "listing": a closing partner saves a card for the $20/month marketing listing; the first charge
//                   waits until their 90-day launch offer ends.
//   kind "promo":   a vendor pays $20 once to run their special offer for 30 days.
import { rpc, stripe, json, bearer, PORTAL } from "../lib/stripe.mjs";

export default async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const token = bearer(req);
  if (!token) return json({ error: "Sign in first." }, 401);
  const { kind } = await req.json().catch(() => ({}));
  if (kind !== "listing" && kind !== "promo") return json({ error: "Unknown payment." }, 400);
  try {
    const info = await rpc("billing_checkout_info", { p_kind: kind }, token);
    const listing = kind === "listing";
    const params = {
      mode: listing ? "subscription" : "payment",
      client_reference_id: info.vendor_id,
      success_url: `${PORTAL}/?billing=done&kind=${kind}&session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${PORTAL}/?billing=cancel&kind=${kind}`,
      line_items: { 0: {
        quantity: 1,
        price_data: {
          currency: "usd",
          unit_amount: info.amount || 2000,
          product_data: { name: listing ? "Orbyt closing partner marketing listing" : "Orbyt special offer, 30 days" },
          ...(listing ? { recurring: { interval: "month" } } : {}),
        },
      } },
      metadata: { vendor_id: info.vendor_id, kind },
      allow_promotion_codes: true,
      ...(info.customer ? { customer: info.customer } : { customer_email: info.email || undefined }),
    };
    if (listing) {
      params.payment_method_collection = "always";
      params.subscription_data = { metadata: { vendor_id: info.vendor_id, kind } };
      if (info.trial_end) params.subscription_data.trial_end = Math.floor(new Date(`${info.trial_end}T12:00:00-08:00`).getTime() / 1000);
    } else {
      if (!info.customer) params.customer_creation = "always";
      params.payment_intent_data = { metadata: { vendor_id: info.vendor_id, kind } };
    }
    const session = await stripe("checkout/sessions", params);
    return json({ url: session.url });
  } catch (e) {
    return json({ error: e.message || "That didn't work. Try again." }, e.status && e.status < 500 ? 400 : (e.status || 500));
  }
};

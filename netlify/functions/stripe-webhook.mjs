// Stripe calls this when a card is saved, a payment goes through or fails, or a listing is canceled.
// It checks Stripe's signature, then hands the event to the database with Orbyt's shared secret.
import { rpc, json, checkStripe, env } from "../lib/stripe.mjs";

const HANDLED = new Set(["checkout.session.completed", "invoice.paid", "invoice.payment_failed",
  "customer.subscription.created", "customer.subscription.updated", "customer.subscription.deleted"]);

export default async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const raw = await req.text();
  const why = checkStripe(raw, req.headers.get("stripe-signature"), env("STRIPE_WEBHOOK_SECRET"));
  if (why !== "ok") { console.log("webhook rejected:", why); return json({ error: "Bad signature", why }, 400); }
  let event;
  try { event = JSON.parse(raw); } catch (_) { return json({ error: "Bad body" }, 400); }
  if (!HANDLED.has(event.type)) return json({ received: true, result: "ignored" });
  try {
    const result = await rpc("billing_apply", { p_secret: env("ORBYT_BILLING_SECRET"), p_event: event });
    return json({ received: true, result });
  } catch (e) {
    console.log("billing_apply failed", event.type, event.id, e.message);
    return json({ error: "Not recorded yet", why: /not allowed/i.test(e.message) ? "ORBYT_BILLING_SECRET doesn't match the shared secret in the portal" : e.message }, 500); // Stripe retries
  }
};

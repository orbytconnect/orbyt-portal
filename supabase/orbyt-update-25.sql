-- Orbyt update 25: promotion codes
-- Stripe checkout now shows a "Promotion code" box. A code that covers the whole $20 makes the payment $0, which Stripe
-- marks "no payment required"; a special offer bought that way now goes live just like a paid one.
-- Needs update 21 first. Safe to run more than once.
do $$
declare def text;
begin
  select pg_get_functiondef('public.billing_apply(text, jsonb)'::regprocedure) into def;
  if position('''no_payment_required''' in def) = 0 then
    def := replace(def, $q$o ->> 'payment_status' = 'paid' and$q$, $q$o ->> 'payment_status' in ('paid', 'no_payment_required') and$q$);
    execute def;
  end if;
end $$;

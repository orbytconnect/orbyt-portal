-- Orbyt update 22: a backup for card payments
-- When someone comes back from Stripe, the portal confirms the checkout with Stripe directly, so a late or failed
-- webhook can't leave a partner stuck on "Add my card". This function tells that check which business is signed in.
-- Needs update 21 first. Safe to run more than once.
create or replace function public.billing_whoami() returns uuid
language sql stable security definer set search_path = '' as $$ select public.my_vendor_id() $$;
revoke execute on function public.billing_whoami() from public, anon;
grant execute on function public.billing_whoami() to authenticated;

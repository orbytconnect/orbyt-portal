-- Orbyt update 21: card payments with Stripe
-- 1. Closing partners add a card when they sign up. Stripe charges $20 a month once their 90-day launch offer ends,
--    and every charge is recorded here automatically. They manage their card or cancel in Stripe's billing page.
-- 2. Vendors pay $20 by card to run a special offer, and it goes live for 30 days as soon as the payment clears.
-- 3. Payments are kept by kind (closing partner marketing fees, special offer fees), so reports keep them apart.
-- 4. Stripe tells the portal about payments through portal.orbytconnect.com/.netlify/functions/stripe-webhook.
--    That sender proves itself with a shared secret that Ashleigh creates once in her portal ("Set up card payments");
--    it lives only in Supabase's Vault and in Netlify's settings.
-- Needs updates 19 and 20 first. Safe to run more than once.

-- billing details for each business: only Orbyt and the business itself can read them, and only Stripe events change them
create table if not exists public.vendor_billing (
  vendor_id               uuid primary key references public.vendors (id) on delete cascade,
  stripe_customer_id      text,
  stripe_subscription_id  text,
  billing_status          text,
  billing_card_at         timestamptz,
  billing_cancel_at       date,
  updated_at              timestamptz not null default now()
);
alter table public.vendor_billing enable row level security;
drop policy if exists vendor_billing_read on public.vendor_billing;
create policy vendor_billing_read on public.vendor_billing for select to authenticated
  using (vendor_id = public.my_vendor_id() or public.is_admin());
revoke all on public.vendor_billing from anon;
revoke insert, update, delete on public.vendor_billing from authenticated;
grant select on public.vendor_billing to authenticated;

-- payments by kind, and where they came from
alter table public.listing_payments add column if not exists kind       text not null default 'listing';
alter table public.listing_payments add column if not exists source     text not null default 'manual';
alter table public.listing_payments add column if not exists stripe_ref text;
do $$ begin
  alter table public.listing_payments add constraint listing_payments_kind_check check (kind in ('listing', 'promo'));
exception when duplicate_object then null; end $$;
create unique index if not exists listing_payments_stripe_ref on public.listing_payments (stripe_ref) where stripe_ref is not null;

-- the paid-through date only follows listing payments
create or replace function public.listing_payments_sync() returns trigger
language plpgsql security definer set search_path = '' as $$
declare vid uuid := coalesce(new.vendor_id, old.vendor_id);
begin
  update public.vendor_admin set listing_paid_through = (select max(period_end) from public.listing_payments where vendor_id = vid and kind = 'listing')
   where vendor_id = vid;
  return null;
end $$;
revoke execute on function public.listing_payments_sync() from public, anon, authenticated;

-- card payments start switched off until Ashleigh turns them on
insert into public.settings (key, value, is_public) values ('billing', '{"enabled": false}'::jsonb, true)
on conflict (key) do nothing;

-- Ashleigh's one-time setup: her browser makes the shared secret and it goes straight into the Vault
create or replace function public.billing_setup(p_secret text) returns void
language plpgsql security definer set search_path = '' as $$
declare sid uuid;
begin
  if not public.is_admin() then raise exception 'Only Orbyt can set up payments.'; end if;
  if p_secret !~ '^[a-f0-9]{48,128}$' then raise exception 'That secret doesn''t look right.'; end if;
  select id into sid from vault.decrypted_secrets where name = 'billing_secret' limit 1;
  if sid is null then perform vault.create_secret(p_secret, 'billing_secret', 'Shared secret for the Orbyt Stripe webhook');
  else perform vault.update_secret(sid, p_secret); end if;
  update public.settings set value = value || jsonb_build_object('secret_set_at', now()) where key = 'billing';
end $$;
revoke execute on function public.billing_setup(text) from public, anon;
grant execute on function public.billing_setup(text) to authenticated;

-- first day of a partner's paid listing: the day after their 90 days (from accepting the agreement) or the last paid month
create or replace function public.listing_start(vid uuid) returns date
language sql stable security definer set search_path = '' as $$
  select greatest(
    coalesce((select (min(t.accepted_at) at time zone 'America/Los_Angeles')::date + 91
                from public.terms_acceptances t join public.vendors v on v.user_id = t.user_id
               where v.id = vid and t.version >= 'partner-terms-2026-11-10'),
             (now() at time zone 'America/Los_Angeles')::date + 91),
    coalesce((select listing_paid_through + 1 from public.vendor_admin where vendor_id = vid), date '2000-01-01'))
$$;
revoke execute on function public.listing_start(uuid) from public, anon, authenticated;

-- what the checkout sender needs, for the signed-in business only
create or replace function public.billing_checkout_info(p_kind text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare vid uuid := public.my_vendor_id(); v public.vendors%rowtype; a public.vendor_admin%rowtype; bl public.vendor_billing%rowtype; start date; today date := (now() at time zone 'America/Los_Angeles')::date;
begin
  if vid is null then raise exception 'Sign in with your business account first.'; end if;
  select * into v from public.vendors where id = vid;
  select * into a from public.vendor_admin where vendor_id = vid;
  select * into bl from public.vendor_billing where vendor_id = vid;
  if p_kind = 'listing' then
    if v.kind <> 'closing' then raise exception 'Listings are for closing partners.'; end if;
    if coalesce(bl.billing_status, '') in ('trialing', 'active', 'past_due', 'incomplete') and bl.stripe_subscription_id is not null then
      raise exception 'Your card is already on file. Use Manage billing to change it.';
    end if;
    start := public.listing_start(vid);
    return jsonb_build_object('vendor_id', vid, 'name', v.name, 'email', public.vendor_email(vid), 'customer', bl.stripe_customer_id,
      'kind', 'listing', 'amount', 2000, 'trial_end', case when start > today + 2 then start end);
  elsif p_kind = 'promo' then
    if v.kind = 'closing' then raise exception 'Special offers are for vendor partners.'; end if;
    if coalesce(a.approved, false) = false then raise exception 'Your account needs to be approved first.'; end if;
    if coalesce(trim(v.promo_offer), '') = '' then raise exception 'Add your offer first.'; end if;
    return jsonb_build_object('vendor_id', vid, 'name', v.name, 'email', public.vendor_email(vid), 'customer', bl.stripe_customer_id,
      'kind', 'promo', 'amount', 2000, 'offer', v.promo_offer);
  end if;
  raise exception 'Unknown payment.';
end $$;
revoke execute on function public.billing_checkout_info(text) from public, anon;
grant execute on function public.billing_checkout_info(text) to authenticated;

create or replace function public.billing_portal_info() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c text;
begin
  select stripe_customer_id into c from public.vendor_billing where vendor_id = public.my_vendor_id();
  if c is null then raise exception 'There''s no card on file yet.'; end if;
  return jsonb_build_object('customer', c);
end $$;
revoke execute on function public.billing_portal_info() from public, anon;
grant execute on function public.billing_portal_info() to authenticated;

-- the signed-in business's own billing state (pending accounts can't load the full portal yet)
create or replace function public.billing_mine() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('kind', v.kind, 'has_card', b.stripe_subscription_id is not null and b.billing_status is distinct from 'canceled',
                            'status', b.billing_status, 'start', public.listing_start(v.id),
                            'enabled', coalesce((select (value ->> 'enabled')::boolean from public.settings where key = 'billing'), false))
    from public.vendors v left join public.vendor_billing b on b.vendor_id = v.id where v.id = public.my_vendor_id()
$$;
revoke execute on function public.billing_mine() from public, anon;
grant execute on function public.billing_mine() to authenticated;

-- Stripe events, passed on by the webhook sender with the shared secret
create or replace function public.billing_apply(p_secret text, p_event jsonb) returns text
language plpgsql security definer set search_path = '' as $$
declare
  k text; typ text := p_event ->> 'type'; o jsonb := p_event -> 'data' -> 'object';
  vid uuid; cust text; meta jsonb; n integer; s date; e date; amt numeric; v public.vendors%rowtype; a public.vendor_admin%rowtype;
  today date := (now() at time zone 'America/Los_Angeles')::date; sub text; line jsonb;
begin
  select decrypted_secret into k from vault.decrypted_secrets where name = 'billing_secret' limit 1;
  if k is null or p_secret is null or p_secret <> k then raise exception 'Not allowed'; end if;
  cust := coalesce(o ->> 'customer', case when typ like 'customer.%' and o ->> 'object' = 'customer' then o ->> 'id' end);
  meta := coalesce(o -> 'metadata', '{}'::jsonb)
       || coalesce(o -> 'subscription_details' -> 'metadata', '{}'::jsonb)
       || coalesce(o -> 'parent' -> 'subscription_details' -> 'metadata', '{}'::jsonb);
  begin vid := nullif(meta ->> 'vendor_id', '')::uuid; exception when others then vid := null; end;
  if vid is null and cust is not null then select vendor_id into vid from public.vendor_billing where stripe_customer_id = cust limit 1; end if;
  if vid is null or not exists (select 1 from public.vendors where id = vid) then return 'ignored: no matching business'; end if;
  select * into v from public.vendors where id = vid;
  insert into public.vendor_billing (vendor_id) values (vid) on conflict (vendor_id) do nothing;
  if cust is not null then update public.vendor_billing set stripe_customer_id = cust, updated_at = now() where vendor_id = vid and stripe_customer_id is distinct from cust; end if;

  if typ = 'checkout.session.completed' then
    if o ->> 'mode' = 'subscription' then
      update public.vendor_billing set stripe_subscription_id = coalesce(o ->> 'subscription', stripe_subscription_id), billing_card_at = now(), updated_at = now(),
             billing_status = case when billing_status is null or billing_status = 'canceled' then 'trialing' else billing_status end, billing_cancel_at = null
       where vendor_id = vid;
      return 'card saved';
    elsif o ->> 'mode' = 'payment' and o ->> 'payment_status' = 'paid' and coalesce(meta ->> 'kind', '') = 'promo' then
      select * into a from public.vendor_admin where vendor_id = vid;
      s := greatest(today, case when a.featured and a.featured_until >= today then a.featured_until + 1 else today end);
      e := s + 29;
      amt := coalesce((o ->> 'amount_total')::numeric, 2000) / 100;
      insert into public.listing_payments (vendor_id, amount, period_start, period_end, kind, source, stripe_ref, note)
      values (vid, amt, s, e, 'promo', 'stripe', o ->> 'id', left(v.promo_offer, 200))
      on conflict (stripe_ref) where stripe_ref is not null do nothing;
      get diagnostics n = row_count;
      if n = 0 then return 'already recorded'; end if;
      update public.vendor_admin set featured = true, featured_until = e where vendor_id = vid;
      perform public.orbyt_email(array[public.admin_email()], 'Special offer paid: ' || v.name, 'A special offer is live',
        public.ep('<b>' || public.h(v.name) || '</b> paid ' || to_char(amt, 'FM$999,990.00') || ' by card. Their special offer is live until <b>' || public.date_text(e) || '</b>.')
        || case when coalesce(v.promo_offer, '') <> '' then public.ep('Offer: ' || public.h(v.promo_offer)) else '' end
        || public.ep('If it doesn''t fit, end it from their card in your portal and refund them in Stripe.'),
        'Open your portal', 'admin_promo_paid');
      return 'special offer live';
    end if;
    return 'ignored';
  end if;

  if typ = 'invoice.paid' then
    amt := coalesce((o ->> 'amount_paid')::numeric, 0) / 100;
    if amt <= 0 then return 'ignored: nothing charged'; end if;
    line := o -> 'lines' -> 'data' -> 0;
    s := (to_timestamp(coalesce((line -> 'period' ->> 'start')::bigint, (o ->> 'period_start')::bigint)) at time zone 'America/Los_Angeles')::date;
    e := (to_timestamp(coalesce((line -> 'period' ->> 'end')::bigint, (o ->> 'period_end')::bigint)) at time zone 'America/Los_Angeles')::date - 1;
    if e < s then e := s; end if;
    insert into public.listing_payments (vendor_id, amount, period_start, period_end, kind, source, stripe_ref)
    values (vid, amt, s, e, 'listing', 'stripe', o ->> 'id')
    on conflict (stripe_ref) where stripe_ref is not null do nothing;
    update public.vendor_billing set billing_status = 'active', updated_at = now() where vendor_id = vid and billing_status is distinct from 'canceled';
    return 'payment recorded';
  end if;

  if typ = 'invoice.payment_failed' then
    update public.vendor_billing set billing_status = 'past_due', updated_at = now() where vendor_id = vid;
    perform public.orbyt_email(array[public.admin_email()], 'Card declined: ' || v.name, 'A closing partner payment didn''t go through',
      public.ep('Stripe couldn''t charge <b>' || public.h(v.name) || '</b> for their $20 listing. Stripe will retry, and they can update their card from Manage billing in their portal.'),
      'Open your portal', 'admin_billing_failed');
    return 'payment failed';
  end if;

  if typ in ('customer.subscription.created', 'customer.subscription.updated', 'customer.subscription.deleted') then
    sub := o ->> 'id';
    update public.vendor_billing set
      updated_at = now(),
      stripe_subscription_id = sub,
      billing_status = case when typ = 'customer.subscription.deleted' then 'canceled' else o ->> 'status' end,
      billing_cancel_at = case when typ = 'customer.subscription.deleted' then today
                               when (o ->> 'cancel_at') is not null then (to_timestamp((o ->> 'cancel_at')::bigint) at time zone 'America/Los_Angeles')::date
                               else null end
     where vendor_id = vid;
    if typ = 'customer.subscription.deleted' then
      perform public.orbyt_email(array[public.admin_email()], 'Listing canceled: ' || v.name, 'A closing partner listing ended',
        public.ep('<b>' || public.h(v.name) || '</b>''s closing partner listing was canceled in Stripe, so it no longer shows in the directory.'),
        'Open your portal', 'admin_billing_canceled');
    end if;
    return 'subscription ' || coalesce(o ->> 'status', 'updated');
  end if;
  return 'ignored';
end $$;
revoke execute on function public.billing_apply(text, jsonb) from public;
grant execute on function public.billing_apply(text, jsonb) to anon;

-- canceled listings drop out of the directory
CREATE OR REPLACE FUNCTION public.can_see_vendor(vid uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
as $$
  select public.is_admin()
      or vid = public.my_vendor_id()
      or exists (select 1 from public.bids b where b.vendor_id = vid and public.on_project(b.project_id))
      or exists (select 1 from public.favorites f where f.user_id = auth.uid() and f.vendor_id = vid)
      or exists (select 1 from public.intros i where i.vendor_id = vid and public.on_project(i.project_id))
      -- listed closing partners are an open directory for every active agent
      or (exists (select 1 from public.profiles me where me.id = auth.uid() and me.role = 'agent' and me.status = 'active')
          and exists (select 1 from public.vendors v join public.vendor_admin a on a.vendor_id = v.id
                       where v.id = vid and v.kind = 'closing' and a.approved and coalesce(v.available, true)
                         and not exists (select 1 from public.vendor_billing b where b.vendor_id = v.id and b.billing_status = 'canceled')))
$$;

-- the renewal reminder points to the Renew button, which now takes a card
create or replace function public.promo_run() returns integer language plpgsql security definer set search_path = '' as $$
declare r record; n integer := 0; ended text := ''; card boolean := coalesce((select (value ->> 'enabled')::boolean from public.settings where key = 'billing'), false);
begin
  for r in select a.vendor_id, a.featured_until, v.name from public.vendor_admin a join public.vendors v on v.id = a.vendor_id
            where a.featured and a.featured_until = current_date + 5 and a.promo_reminded_for is distinct from a.featured_until loop
    perform public.orbyt_email(array[public.vendor_email(r.vendor_id)], 'Your Orbyt special offer ends ' || public.date_text(r.featured_until),
      'Your special offer ends soon',
      public.ep('Your special offer runs until <b>' || public.date_text(r.featured_until) || '</b>. Want another 30 days? '
        || case when card then 'Tap Renew on your dashboard to pay $20 by card, and it keeps running.' else 'Tap Renew on your dashboard and I''ll send a payment link.' end),
      'Open your dashboard', 'vendor_promo_renew');
    update public.vendor_admin set promo_reminded_for = r.featured_until where vendor_id = r.vendor_id;
    n := n + 1;
  end loop;
  for r in select a.vendor_id, v.name from public.vendor_admin a join public.vendors v on v.id = a.vendor_id
            where a.featured and a.featured_until is not null and a.featured_until < current_date loop
    update public.vendor_admin set featured = false where vendor_id = r.vendor_id;
    ended := ended || '<li>' || public.h(r.name) || '</li>';
    n := n + 1;
  end loop;
  if ended <> '' then
    perform public.orbyt_email(array[public.admin_email()], 'Special offers ended', 'Special offers ended',
      public.ep('These special offers ran their 30 days and switched off:')
      || '<ul style="font-size:15px;line-height:1.6;margin:0 0 16px;padding-left:20px">' || ended || '</ul>',
      'Open your dashboard', 'admin_promo_ended');
  end if;
  return n;
end $$;
revoke execute on function public.promo_run() from public, anon, authenticated;

-- the sign-up page (before anyone signs in) only needs to know whether card payments are on
create or replace function public.billing_enabled() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select (value ->> 'enabled')::boolean from public.settings where key = 'billing'), false)
$$;
grant execute on function public.billing_enabled() to anon, authenticated;

-- Orbyt update 15: special offers (stored as featured placement)
-- 1. Vendors write their own special offer for Orbyt clients (a short headline and details) and request it,
--    $20 for 30 days. Ashleigh gets an email, sends a payment link, and clicks "Mark offer paid" once it's paid.
--    Agents see the offer next to the vendor's quotes. It doesn't change matching.
-- 2. A special offer has an end date. Marking it paid starts (or extends) 30 days, and the vendor gets a
--    confirmation email. Five days before it ends, the vendor gets a renewal reminder. When it ends, it switches
--    off on its own and Ashleigh gets a note.
-- Safe to run more than once.

alter table public.vendors      add column if not exists promo_offer        text check (promo_offer is null or length(promo_offer) <= 90);
alter table public.vendors      add column if not exists promo_details      text check (promo_details is null or length(promo_details) <= 400);
alter table public.vendors      add column if not exists promo_requested_at timestamptz;
alter table public.vendor_admin add column if not exists featured_until     date;
alter table public.vendor_admin add column if not exists promo_reminded_for date;

-- a vendor asked for featured placement: tell Ashleigh
create or replace function public.vendors_promo_notify() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.promo_requested_at is not null and new.promo_requested_at is distinct from old.promo_requested_at then
    perform public.orbyt_email(array[public.admin_email()], 'Special offer request: ' || new.name,
      new.name || ' wants to run a special offer',
      public.ep(public.h(new.name) || ' asked to run a special offer for Orbyt clients, $20 for 30 days.')
      || case when coalesce(new.promo_offer, '') <> '' then public.ep('Their offer: <b>' || public.h(new.promo_offer) || '</b>'
           || case when coalesce(new.promo_details, '') <> '' then '<br>' || public.h(new.promo_details) else '' end) else '' end
      || public.ep('Send them a $20 payment link at ' || public.h(coalesce(new.email, 'their email')) || '. Once it''s paid, click Mark offer paid on their row in your Vendors tab.'),
      'Open your dashboard', 'admin_promo_request');
  end if;
  return new;
exception when others then
  raise warning 'Orbyt promo email skipped: %', sqlerrm;
  return new;
end $$;
drop trigger if exists vendors_promo_notify on public.vendors;
create trigger vendors_promo_notify after update of promo_requested_at on public.vendors
  for each row execute function public.vendors_promo_notify();
revoke execute on function public.vendors_promo_notify() from public, anon, authenticated;

-- Ashleigh marked it paid (a new or later end date): tell the vendor
create or replace function public.vendor_admin_promo_notify() returns trigger language plpgsql security definer set search_path = '' as $$
declare v public.vendors%rowtype;
begin
  if new.featured and new.featured_until is not null and new.featured_until is distinct from old.featured_until
     and new.featured_until >= current_date then
    select * into v from public.vendors where id = new.vendor_id;
    perform public.orbyt_email(array[public.vendor_email(new.vendor_id)], 'Your Orbyt special offer is live until ' || public.date_text(new.featured_until),
      'Your special offer is live',
      public.ep('Thanks! Your payment is in, and your special offer is live until <b>' || public.date_text(new.featured_until) || '</b>.')
      || public.ep('Agents see it next to your quotes and on your profile, so they can pass the deal on to their clients'
         || case when coalesce(v.promo_offer, '') <> '' then ': <b>' || public.h(v.promo_offer) || '</b>' else '' end || '.')
      || public.ep('You can change your offer anytime from your dashboard.'),
      'Open your dashboard', 'vendor_promo_on');
    update public.vendors set promo_requested_at = null where id = new.vendor_id and promo_requested_at is not null;
  end if;
  return new;
exception when others then
  raise warning 'Orbyt promo email skipped: %', sqlerrm;
  return new;
end $$;
drop trigger if exists vendor_admin_promo_notify on public.vendor_admin;
create trigger vendor_admin_promo_notify after update of featured_until on public.vendor_admin
  for each row execute function public.vendor_admin_promo_notify();
revoke execute on function public.vendor_admin_promo_notify() from public, anon, authenticated;

-- every morning: renewal reminders 5 days out, and switch off promotions that have ended
create or replace function public.promo_run() returns integer language plpgsql security definer set search_path = '' as $$
declare r record; n integer := 0; ended text := '';
begin
  for r in select a.vendor_id, a.featured_until, v.name from public.vendor_admin a join public.vendors v on v.id = a.vendor_id
            where a.featured and a.featured_until = current_date + 5 and a.promo_reminded_for is distinct from a.featured_until loop
    perform public.orbyt_email(array[public.vendor_email(r.vendor_id)], 'Your Orbyt special offer ends ' || public.date_text(r.featured_until),
      'Your special offer ends soon',
      public.ep('Your special offer runs until <b>' || public.date_text(r.featured_until) || '</b>. Want another 30 days? Tap Renew on your dashboard and I''ll send a payment link.'),
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

do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('orbyt-promo', '15 16 * * *', 'select public.promo_run()');
exception when others then
  raise warning 'Daily special offer checks were not scheduled (%). In Supabase, turn on the pg_cron extension under Database, Extensions, then run this script again.', sqlerrm;
end $$;

-- Orbyt update 20: closing partner sign-ups and listing payments
-- 1. A closing partner sign-up now emails (and notifies) you as "New closing partner sign-up", with their license number,
--    instead of "New vendor sign-up".
-- 2. Listing payments: each $20 listing payment you record is kept here, so invoicing and reports can show listing fees
--    separately from vendor job fees. Recording or removing a payment updates the partner's paid-through date.
-- Needs update 19 first. Safe to run more than once.

create table if not exists public.listing_payments (
  id            uuid primary key default gen_random_uuid(),
  vendor_id     uuid not null references public.vendors (id) on delete cascade,
  amount        numeric(10,2) not null default 20 check (amount >= 0),
  period_start  date not null,
  period_end    date not null check (period_end >= period_start),
  paid_at       timestamptz not null default now(),
  note          text,
  created_at    timestamptz not null default now()
);
create index if not exists listing_payments_vendor on public.listing_payments (vendor_id);
alter table public.listing_payments enable row level security;
drop policy if exists listing_payments_admin on public.listing_payments;
create policy listing_payments_admin on public.listing_payments for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists listing_payments_own on public.listing_payments;
create policy listing_payments_own on public.listing_payments for select to authenticated
  using (vendor_id = public.my_vendor_id());
revoke all on public.listing_payments from anon;
grant select, insert, update, delete on public.listing_payments to authenticated;

-- the paid-through date always matches the latest payment on record
create or replace function public.listing_payments_sync() returns trigger
language plpgsql security definer set search_path = '' as $$
declare vid uuid := coalesce(new.vendor_id, old.vendor_id);
begin
  update public.vendor_admin set listing_paid_through = (select max(period_end) from public.listing_payments where vendor_id = vid)
   where vendor_id = vid;
  return null;
end $$;
revoke execute on function public.listing_payments_sync() from public, anon, authenticated;
drop trigger if exists listing_payments_sync on public.listing_payments;
create trigger listing_payments_sync after insert or update or delete on public.listing_payments
  for each row execute function public.listing_payments_sync();

-- the sign-up email says "closing partner"
CREATE OR REPLACE FUNCTION public.profiles_notify()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
as $$
declare
  meta jsonb;
  who  text;
  lbl  text;
begin
  if tg_op = 'INSERT' then
    if new.status = 'pending' then
      select raw_user_meta_data into meta from auth.users where id = new.id;
      who := coalesce(nullif(trim(meta ->> 'company'), ''), new.full_name, new.email);
      lbl := case when new.role = 'vendor' and meta ->> 'partner_kind' = 'closing' then 'closing partner' else new.role end;
      perform public.orbyt_email(array[public.admin_email()],
        'New ' || lbl || ' sign-up: ' || who, 'New ' || lbl || ' sign-up',
        public.ep('<b>' || public.h(who) || '</b>' || case when new.role = 'vendor' and coalesce(meta ->> 'full_name', '') <> '' then ' (' || public.h(meta ->> 'full_name') || ')' else '' end
                  || ' just joined as ' || case when lbl = 'closing partner' then 'a closing partner' when new.role = 'vendor' then 'a vendor partner' else 'an agent' end || '. ' || public.h(new.email)
                  || case when coalesce(new.phone, '') <> '' then ', ' || public.h(new.phone) else '' end || '.')
        || case when coalesce(meta ->> 'services', '') <> '' then public.ep('Services: ' || public.h(array_to_string(public.jsonb_text_array(meta -> 'services'), ', '))) else '' end
        || case when cardinality(new.areas) > 0 then public.ep('Areas: ' || public.h(array_to_string(new.areas, ', '))) else '' end
        || case when lbl = 'closing partner' and coalesce(meta ->> 'license', '') <> '' then public.ep('License: ' || public.h(meta ->> 'license')) else '' end
        || case when coalesce(new.brokerage, '') <> '' then public.ep('Brokerage: ' || public.h(new.brokerage)) else '' end,
        'Review in Orbyt', 'admin_signup');
    end if;
    return new;
  end if;
  if new.status = 'active' and old.status = 'pending' then
    if new.role = 'vendor' and exists (select 1 from public.vendors where user_id = new.id and kind = 'closing') then
      perform public.orbyt_email(array[new.email], 'Your Orbyt closing partner listing is live', 'You''re listed, ' || public.first_name(new.full_name),
        public.ep('Thanks for your patience while I checked your license. Your listing is now live in the Orbyt closing partner directory, where agents in the network can find you and your business overview.')
        || public.ep('Your first 90 days are free. After that, your marketing listing is $20 a month, and you can cancel anytime.'),
        'Sign in to Orbyt', 'approved');
    elsif new.role = 'vendor' then
      perform public.orbyt_email(array[new.email], 'You''re approved for the Orbyt network', 'You''re in, ' || public.first_name(new.full_name),
        public.ep('Thanks for your patience while I checked everything. You''re approved as an Orbyt vendor partner.')
        || public.ep('When you sign in, you''ll see exactly what Orbyt costs (you only pay when an introduction turns into a paid job) and the insurance paperwork your services need.'),
        'Sign in to Orbyt', 'approved');
    elsif new.role = 'agent' then
      perform public.orbyt_email(array[new.email], 'You''re approved for Orbyt', 'You''re in, ' || public.first_name(new.full_name),
        public.ep('Your Orbyt account is ready. Add your first project with the address and what the home needs, and I''ll start lining up vendors matched to it.')
        || public.ep('You''ll get an email here as soon as bids come in.'),
        'Start a project', 'approved');
    end if;
  end if;
  return new;
exception when others then
  raise warning 'Orbyt sign-up email skipped: %', sqlerrm;
  return new;
end $$;


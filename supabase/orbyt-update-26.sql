-- Orbyt update 26: special offers can run for fewer than 30 days
-- 1. When a vendor pays $20 for a special offer, they pick the end date, up to 30 days. Checkout passes it along,
--    and the offer runs from today (or the day after their current offer ends) through that date.
-- 2. While an offer is live, the vendor can end it sooner. They can't extend it without paying again.
-- Needs update 21 first. Safe to run more than once.
do $$
declare def text;
begin
  select pg_get_functiondef('public.billing_apply(text, jsonb)'::regprocedure) into def;
  if position('promo_end' in def) = 0 then
    def := replace(def, $q$      e := s + 29;$q$,
      $q$      e := s + 29;
      begin
        if (meta ->> 'promo_end') ~ '^\d{4}-\d{2}-\d{2}$' and (meta ->> 'promo_end')::date between s and s + 29 then e := (meta ->> 'promo_end')::date; end if;
      exception when others then null;
      end;$q$);
    execute def;
  end if;
end $$;

-- a vendor ends their live offer sooner (today at the earliest)
create or replace function public.promo_set_end(p_end date) returns date
language plpgsql security definer set search_path = '' as $$
declare vid uuid := public.my_vendor_id(); cur date; today date := (now() at time zone 'America/Los_Angeles')::date;
begin
  if vid is null then raise exception 'Sign in with your business account first.'; end if;
  select featured_until into cur from public.vendor_admin where vendor_id = vid and featured;
  if cur is null or cur < today then raise exception 'You don''t have a special offer running.'; end if;
  if p_end is null or p_end < today then raise exception 'Pick today or a later date.'; end if;
  if p_end > cur then raise exception 'Your offer is paid through %. To run it longer, renew it when it ends.', to_char(cur, 'Mon FMDD'); end if;
  update public.vendor_admin set featured_until = p_end, promo_reminded_for = null where vendor_id = vid;
  return p_end;
end $$;
revoke execute on function public.promo_set_end(date) from public, anon;
grant execute on function public.promo_set_end(date) to authenticated;

-- the "your offer is live" email only goes out for a new or longer offer, not when a vendor ends one sooner
do $$
declare def text;
begin
  select pg_get_functiondef('public.vendor_admin_promo_notify()'::regprocedure) into def;
  if position('new.featured_until > old.featured_until' in def) = 0 then
    def := replace(def, $q$new.featured_until is distinct from old.featured_until$q$,
                        $q$(old.featured_until is null or new.featured_until > old.featured_until)$q$);
    execute def;
  end if;
end $$;

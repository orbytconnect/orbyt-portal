-- Orbyt update 28: closing partner ads
-- Closing partners write their own ad for their directory listing: a headline, a short pitch, and an optional logo
-- or photo (stored in the public vendor-public folder, like the business overview PDF). Agents see it on the listing.
-- Safe to run more than once.
alter table public.vendors add column if not exists ad_headline text;
alter table public.vendors add column if not exists ad_body text;
alter table public.vendors add column if not exists ad_image text;
do $$ begin
  alter table public.vendors add constraint vendors_ad_len check (length(coalesce(ad_headline, '')) <= 80 and length(coalesce(ad_body, '')) <= 400);
exception when duplicate_object then null; end $$;

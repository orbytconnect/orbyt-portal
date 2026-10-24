-- Orbyt portal: update 6
-- Vendors' typical pricing (only Orbyt and the vendor can see it). Safe to run more than once.
alter table public.vendor_private add column if not exists pricing jsonb not null default '{}';

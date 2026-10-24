-- Orbyt portal: update 3
-- Signed Vendor Network Agreements, kept on each vendor's profile. Safe to run more than once.
create table if not exists public.vendor_agreements (
  id             uuid primary key default gen_random_uuid(),
  vendor_id      uuid not null references public.vendors (id) on delete cascade,
  user_id        uuid references auth.users (id) on delete set null,
  version        text not null,
  legal_name     text not null,
  signer_name    text not null,
  signer_title   text,
  signer_email   text,
  details        jsonb not null default '{}',
  document_html  text not null,
  user_agent     text,
  signed_at      timestamptz not null default now()
);
create index if not exists vendor_agreements_vendor_idx on public.vendor_agreements (vendor_id);
alter table public.vendor_agreements enable row level security;

-- the signer and the time always come from the server, never from the browser
create or replace function public.vendor_agreements_stamp()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.user_id := auth.uid();
  new.signed_at := now();
  return new;
end $$;
drop trigger if exists vendor_agreements_stamp on public.vendor_agreements;
create trigger vendor_agreements_stamp before insert on public.vendor_agreements
  for each row execute function public.vendor_agreements_stamp();

drop policy if exists vendor_agreements_read on public.vendor_agreements;
drop policy if exists vendor_agreements_sign on public.vendor_agreements;
drop policy if exists vendor_agreements_admin on public.vendor_agreements;
-- a vendor sees their own; Ashleigh sees all
create policy vendor_agreements_read on public.vendor_agreements for select to authenticated
  using (public.is_admin() or vendor_id = public.my_vendor_id());
-- only an approved vendor can sign, and only for their own business
create policy vendor_agreements_sign on public.vendor_agreements for insert to authenticated
  with check (vendor_id = public.my_vendor_id() and public.is_active());
-- signed agreements can't be edited; only Ashleigh can remove one
create policy vendor_agreements_admin on public.vendor_agreements for delete to authenticated
  using (public.is_admin());

grant select, insert, delete on public.vendor_agreements to authenticated;
revoke all on public.vendor_agreements from anon;
revoke execute on function public.vendor_agreements_stamp() from public, anon, authenticated;

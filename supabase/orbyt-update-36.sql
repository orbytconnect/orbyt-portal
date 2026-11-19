-- Orbyt update 36: approve vendors once everything's in
-- 1. Every vendor uploads a current liability insurance certificate before approval (not just the higher-risk trades).
-- 2. When a vendor or closing partner finishes setting up, Ashleigh gets one email: "ready for your review".
-- Needs update 35 first. Safe to run more than once.

alter table public.vendor_admin add column if not exists ready_notified_at timestamptz;

CREATE OR REPLACE FUNCTION public.vendor_setup_missing(p_vendor uuid)
 RETURNS text[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select case when v.kind = 'closing' then array_remove(array[
    case when cardinality(v.service_details) = 0 then 'specific services' end,
    case when length(trim(coalesce(v.license_number, ''))) < 3 then 'license number' end,
    case when coalesce(v.years_in_business, '') = '' then 'years in business' end,
    case when coalesce((select (value ->> 'enabled')::boolean from public.settings where key = 'billing'), false)
          and not exists (select 1 from public.vendor_billing b where b.vendor_id = v.id and b.stripe_subscription_id is not null and coalesce(b.billing_status, '') <> 'canceled')
         then 'card on file' end], null)
  else array_remove(array[
    case when cardinality(v.service_details) = 0 then 'specific services' end,
    case when coalesce(v.years_in_business, '') = '' then 'years in business' end,
    case when coalesce(v.team_size, '') = '' then 'team size' end,
    case when coalesce(v.lead_time, '') = '' then 'typical lead time' end,
    case when length(trim(coalesce(p.references_text, ''))) < 10 then 'agent references' end,
    case when coalesce(p.insurance ->> 'path', '') = '' then 'certificate of insurance' end], null) end
  from public.vendors v left join public.vendor_private p on p.vendor_id = v.id
  where v.id = p_vendor
$function$;

create or replace function public.vendor_ready_check(p_vendor uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v public.vendors%rowtype; a public.vendor_admin%rowtype; url text;
begin
  select * into a from public.vendor_admin where vendor_id = p_vendor;
  if a.vendor_id is null or a.approved or a.ready_notified_at is not null then return; end if;
  if cardinality(coalesce(public.vendor_setup_missing(p_vendor), '{}')) > 0 then return; end if;
  select * into v from public.vendors where id = p_vendor;
  if v.user_id is null then return; end if;
  update public.vendor_admin set ready_notified_at = now() where vendor_id = p_vendor;
  perform public.orbyt_email(array[public.admin_email()], v.name || ' is ready for your review',
    'Ready to approve: ' || public.h(v.name),
    public.ep(public.h(v.name) || case when v.kind = 'closing' then ' (closing partner)' else '' end || ' finished setting up: '
      || case when v.kind = 'closing' then 'license, years in business and services are in.' else 'references, insurance, business details and services are in.' end)
    || public.ep('Check them, then approve from their card in the vendor list.'),
    'Review in Orbyt', 'ready_review');
exception when others then
  raise warning 'Orbyt ready email skipped: %', sqlerrm;
end $$;
revoke execute on function public.vendor_ready_check(uuid) from public, anon, authenticated;

create or replace function public.vendor_ready_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform public.vendor_ready_check(coalesce((to_jsonb(new) ->> 'vendor_id')::uuid, (to_jsonb(new) ->> 'id')::uuid));
  return new;
end $$;
revoke execute on function public.vendor_ready_trg() from public, anon, authenticated;
drop trigger if exists vendor_ready_v on public.vendors;
create trigger vendor_ready_v after update on public.vendors for each row execute function public.vendor_ready_trg();
drop trigger if exists vendor_ready_p on public.vendor_private;
create trigger vendor_ready_p after insert or update on public.vendor_private for each row execute function public.vendor_ready_trg();
drop trigger if exists vendor_ready_b on public.vendor_billing;
create trigger vendor_ready_b after insert or update on public.vendor_billing for each row execute function public.vendor_ready_trg();

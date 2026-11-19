-- Orbyt update 37: insurance timing matches the Vendor Terms (Schedule 3)
-- Higher-risk trades upload their certificate (naming Orbyt LLC) before approval, since it's needed before the first introduction.
-- Everyone else uploads within 30 days after approval, so insurance isn't on their setup list.
-- Run after update 36. Safe to run more than once.

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
    case when public.insurance_group(v.services) = 'high' and coalesce(p.insurance ->> 'path', '') = '' then 'certificate of insurance' end], null) end
  from public.vendors v left join public.vendor_private p on p.vendor_id = v.id
  where v.id = p_vendor
$function$;

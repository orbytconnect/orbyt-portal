-- Orbyt update 30: two-step closing partner sign-up
-- Closing partners now create their account first, then add their license number and years in business
-- (and their card, when card payments are on) while they wait for approval.
-- They get the same reminders as vendors: about 1, 4 and 7 days after sign-up, then weekly until they finish.
-- Run update 29 first. Safe to run more than once.

create or replace function public.vendor_setup_missing(p_vendor uuid) returns text[]
language sql stable security definer set search_path = '' as $$
  select case when v.kind = 'closing' then array_remove(array[
    case when length(trim(coalesce(v.license_number, ''))) < 3 then 'license number' end,
    case when coalesce(v.years_in_business, '') = '' then 'years in business' end,
    case when coalesce((select (value ->> 'enabled')::boolean from public.settings where key = 'billing'), false)
          and not exists (select 1 from public.vendor_billing b where b.vendor_id = v.id and b.stripe_subscription_id is not null and coalesce(b.billing_status, '') <> 'canceled')
         then 'card on file' end], null)
  else array_remove(array[
    case when coalesce(v.years_in_business, '') = '' then 'years in business' end,
    case when coalesce(v.team_size, '') = '' then 'team size' end,
    case when coalesce(v.lead_time, '') = '' then 'typical lead time' end,
    case when length(trim(coalesce(p.references_text, ''))) < 10 then 'agent references' end], null) end
  from public.vendors v left join public.vendor_private p on p.vendor_id = v.id
  where v.id = p_vendor
$$;
revoke execute on function public.vendor_setup_missing(uuid) from public, anon, authenticated;

create or replace function public.vendor_setup_send(p_vendor uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
declare v public.vendors%rowtype; miss text[]; confirmed boolean; first text; body text; n integer; cp boolean;
begin
  select * into v from public.vendors where id = p_vendor;
  if v.id is null or v.user_id is null then return false; end if;
  miss := public.vendor_setup_missing(p_vendor);
  if coalesce(array_length(miss, 1), 0) = 0 then return false; end if;
  cp := coalesce(v.kind, '') = 'closing';
  select email_confirmed_at is not null into confirmed from auth.users where id = v.user_id;
  select coalesce(setup_reminders, 0) into n from public.vendor_admin where vendor_id = v.id;
  first := split_part(coalesce(nullif(v.contact_name, ''), ''), ' ', 1);
  body := '<p style="font-size:15px;line-height:1.6;margin:0 0 12px">Hi' || case when first <> '' then ' ' || public.h(first) else '' end || ',</p>'
       || '<p style="font-size:15px;line-height:1.6;margin:0 0 12px">Thanks for starting your Orbyt sign-up for ' || public.h(v.name)
       || case when cp then '. Before I can check your license and publish your listing in the closing partner directory, I need a few more details:</p>'
               else '. Before I can review your profile and introduce you to agents, I need a few more details:</p>' end
       || '<ul style="font-size:15px;line-height:1.6;margin:0 0 12px;padding-left:20px">'
       || (select string_agg('<li>' || public.h(upper(left(m, 1)) || substr(m, 2))
                  || case when m = 'card on file' then ' (nothing is charged during your 90-day launch offer)' else '' end || '</li>', '') from unnest(miss) m)
       || '</ul><p style="font-size:15px;line-height:1.6;margin:0 0 12px">It takes about 2 minutes. Sign in and you''ll land right on the form.</p>'
       || case when not coalesce(confirmed, false) then
            '<p style="font-size:15px;line-height:1.6;margin:0 0 12px">First, confirm your email with the link I sent when you signed up. Can''t find it? Just reply and I''ll help.</p>' else '' end;
  perform public.orbyt_email_link(array[v.email],
    case when cp then case when n = 0 then 'Finish your Orbyt listing' else 'Still want to be listed? Finish your Orbyt listing' end
         else case when n = 0 then 'Finish your Orbyt profile' else 'Still want agent introductions? Finish your Orbyt profile' end end,
    'You''re almost in', body, case when cp then 'Finish my listing' else 'Finish my profile' end, 'vendor_setup_reminder', null);
  update public.vendor_admin set setup_reminders = coalesce(setup_reminders, 0) + 1, setup_reminded_at = now() where vendor_id = v.id;
  return true;
end $$;
revoke execute on function public.vendor_setup_send(uuid) from public, anon, authenticated;

-- daily: about 1, 4 and 7 days after sign-up, then weekly until they finish (stops if declined); vendors and closing partners
create or replace function public.vendor_setup_reminders_run() returns integer
language plpgsql security definer set search_path = '' as $$
declare r record; sent integer := 0;
begin
  for r in
    select v.id from public.vendors v join public.vendor_admin a on a.vendor_id = v.id
    left join public.profiles pr on pr.id = v.user_id
    where a.approved = false and v.user_id is not null
      and coalesce(pr.status, 'pending') <> 'declined'
      and v.created_at < now() - interval '20 hours'
      and (a.setup_reminded_at is null
           or a.setup_reminded_at < now() - case when coalesce(a.setup_reminders, 0) < 3 then interval '68 hours' else interval '164 hours' end)
      and coalesce(array_length(public.vendor_setup_missing(v.id), 1), 0) > 0
  loop
    if public.vendor_setup_send(r.id) then sent := sent + 1; end if;
  end loop;
  return sent;
end $$;
revoke execute on function public.vendor_setup_reminders_run() from public, anon, authenticated;

notify pgrst, 'reload schema';

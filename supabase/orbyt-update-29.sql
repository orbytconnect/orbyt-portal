-- Orbyt update 29: two-step vendor sign-up
-- Vendors create their account first (step 1), then finish their profile (step 2: years in business,
-- team size, lead time, agent references) while they wait for approval.
-- This adds automatic reminders for vendors who haven't finished, plus a "Send a reminder now" button for Ashleigh.
-- Safe to run more than once.

alter table public.vendor_admin add column if not exists setup_reminders   integer not null default 0;
alter table public.vendor_admin add column if not exists setup_reminded_at timestamptz;

-- what a vendor still needs before review (empty when done, and always empty for closing partners)
create or replace function public.vendor_setup_missing(p_vendor uuid) returns text[]
language sql stable security definer set search_path = '' as $$
  select case when v.kind = 'closing' then array[]::text[] else array_remove(array[
    case when coalesce(v.years_in_business, '') = '' then 'years in business' end,
    case when coalesce(v.team_size, '') = '' then 'team size' end,
    case when coalesce(v.lead_time, '') = '' then 'typical lead time' end,
    case when length(trim(coalesce(p.references_text, ''))) < 10 then 'agent references' end], null) end
  from public.vendors v left join public.vendor_private p on p.vendor_id = v.id
  where v.id = p_vendor
$$;
revoke execute on function public.vendor_setup_missing(uuid) from public, anon, authenticated;

-- send one reminder email (internal)
create or replace function public.vendor_setup_send(p_vendor uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
declare v public.vendors%rowtype; miss text[]; confirmed boolean; first text; body text; n integer;
begin
  select * into v from public.vendors where id = p_vendor;
  if v.id is null or v.user_id is null then return false; end if;
  miss := public.vendor_setup_missing(p_vendor);
  if coalesce(array_length(miss, 1), 0) = 0 then return false; end if;
  select email_confirmed_at is not null into confirmed from auth.users where id = v.user_id;
  select coalesce(setup_reminders, 0) into n from public.vendor_admin where vendor_id = v.id;
  first := split_part(coalesce(nullif(v.contact_name, ''), ''), ' ', 1);
  body := '<p style="font-size:15px;line-height:1.6;margin:0 0 12px">Hi' || case when first <> '' then ' ' || public.h(first) else '' end || ',</p>'
       || '<p style="font-size:15px;line-height:1.6;margin:0 0 12px">Thanks for starting your Orbyt sign-up for ' || public.h(v.name)
       || '. Before I can review your profile and introduce you to agents, I need a few more details:</p>'
       || '<ul style="font-size:15px;line-height:1.6;margin:0 0 12px;padding-left:20px">'
       || (select string_agg('<li>' || public.h(upper(left(m, 1)) || substr(m, 2)) || '</li>', '') from unnest(miss) m)
       || '</ul><p style="font-size:15px;line-height:1.6;margin:0 0 12px">It takes about 2 minutes. Sign in and you''ll land right on the form.</p>'
       || case when not coalesce(confirmed, false) then
            '<p style="font-size:15px;line-height:1.6;margin:0 0 12px">First, confirm your email with the link I sent when you signed up. Can''t find it? Just reply and I''ll help.</p>' else '' end;
  perform public.orbyt_email_link(array[v.email],
    case when n = 0 then 'Finish your Orbyt profile' else 'Still want agent introductions? Finish your Orbyt profile' end,
    'You''re almost in', body, 'Finish my profile', 'vendor_setup_reminder', null);
  update public.vendor_admin set setup_reminders = coalesce(setup_reminders, 0) + 1, setup_reminded_at = now() where vendor_id = v.id;
  return true;
end $$;
revoke execute on function public.vendor_setup_send(uuid) from public, anon, authenticated;

-- daily: reminders after about 1, 4 and 7 days, then stop
create or replace function public.vendor_setup_reminders_run() returns integer
language plpgsql security definer set search_path = '' as $$
declare r record; sent integer := 0;
begin
  for r in
    select v.id from public.vendors v join public.vendor_admin a on a.vendor_id = v.id
    where a.approved = false and coalesce(v.kind, '') <> 'closing' and v.user_id is not null
      and v.created_at < now() - interval '20 hours'
      and coalesce(a.setup_reminders, 0) < 3
      and (a.setup_reminded_at is null or a.setup_reminded_at < now() - interval '68 hours')
      and coalesce(array_length(public.vendor_setup_missing(v.id), 1), 0) > 0
  loop
    if public.vendor_setup_send(r.id) then sent := sent + 1; end if;
  end loop;
  return sent;
end $$;
revoke execute on function public.vendor_setup_reminders_run() from public, anon, authenticated;

-- Ashleigh: send one now
create or replace function public.vendor_setup_remind(p_vendor uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Only Orbyt can send reminders'; end if;
  return public.vendor_setup_send(p_vendor);
end $$;
revoke execute on function public.vendor_setup_remind(uuid) from public, anon;
grant execute on function public.vendor_setup_remind(uuid) to authenticated;

-- Ashleigh: who confirmed their email, and reminders sent so far
create or replace function public.vendor_setup_status()
returns table (vendor_id uuid, email_confirmed boolean, reminders integer, reminded_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then return; end if;
  return query
    select v.id, (u.email_confirmed_at is not null), coalesce(a.setup_reminders, 0), a.setup_reminded_at
    from public.vendors v join public.vendor_admin a on a.vendor_id = v.id
    left join auth.users u on u.id = v.user_id
    where a.approved = false;
end $$;
revoke execute on function public.vendor_setup_status() from public, anon;
grant execute on function public.vendor_setup_status() to authenticated;

-- 8:20am Pacific (16:20 UTC), daily
do $$ begin
  begin perform cron.unschedule('orbyt-setup-reminders'); exception when others then null; end;
  perform cron.schedule('orbyt-setup-reminders', '20 16 * * *', 'select public.vendor_setup_reminders_run()');
exception when others then raise notice 'pg_cron not available here: %', sqlerrm;
end $$;

notify pgrst, 'reload schema';

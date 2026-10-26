-- Orbyt update 8: Terms of Use by checkbox, and vendor insurance by trade group
-- 1. Agents and vendors agree to the Terms of Use with a checkbox (at sign-up, or in the portal),
--    instead of signing. Each acceptance records who, which version, when, IP address and browser.
--    Signed vendor agreements from before stay on file.
-- 2. Vendors upload their certificate of insurance, Ashleigh verifies it with one click, and
--    reminder emails go out every morning for missing, expiring and expired certificates.
-- Safe to run more than once.

-- ---------- Terms of Use: agents and vendors agree with a checkbox, no signature ----------
create table if not exists public.terms_acceptances (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid references auth.users (id) on delete set null,
  email           text not null,
  role            text not null check (role in ('agent', 'vendor')),
  version         text not null,
  source          text not null default 'portal' check (source in ('signup', 'portal')),
  accepted_at     timestamptz not null default now(),
  ip              text,
  first_login_ip  text,
  user_agent      text
);
create index if not exists terms_acceptances_user_idx on public.terms_acceptances (user_id);
alter table public.terms_acceptances enable row level security;

drop policy if exists terms_acceptances_read on public.terms_acceptances;
-- people see their own record; Ashleigh sees everyone's. Records are only written by the functions below.
create policy terms_acceptances_read on public.terms_acceptances for select to authenticated
  using (public.is_admin() or user_id = auth.uid());
grant select on public.terms_acceptances to authenticated;
revoke all on public.terms_acceptances from anon;

-- the visitor's IP address, as passed along by Supabase's gateway
create or replace function public.request_ip()
returns text language sql stable set search_path = '' as $$
  select nullif(trim(split_part(coalesce(
    nullif(current_setting('request.headers', true), '')::json ->> 'x-forwarded-for',
    nullif(current_setting('request.headers', true), '')::json ->> 'x-real-ip', ''), ',', 1)), '')
$$;

-- agree in the portal (people who joined before the checkbox, or after the terms change)
create or replace function public.accept_terms(p_version text, p_user_agent text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare r text; em text; new_id uuid;
begin
  select role, lower(email) into r, em from public.profiles where id = auth.uid();
  if r is null or r not in ('agent', 'vendor') then raise exception 'Only agents and vendors accept these terms'; end if;
  if p_version is null or p_version not like r || '-terms-%' then raise exception 'Those terms are not for this account'; end if;
  insert into public.terms_acceptances (user_id, email, role, version, source, ip, user_agent)
  values (auth.uid(), em, r, p_version, 'portal', public.request_ip(), left(p_user_agent, 300))
  returning id into new_id;
  return new_id;
end $$;

-- people who agreed on the sign-up form: note the IP address the first time they sign in
create or replace function public.note_terms_login()
returns void language sql security definer set search_path = '' as $$
  update public.terms_acceptances set first_login_ip = public.request_ip()
  where user_id = auth.uid() and source = 'signup' and first_login_ip is null
$$;

revoke execute on function public.accept_terms(text, text) from public, anon;
revoke execute on function public.note_terms_login() from public, anon;
grant execute on function public.accept_terms(text, text) to authenticated;
grant execute on function public.note_terms_login() to authenticated;

-- sign-ups now record the checkbox
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  m        jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  r        text  := case when m ->> 'role' = 'vendor' then 'vendor' else 'agent' end;
  em       text  := lower(new.email);
  invited  boolean;
  v_id     uuid;
begin
  -- agents who are already on a project (shared with them, or imported/added by Orbyt under their email)
  -- and vendors Orbyt already approved skip the approval wait
  invited := (r = 'agent' and (
    exists (select 1 from public.project_members where lower(email) = em)
    or exists (select 1 from public.default_shares where lower(email) = em)
    or exists (select 1 from public.projects where agent_id is null and lower(agent_email) = em)))
    or (r = 'vendor' and exists (select 1 from public.vendors v join public.vendor_admin a on a.vendor_id = v.id
                                 where v.user_id is null and lower(v.email) = em and a.approved));

  insert into public.profiles (id, role, status, full_name, email, phone, brokerage, areas, approved_at)
  values (new.id, r, case when invited then 'active' else 'pending' end,
          nullif(trim(m ->> 'full_name'), ''), em, m ->> 'phone', m ->> 'brokerage',
          public.jsonb_text_array(m -> 'areas'), case when invited then now() end)
  on conflict (id) do nothing;

  update public.project_members set user_id = new.id where user_id is null and lower(email) = em;
  if r = 'agent' then
    update public.projects set agent_id = new.id where agent_id is null and lower(agent_email) = em;
  end if;

  if r = 'vendor' then
    select id into v_id from public.vendors where user_id is null and lower(email) = em limit 1;
    if v_id is null then
      insert into public.vendors (user_id, name, contact_name, email, phone, website, services, areas,
                                  years_in_business, team_size, lead_time, works_with_agents, portfolio_url, source)
      values (new.id, coalesce(nullif(trim(m ->> 'company'), ''), nullif(trim(m ->> 'full_name'), ''), em),
              m ->> 'full_name', em, m ->> 'phone', m ->> 'website',
              public.jsonb_text_array(m -> 'services'), public.jsonb_text_array(m -> 'areas'),
              m ->> 'years_in_business', m ->> 'team_size', m ->> 'lead_time',
              m ->> 'works_with_agents', m ->> 'portfolio_url', 'Portal sign-up')
      returning id into v_id;
      insert into public.vendor_admin (vendor_id) values (v_id) on conflict do nothing;
    else
      update public.vendors set user_id = new.id where id = v_id;
      insert into public.vendor_admin (vendor_id) values (v_id) on conflict do nothing;
    end if;
    insert into public.vendor_private (vendor_id, references_text, heard_about, signup_notes, promo_interest)
    values (v_id, m ->> 'references', m ->> 'heard_about', m ->> 'signup_notes', m ->> 'promo_interest')
    on conflict (vendor_id) do update set
      references_text = coalesce(excluded.references_text, public.vendor_private.references_text),
      heard_about     = coalesce(excluded.heard_about,     public.vendor_private.heard_about),
      signup_notes    = coalesce(excluded.signup_notes,    public.vendor_private.signup_notes),
      promo_interest  = coalesce(excluded.promo_interest,  public.vendor_private.promo_interest);
  end if;
  -- Terms of Use accepted with the checkbox on the sign-up form
  if (m ->> 'terms_version') like r || '-terms-%' then
    insert into public.terms_acceptances (user_id, email, role, version, source, user_agent)
    values (new.id, em, r, m ->> 'terms_version', 'signup', left(m ->> 'user_agent', 300));
  end if;
  return new;
end $$;

-- the approval email no longer mentions signing
create or replace function public.profiles_notify() returns trigger language plpgsql security definer set search_path = '' as $$
declare
  meta jsonb;
  who  text;
begin
  if tg_op = 'INSERT' then
    if new.status = 'pending' then
      select raw_user_meta_data into meta from auth.users where id = new.id;
      who := coalesce(nullif(trim(meta ->> 'company'), ''), new.full_name, new.email);
      perform public.orbyt_email(array[public.admin_email()],
        'New ' || new.role || ' sign-up: ' || who, 'New ' || new.role || ' sign-up',
        public.ep('<b>' || public.h(who) || '</b>' || case when new.role = 'vendor' and coalesce(meta ->> 'full_name', '') <> '' then ' (' || public.h(meta ->> 'full_name') || ')' else '' end
                  || ' just joined as ' || case when new.role = 'vendor' then 'a vendor partner' else 'an agent' end || '. ' || public.h(new.email)
                  || case when coalesce(new.phone, '') <> '' then ', ' || public.h(new.phone) else '' end || '.')
        || case when coalesce(meta ->> 'services', '') <> '' then public.ep('Services: ' || public.h(array_to_string(public.jsonb_text_array(meta -> 'services'), ', '))) else '' end
        || case when cardinality(new.areas) > 0 then public.ep('Areas: ' || public.h(array_to_string(new.areas, ', '))) else '' end
        || case when coalesce(new.brokerage, '') <> '' then public.ep('Brokerage: ' || public.h(new.brokerage)) else '' end,
        'Review in Orbyt', 'admin_signup');
    end if;
    return new;
  end if;
  if new.status = 'active' and old.status = 'pending' then
    if new.role = 'vendor' then
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

-- ---------- Insurance by trade group: vendors upload, Ashleigh verifies, reminders run daily ----------
-- vendor's current certificate: {path, name, expires, uploadedAt}
alter table public.vendor_private add column if not exists insurance jsonb not null default '{}';
-- Ashleigh's check (only she can write vendor_admin)
alter table public.vendor_admin add column if not exists insurance_verified_path text;
alter table public.vendor_admin add column if not exists insurance_verified_at   timestamptz;
alter table public.vendor_admin add column if not exists insurance_expires       date;
alter table public.vendor_admin add column if not exists insurance_note          text;
alter table public.vendor_admin add column if not exists insurance_note_at       timestamptz;

create table if not exists public.insurance_reminders (
  vendor_id  uuid not null references public.vendors (id) on delete cascade,
  kind       text not null,
  sent_at    timestamptz not null default now(),
  primary key (vendor_id, kind)
);
alter table public.insurance_reminders enable row level security;
drop policy if exists insurance_reminders_admin on public.insurance_reminders;
create policy insurance_reminders_admin on public.insurance_reminders for select to authenticated using (public.is_admin());
grant select on public.insurance_reminders to authenticated;
revoke all on public.insurance_reminders from anon;

-- Trade groups. Keep these lists in step with INS_GROUPS in the portal code (src/live.js).
create or replace function public.insurance_trades(services text[], grp text) returns text[]
language sql immutable set search_path = '' as $$
  select coalesce(array_agg(s order by s), '{}') from unnest(coalesce(services, '{}')) s
  where lower(trim(s)) = any (case grp
    when 'high' then array['general contractor / remodeling','roofing','plumbing','electric','hvac','concrete','flooring','drywall',
                           'fencing','garage doors','appliance repair','solar panel cleaning','pest control','tree service']
    when 'mid'  then array['handyman','pool services','moving','junk removal','gutter cleaning','pressure washing','window cleaning',
                           'staging','landscaping']
    else array[]::text[] end)
$$;
create or replace function public.insurance_group(services text[]) returns text
language sql immutable set search_path = '' as $$
  select case when cardinality(public.insurance_trades(services, 'high')) > 0 then 'high'
              when cardinality(public.insurance_trades(services, 'mid'))  > 0 then 'mid' else 'low' end
$$;

-- Emails when a certificate comes in, when Ashleigh asks for a fix, and when she confirms it
create or replace function public.insurance_upload_notify() returns trigger language plpgsql security definer set search_path = '' as $$
declare vname text;
begin
  if coalesce(new.insurance ->> 'path', '') <> '' and new.insurance ->> 'path' is distinct from old.insurance ->> 'path' then
    select name into vname from public.vendors where id = new.vendor_id;
    perform public.orbyt_email(array[public.admin_email()], vname || ' uploaded their insurance', 'Insurance to check',
      public.ep('<b>' || public.h(vname) || '</b> uploaded a certificate of insurance'
        || case when coalesce(new.insurance ->> 'expires', '') <> '' then ', good through ' || public.h(to_char((new.insurance ->> 'expires')::date, 'FMMonth FMDD, YYYY')) else '' end || '.')
      || public.ep('Open it from your dashboard, check that Orbyt LLC is listed, and click Verified.'),
      'Check it now', 'admin_insurance');
  end if;
  return new;
exception when others then
  raise warning 'Orbyt insurance email skipped: %', sqlerrm;
  return new;
end $$;
drop trigger if exists insurance_upload_notify on public.vendor_private;
create trigger insurance_upload_notify after update of insurance on public.vendor_private
  for each row execute function public.insurance_upload_notify();

create or replace function public.insurance_check_notify() returns trigger language plpgsql security definer set search_path = '' as $$
declare v public.vendors%rowtype;
begin
  select * into v from public.vendors where id = new.vendor_id;
  if new.insurance_note_at is distinct from old.insurance_note_at and coalesce(new.insurance_note, '') <> '' then
    perform public.orbyt_email(array[public.vendor_email(v.id)], 'Your insurance certificate needs another look', 'One fix on your insurance',
      public.ep('Hi ' || public.h(public.first_name(v.contact_name)) || ', thanks for sending your certificate of insurance. It needs one change before I can mark it complete:')
      || public.ep('<i>' || public.h(new.insurance_note) || '</i>')
      || public.ep('Sign in to copy a ready-made request for your insurance agent, then upload the new certificate.'),
      'Upload a new certificate', 'insurance_fix');
  elsif new.insurance_verified_at is distinct from old.insurance_verified_at and new.insurance_verified_at is not null then
    perform public.orbyt_email(array[public.vendor_email(v.id)], 'Your insurance is all set', 'Insurance confirmed',
      public.ep('Hi ' || public.h(public.first_name(v.contact_name)) || ', your certificate of insurance is confirmed'
        || case when new.insurance_expires is not null then ', good through ' || to_char(new.insurance_expires, 'FMMonth FMDD, YYYY') else '' end
        || '. I''ll remind you before it expires.'),
      'Go to Orbyt', 'insurance_ok');
  end if;
  return new;
exception when others then
  raise warning 'Orbyt insurance email skipped: %', sqlerrm;
  return new;
end $$;
drop trigger if exists insurance_check_notify on public.vendor_admin;
create trigger insurance_check_notify after update of insurance_note_at, insurance_verified_at on public.vendor_admin
  for each row execute function public.insurance_check_notify();

-- Daily reminders: missing certificates, expiring soon, expired. Each one goes out once.
create or replace function public.insurance_reminders_run() returns integer language plpgsql security definer set search_path = '' as $$
declare
  r        record;
  grp      text;
  trades   text;
  cur      jsonb;
  has_file boolean;
  verified boolean;
  exp      date;
  due      date;
  n_up     integer;
  last_up  timestamptz;
  ask      text;
  sent     integer := 0;
begin
  for r in
    select v.id, v.name, v.services, v.contact_name, a.approved_at, a.insurance_verified_path, a.insurance_expires,
           a.insurance_note_at, coalesce(p.insurance, '{}'::jsonb) as insurance
      from public.vendors v
      join public.vendor_admin a on a.vendor_id = v.id and a.approved
      left join public.vendor_private p on p.vendor_id = v.id
      join public.profiles pr on pr.id = v.user_id and pr.status = 'active'
  loop
    grp := public.insurance_group(r.services);
    trades := lower(array_to_string(public.insurance_trades(r.services, grp), ', '));
    cur := r.insurance;
    has_file := coalesce(cur ->> 'path', '') <> ''
                and (r.insurance_note_at is null or r.insurance_note_at < coalesce((cur ->> 'uploadedAt')::timestamptz, '-infinity'));
    verified := has_file and r.insurance_verified_path = cur ->> 'path';
    exp := case when verified then r.insurance_expires else nullif(cur ->> 'expires', '')::date end;
    due := (coalesce(r.approved_at, now()) + interval '30 days')::date;

    if not has_file then
      -- up to four nudges, a week apart, starting two days after approval
      select count(*), max(sent_at) into n_up, last_up from public.insurance_reminders where vendor_id = r.id and kind like 'upload:%';
      if n_up < 4 and coalesce(r.approved_at, now()) < now() - interval '2 days' and (last_up is null or last_up < now() - interval '6 days') then
        ask := case grp
          when 'high' then 'Because you offer ' || public.h(trades) || ', Orbyt needs a certificate of insurance that names Orbyt LLC as an additional insured before I can send you introductions.'
          when 'mid'  then 'Because you offer ' || public.h(trades) || ', Orbyt needs a certificate of insurance that names Orbyt LLC as an additional insured by '
                           || to_char(due, 'FMMonth FMDD') || '. Introductions keep coming until then.'
          else 'Orbyt needs a current certificate of your general liability insurance' || ' by ' || to_char(due, 'FMMonth FMDD') || '.' end;
        perform public.orbyt_email(array[public.vendor_email(r.id)], 'Your Orbyt insurance certificate', 'Quick insurance step',
          public.ep('Hi ' || public.h(public.first_name(r.contact_name)) || ', ' || ask)
          || public.ep('Sign in to copy a ready-made email to your insurance agent. They can usually send the certificate the same day. Then upload it on your dashboard.'),
          'Upload my certificate', 'insurance_upload');
        insert into public.insurance_reminders (vendor_id, kind) values (r.id, 'upload:' || (n_up + 1)) on conflict do nothing;
        sent := sent + 1;
      end if;
    elsif exp is not null and exp < current_date then
      if not exists (select 1 from public.insurance_reminders where vendor_id = r.id and kind = 'expired:' || exp) then
        perform public.orbyt_email(array[public.vendor_email(r.id)], 'Your insurance certificate has expired', 'Time for a new certificate',
          public.ep('Hi ' || public.h(public.first_name(r.contact_name)) || ', the certificate of insurance on file with Orbyt expired on '
            || to_char(exp, 'FMMonth FMDD, YYYY') || '.'
            || case when grp <> 'low' then ' New introductions are paused until the renewed certificate is in.' else '' end)
          || public.ep('Ask your insurance agent for the renewed certificate (sign in to copy a ready-made request), then upload it on your dashboard.'),
          'Upload my certificate', 'insurance_expired');
        perform public.orbyt_email(array[public.admin_email()], r.name || '''s insurance expired', 'Insurance expired',
          public.ep('<b>' || public.h(r.name) || '</b>''s certificate of insurance expired on ' || to_char(exp, 'FMMonth FMDD, YYYY') || '. They''ve been asked to upload the renewal.'),
          'See their profile', 'admin_insurance');
        insert into public.insurance_reminders (vendor_id, kind) values (r.id, 'expired:' || exp) on conflict do nothing;
        sent := sent + 1;
      end if;
    elsif verified and exp is not null and exp <= current_date + 30 then
      if not exists (select 1 from public.insurance_reminders where vendor_id = r.id and kind = 'expiring:' || exp) then
        perform public.orbyt_email(array[public.vendor_email(r.id)], 'Your insurance renews soon', 'Insurance renewal coming up',
          public.ep('Hi ' || public.h(public.first_name(r.contact_name)) || ', the certificate of insurance on file with Orbyt is good through '
            || to_char(exp, 'FMMonth FMDD, YYYY') || '. Once your policy renews, please upload the new certificate so introductions keep coming.'),
          'Upload my certificate', 'insurance_expiring');
        insert into public.insurance_reminders (vendor_id, kind) values (r.id, 'expiring:' || exp) on conflict do nothing;
        sent := sent + 1;
      end if;
    end if;
  end loop;
  return sent;
end $$;
revoke execute on function public.insurance_reminders_run() from public, anon, authenticated;
revoke execute on function public.insurance_upload_notify() from public, anon, authenticated;
revoke execute on function public.insurance_check_notify() from public, anon, authenticated;

-- Run the reminders every morning (9:05am Pacific in summer, 8:05am in winter)
do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('orbyt-insurance-reminders', '5 16 * * *', 'select public.insurance_reminders_run()');
exception when others then
  raise warning 'Daily insurance reminders were not scheduled (%). In Supabase, turn on the pg_cron extension under Database, Extensions, then run this script again.', sqlerrm;
end $$;
